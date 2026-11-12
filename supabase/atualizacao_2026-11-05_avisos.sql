-- Ponto AVP — avisos para fiscais (quem não bateu a entrada)
-- 1) papéis: admin (tudo) e fiscal (só vê)
alter table public.admins add column if not exists papel text not null default 'admin';
alter table public.admins add column if not exists email text;
do $$ begin
  alter table public.admins add constraint admins_papel_ck check (papel in ('admin', 'fiscal'));
exception when duplicate_object then null; end $$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid() and papel = 'admin');
$$;
create or replace function public.is_gestor()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;
revoke execute on function public.is_gestor() from public, anon;
grant execute on function public.is_gestor() to authenticated;

-- fiscais podem ler tudo o que o painel mostra
drop policy if exists colab_ler on public.colaboradores;
create policy colab_ler on public.colaboradores for select to authenticated using (user_id = auth.uid() or public.is_gestor());
drop policy if exists reg_ler on public.registros;
create policy reg_ler on public.registros for select to authenticated
  using (public.is_gestor() or colaborador_id in (select id from public.colaboradores where user_id = auth.uid()));
drop policy if exists tent_ler on public.tentativas_bloqueadas;
create policy tent_ler on public.tentativas_bloqueadas for select to authenticated using (public.is_gestor());
drop policy if exists pr_ler on public.pontos_ronda;
create policy pr_ler on public.pontos_ronda for select to authenticated
  using (public.is_gestor() or posto_id in (select posto_id from public.colaboradores where user_id = auth.uid()));
drop policy if exists rondas_ler on public.rondas;
create policy rondas_ler on public.rondas for select to authenticated
  using (public.is_gestor() or colaborador_id in (select id from public.colaboradores where user_id = auth.uid()));
drop policy if exists ajustes_ler on public.ajustes;
create policy ajustes_ler on public.ajustes for select to authenticated
  using (public.is_gestor() or colaborador_id in (select id from public.colaboradores where user_id = auth.uid()));
drop policy if exists selfie_ver on storage.objects;
create policy selfie_ver on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_gestor()));

-- 2) horário e escala de cada funcionário
alter table public.colaboradores add column if not exists hora_entrada time;
alter table public.colaboradores add column if not exists escala text;
alter table public.colaboradores add column if not exists escala_ref date;
do $$ begin
  alter table public.colaboradores add constraint colab_escala_ck check (escala is null or escala in ('seg-sex', 'seg-sab', 'todos', '12x36'));
exception when duplicate_object then null; end $$;

create table if not exists public.config (chave text primary key, valor text not null);
insert into public.config values ('tolerancia_min', '15') on conflict do nothing;
alter table public.config enable row level security;
drop policy if exists config_ler on public.config;
create policy config_ler on public.config for select to authenticated using (public.is_gestor());
drop policy if exists config_admin on public.config;
create policy config_admin on public.config for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.escala_trabalha(p_escala text, p_ref date, p_dia date)
returns boolean language sql immutable set search_path = public as $$
  select case p_escala
    when 'seg-sex' then extract(isodow from p_dia) between 1 and 5
    when 'seg-sab' then extract(isodow from p_dia) between 1 and 6
    when 'todos'   then true
    when '12x36'   then p_ref is not null and ((p_dia - p_ref) % 2) = 0
    else false end;
$$;

-- 3) inscrições de aviso (cada celular que ativou os avisos)
create table if not exists public.push_inscricoes (
  id         bigserial primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  aparelho   text,
  criado_em  timestamptz not null default now()
);
alter table public.push_inscricoes enable row level security;
drop policy if exists push_proprio on public.push_inscricoes;
create policy push_proprio on public.push_inscricoes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.is_gestor());

-- 4) avisos já enviados (um por funcionário por dia)
create table if not exists public.avisos_enviados (
  colaborador_id bigint not null references public.colaboradores(id) on delete cascade,
  dia            date not null,
  tipo           text not null,
  previsto       timestamptz,
  enviado_em     timestamptz not null default now(),
  primary key (colaborador_id, dia, tipo)
);
alter table public.avisos_enviados enable row level security;
drop policy if exists avisos_ler on public.avisos_enviados;
create policy avisos_ler on public.avisos_enviados for select to authenticated using (public.is_gestor());

-- 5) quem passou do horário sem bater o ponto (marca como avisado e devolve só os novos)
create or replace function public.pegar_atrasos()
returns table(colaborador_id bigint, nome text, posto text, previsto timestamptz)
language plpgsql security definer set search_path = public as $$
declare v_tol interval;
begin
  select make_interval(mins => coalesce((select valor::int from public.config where chave = 'tolerancia_min'), 15)) into v_tol;
  return query
  with dias as (
    select ((now() at time zone 'America/Sao_Paulo')::date - k) as d from generate_series(0, 1) k
  ), cand as (
    select c.id, c.nome, p.nome as pnome, dd.d,
           ((dd.d + c.hora_entrada)::timestamp at time zone 'America/Sao_Paulo') as prev
      from public.colaboradores c
      join public.postos p on p.id = c.posto_id and p.ativo
      cross join dias dd
     where c.ativo and c.hora_entrada is not null and public.escala_trabalha(c.escala, c.escala_ref, dd.d)
  ), atrasados as (
    select * from cand
     where now() >= cand.prev + v_tol and now() < cand.prev + interval '4 hours'
       and not exists (select 1 from public.marcas_efetivas(cand.id, cand.prev - interval '3 hours') m)
  ), novos as (
    insert into public.avisos_enviados (colaborador_id, dia, tipo, previsto)
    select a.id, a.d, 'sem_entrada', a.prev from atrasados a
    on conflict do nothing
    returning avisos_enviados.colaborador_id, avisos_enviados.dia
  )
  select a.id, a.nome, a.pnome, a.prev from atrasados a join novos n on n.colaborador_id = a.id and n.dia = a.d
  order by a.prev, a.nome;
end;
$$;
revoke execute on function public.pegar_atrasos() from public, anon, authenticated;
