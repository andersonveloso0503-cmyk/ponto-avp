-- Ponto AVP — ajustes de ponto pelo RH (tratamento de marcações)
-- A marcação original nunca é alterada: o ajuste fica registrado à parte, com justificativa, quem fez e quando.
create table if not exists public.ajustes (
  id              bigserial primary key,
  colaborador_id  bigint not null references public.colaboradores(id),
  acao            text not null check (acao in ('incluir', 'desconsiderar', 'alterar_tipo')),
  registro_id     bigint references public.registros(id),
  tipo            text check (tipo in ('entrada','saida_intervalo','volta_intervalo','saida')),
  marcacao_em     timestamptz,
  posto_id        bigint references public.postos(id),
  justificativa   text not null check (length(trim(justificativa)) >= 5),
  criado_por      uuid not null default auth.uid(),
  criado_em       timestamptz not null default now(),
  anulado_em      timestamptz,
  anulado_por     uuid,
  check ((acao = 'incluir' and tipo is not null and marcacao_em is not null and registro_id is null)
      or (acao = 'desconsiderar' and registro_id is not null)
      or (acao = 'alterar_tipo' and registro_id is not null and tipo is not null))
);
create index if not exists ajustes_colab on public.ajustes (colaborador_id);
create unique index if not exists ajustes_um_por_registro on public.ajustes (registro_id)
  where registro_id is not null and anulado_em is null;

-- ajuste não pode ser apagado nem editado; só anulado pela função abaixo
create or replace function public.ajustes_protege()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then raise exception 'Ajustes não podem ser apagados. Use Anular.'; end if;
  if new.colaborador_id <> old.colaborador_id or new.acao <> old.acao or new.registro_id is distinct from old.registro_id
     or new.tipo is distinct from old.tipo or new.marcacao_em is distinct from old.marcacao_em
     or new.justificativa <> old.justificativa or new.criado_por <> old.criado_por or new.criado_em <> old.criado_em
     or old.anulado_em is not null then
    raise exception 'Ajustes não podem ser editados. Anule e faça outro.';
  end if;
  return new;
end;
$$;
drop trigger if exists ajustes_protege on public.ajustes;
create trigger ajustes_protege before update or delete on public.ajustes
  for each row execute function public.ajustes_protege();

-- confere que o registro ajustado é do mesmo colaborador
create or replace function public.ajustes_confere()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.registro_id is not null and not exists
     (select 1 from public.registros r where r.id = new.registro_id and r.colaborador_id = new.colaborador_id) then
    raise exception 'O registro não é deste colaborador.';
  end if;
  new.criado_por := auth.uid(); new.criado_em := now(); new.anulado_em := null; new.anulado_por := null;
  return new;
end;
$$;
drop trigger if exists ajustes_confere on public.ajustes;
create trigger ajustes_confere before insert on public.ajustes
  for each row execute function public.ajustes_confere();

create or replace function public.anular_ajuste(p_id bigint)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return json_build_object('ok', false, 'motivo', 'Sem permissão.'); end if;
  update public.ajustes set anulado_em = now(), anulado_por = auth.uid() where id = p_id and anulado_em is null;
  return json_build_object('ok', found);
end;
$$;

alter table public.ajustes enable row level security;
drop policy if exists ajustes_ler on public.ajustes;
create policy ajustes_ler on public.ajustes for select to authenticated
  using (public.is_admin() or colaborador_id in (select id from public.colaboradores where user_id = auth.uid()));
drop policy if exists ajustes_incluir on public.ajustes;
create policy ajustes_incluir on public.ajustes for insert to authenticated with check (public.is_admin());

revoke execute on function public.anular_ajuste(bigint) from public, anon;
grant execute on function public.anular_ajuste(bigint) to authenticated;
