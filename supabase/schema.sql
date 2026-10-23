-- =====================================================================
-- PONTO AVP — banco de dados (Supabase)
-- Rode este arquivo inteiro no Supabase: SQL Editor > New query > Run
-- Pode rodar de novo sem problema (ele não apaga registros).
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists unaccent with schema extensions;

-- ---------------------------------------------------------------------
-- TABELAS
-- ---------------------------------------------------------------------

create table if not exists public.postos (
  id          bigserial primary key,
  nome        text not null,
  endereco    text,
  lat         double precision not null,
  lng         double precision not null,
  raio_m      integer not null default 150 check (raio_m between 20 and 5000),
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);

create table if not exists public.colaboradores (
  id          bigserial primary key,
  cpf         text not null unique check (cpf ~ '^[0-9]{11}$'),
  nome        text not null,
  funcao      text,
  posto_id    bigint references public.postos(id) on delete set null,
  ativo       boolean not null default true,
  user_id     uuid unique references auth.users(id) on delete set null,
  criado_em   timestamptz not null default now()
);

create table if not exists public.admins (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  nome        text
);

-- Registro de ponto: cada linha é um NSR (número sequencial de registro).
-- Não pode ser alterado nem apagado (ver gatilho abaixo).
create table if not exists public.registros (
  id              bigserial primary key,           -- NSR
  colaborador_id  bigint not null references public.colaboradores(id),
  posto_id        bigint references public.postos(id),
  tipo            text not null check (tipo in ('entrada','saida_intervalo','volta_intervalo','saida')),
  registrado_em   timestamptz not null default now(),  -- hora do SERVIDOR, não do celular
  lat             double precision not null,
  lng             double precision not null,
  precisao_m      double precision,
  distancia_m     double precision not null,
  foto_path       text not null,
  dispositivo     text,
  hash            text not null
);
create index if not exists registros_colab_data on public.registros (colaborador_id, registrado_em desc);
create index if not exists registros_data on public.registros (registrado_em desc);

-- Tentativas bloqueadas (longe do posto, GPS fraco etc.) — o empregador vê no painel
create table if not exists public.tentativas_bloqueadas (
  id              bigserial primary key,
  colaborador_id  bigint references public.colaboradores(id),
  posto_id        bigint references public.postos(id),
  tentado_em      timestamptz not null default now(),
  lat             double precision,
  lng             double precision,
  precisao_m      double precision,
  distancia_m     double precision,
  foto_path       text,
  motivo          text not null
);
create index if not exists tentativas_data on public.tentativas_bloqueadas (tentado_em desc);

-- ---------------------------------------------------------------------
-- FUNÇÕES DE APOIO
-- ---------------------------------------------------------------------

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- distância em metros entre dois pontos (fórmula de Haversine)
create or replace function public.distancia_m(lat1 double precision, lng1 double precision,
                                              lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 6371000 * 2 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)
  ));
$$;

create or replace function public.normaliza_nome(t text)
returns text language sql immutable as $$
  select regexp_replace(lower(extensions.unaccent(coalesce(t, ''))), '\s+', ' ', 'g');
$$;

-- registros não podem ser alterados nem apagados
create or replace function public.bloqueia_alteracao()
returns trigger language plpgsql as $$
begin
  raise exception 'Registros de ponto não podem ser alterados nem apagados.';
end;
$$;
drop trigger if exists registros_imutaveis on public.registros;
create trigger registros_imutaveis before update or delete on public.registros
  for each row execute function public.bloqueia_alteracao();

-- ---------------------------------------------------------------------
-- PRIMEIRO ACESSO (colaborador cria a senha com CPF + nome)
-- ---------------------------------------------------------------------

-- confere se CPF + nome batem com um colaborador ativo ainda sem conta
create or replace function public.primeiro_acesso_valido(p_cpf text, p_nome text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare c public.colaboradores;
begin
  select * into c from public.colaboradores
   where cpf = regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  if not found or not c.ativo then
    return json_build_object('ok', false, 'motivo', 'CPF não cadastrado. Fale com o RH.');
  end if;
  if public.normaliza_nome(c.nome) <> public.normaliza_nome(trim(p_nome)) then
    return json_build_object('ok', false, 'motivo', 'O nome não confere com o cadastro. Digite o nome completo.');
  end if;
  if c.user_id is not null then
    return json_build_object('ok', false, 'motivo', 'Este CPF já tem senha. Use "Entrar". Esqueceu? Fale com o RH.');
  end if;
  return json_build_object('ok', true);
end;
$$;

-- liga a conta recém-criada (e-mail = cpf@dominio) ao cadastro do colaborador
create or replace function public.vincular_conta(p_nome text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare v_email text; v_cpf text; c public.colaboradores;
begin
  select email into v_email from auth.users where id = auth.uid();
  if v_email is null then
    return json_build_object('ok', false, 'motivo', 'Sessão inválida.');
  end if;
  v_cpf := split_part(v_email, '@', 1);
  select * into c from public.colaboradores where cpf = v_cpf;
  if not found or not c.ativo
     or public.normaliza_nome(c.nome) <> public.normaliza_nome(trim(p_nome)) then
    return json_build_object('ok', false, 'motivo', 'Cadastro não confere. Fale com o RH.');
  end if;
  if c.user_id is not null and c.user_id <> auth.uid() then
    return json_build_object('ok', false, 'motivo', 'Este CPF já está ligado a outra conta. Fale com o RH.');
  end if;
  update public.colaboradores set user_id = auth.uid() where id = c.id;
  return json_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- SITUAÇÃO DO COLABORADOR E BATER PONTO
-- ---------------------------------------------------------------------

-- quais tipos de registro são permitidos agora, a partir do último registro
create or replace function public.tipos_permitidos(p_colab bigint)
returns text[] language plpgsql stable security definer set search_path = public, extensions as $$
declare ult public.registros;
begin
  select * into ult from public.registros
   where colaborador_id = p_colab order by registrado_em desc limit 1;
  if not found or ult.tipo = 'saida' or now() - ult.registrado_em > interval '16 hours' then
    return array['entrada'];
  elsif ult.tipo = 'saida_intervalo' then
    return array['volta_intervalo'];
  else  -- entrada ou volta_intervalo
    return array['saida_intervalo', 'saida'];
  end if;
end;
$$;

-- (meu_status fica mais abaixo, junto com as rondas)

-- A ÚNICA forma de gravar um ponto. Confere posto, distância, GPS e selfie.
create or replace function public.bater_ponto(
  p_lat double precision, p_lng double precision, p_precisao double precision,
  p_foto text, p_tipo text default null, p_dispositivo text default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  c public.colaboradores; p public.postos;
  v_dist double precision; v_permitidos text[]; v_tipo text;
  v_ultimo timestamptz; v_hash_ant text; v_hash text; v_ts timestamptz := now();
  r public.registros; v_motivo text;
begin
  select * into c from public.colaboradores where user_id = auth.uid();
  if not found or not c.ativo then
    return json_build_object('ok', false, 'motivo', 'Cadastro não encontrado ou inativo. Fale com o RH.');
  end if;

  select * into p from public.postos where id = c.posto_id and ativo;
  if not found then
    return json_build_object('ok', false, 'motivo', 'Você não está ligado a um posto. Fale com o RH.');
  end if;

  if p_lat is null or p_lng is null then
    return json_build_object('ok', false, 'motivo', 'Localização não recebida. Ligue o GPS e permita a localização.');
  end if;

  v_dist := public.distancia_m(p_lat, p_lng, p.lat, p.lng);

  if p_foto is null or split_part(p_foto, '/', 1) <> auth.uid()::text then
    v_motivo := 'Selfie obrigatória.';
  elsif p_precisao is not null and p_precisao > 200 then
    v_motivo := format('Sinal de GPS fraco (precisão de %s m). Vá para um lugar aberto e tente de novo.', round(p_precisao));
  elsif v_dist > p.raio_m then
    v_motivo := format('Você está a %s m do posto %s (limite %s m). Ponto bloqueado.', round(v_dist), p.nome, p.raio_m);
  end if;

  if v_motivo is not null then
    insert into public.tentativas_bloqueadas (colaborador_id, posto_id, lat, lng, precisao_m, distancia_m, foto_path, motivo)
    values (c.id, p.id, p_lat, p_lng, p_precisao, v_dist, p_foto, v_motivo);
    return json_build_object('ok', false, 'motivo', v_motivo, 'distancia_m', round(v_dist), 'raio_m', p.raio_m);
  end if;

  select registrado_em, hash into v_ultimo, v_hash_ant from public.registros
   where colaborador_id = c.id order by registrado_em desc limit 1;
  if v_ultimo is not null and v_ts - v_ultimo < interval '1 minute' then
    return json_build_object('ok', false, 'motivo', 'Você acabou de registrar. Aguarde 1 minuto.');
  end if;

  v_permitidos := public.tipos_permitidos(c.id);
  v_tipo := coalesce(p_tipo, v_permitidos[1]);
  if not (v_tipo = any(v_permitidos)) then
    return json_build_object('ok', false, 'motivo', 'Tipo de registro fora de ordem. Atualize a tela.');
  end if;

  -- assinatura encadeada: qualquer alteração por fora quebra a sequência
  v_hash := encode(extensions.digest(concat_ws('|', coalesce(v_hash_ant, 'inicio'), c.cpf, v_tipo,
                                    to_char(v_ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
                                    p_lat, p_lng, p.id), 'sha256'), 'hex');

  insert into public.registros (colaborador_id, posto_id, tipo, registrado_em, lat, lng,
                                precisao_m, distancia_m, foto_path, dispositivo, hash)
  values (c.id, p.id, v_tipo, v_ts, p_lat, p_lng, p_precisao, v_dist, p_foto, left(p_dispositivo, 300), v_hash)
  returning * into r;

  return json_build_object('ok', true,
    'registro', json_build_object('nsr', r.id, 'tipo', r.tipo, 'registrado_em', r.registrado_em,
                                  'distancia_m', round(r.distancia_m), 'hash', r.hash),
    'colaborador', json_build_object('nome', c.nome, 'cpf', c.cpf),
    'posto', json_build_object('nome', p.nome));
end;
$$;

-- ---------------------------------------------------------------------
-- SEGURANÇA (RLS)
-- ---------------------------------------------------------------------

alter table public.postos                enable row level security;
alter table public.colaboradores         enable row level security;
alter table public.admins                enable row level security;
alter table public.registros             enable row level security;
alter table public.tentativas_bloqueadas enable row level security;

drop policy if exists postos_ler on public.postos;
create policy postos_ler on public.postos for select to authenticated using (true);
drop policy if exists postos_admin on public.postos;
create policy postos_admin on public.postos for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists colab_ler on public.colaboradores;
create policy colab_ler on public.colaboradores for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists colab_admin on public.colaboradores;
create policy colab_admin on public.colaboradores for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists admins_ler on public.admins;
create policy admins_ler on public.admins for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- registros: só leitura (gravação apenas pela função bater_ponto)
drop policy if exists reg_ler on public.registros;
create policy reg_ler on public.registros for select to authenticated
  using (public.is_admin() or colaborador_id in
         (select id from public.colaboradores where user_id = auth.uid()));

drop policy if exists tent_ler on public.tentativas_bloqueadas;
create policy tent_ler on public.tentativas_bloqueadas for select to authenticated
  using (public.is_admin());

revoke all on function public.bater_ponto(double precision, double precision, double precision, text, text, text) from public, anon;
grant execute on function public.bater_ponto(double precision, double precision, double precision, text, text, text) to authenticated;
grant execute on function public.vincular_conta(text) to authenticated;
grant execute on function public.primeiro_acesso_valido(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- SELFIES (armazenamento privado)
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('selfies', 'selfies', false)
on conflict (id) do nothing;

drop policy if exists selfie_enviar on storage.objects;
create policy selfie_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'selfies' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists selfie_ver on storage.objects;
create policy selfie_ver on storage.objects for select to authenticated
  using (bucket_id = 'selfies' and
         ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ---------------------------------------------------------------------
-- RONDAS COM QR CODE
-- Cada posto pode ter vários pontos de ronda (Garagem, Portão B, Salão...).
-- Cada ponto tem um QR Code. O colaborador lê o QR e a passagem é gravada.
-- ---------------------------------------------------------------------

create table if not exists public.pontos_ronda (
  id          bigserial primary key,
  posto_id    bigint not null references public.postos(id),
  nome        text not null,
  codigo      text not null unique default encode(extensions.gen_random_bytes(9), 'hex'),
  ordem       integer not null default 0,
  ativo       boolean not null default true,
  criado_em   timestamptz not null default now()
);
create index if not exists pontos_ronda_posto on public.pontos_ronda (posto_id);

create table if not exists public.rondas (
  id              bigserial primary key,
  colaborador_id  bigint not null references public.colaboradores(id),
  ponto_ronda_id  bigint not null references public.pontos_ronda(id),
  posto_id        bigint references public.postos(id),
  registrado_em   timestamptz not null default now(),
  lat             double precision not null,
  lng             double precision not null,
  precisao_m      double precision,
  distancia_m     double precision not null
);
create index if not exists rondas_data on public.rondas (registrado_em desc);
create index if not exists rondas_colab on public.rondas (colaborador_id, registrado_em desc);

drop trigger if exists rondas_imutaveis on public.rondas;
create trigger rondas_imutaveis before update or delete on public.rondas
  for each row execute function public.bloqueia_alteracao();

create or replace function public.registrar_ronda(
  p_codigo text, p_lat double precision, p_lng double precision, p_precisao double precision)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  c public.colaboradores; pr public.pontos_ronda; p public.postos;
  v_dist double precision; v_motivo text; v_perm text[]; v_ult timestamptz; r public.rondas;
begin
  select * into c from public.colaboradores where user_id = auth.uid();
  if not found or not c.ativo then
    return json_build_object('ok', false, 'motivo', 'Cadastro não encontrado ou inativo. Fale com o RH.');
  end if;

  select * into pr from public.pontos_ronda where codigo = trim(coalesce(p_codigo, '')) and ativo;
  if not found then
    return json_build_object('ok', false, 'motivo', 'QR Code de ronda inválido ou desativado.');
  end if;
  select * into p from public.postos where id = pr.posto_id;

  if p_lat is not null and p_lng is not null then
    v_dist := public.distancia_m(p_lat, p_lng, p.lat, p.lng);
  end if;

  if pr.posto_id is distinct from c.posto_id then
    v_motivo := format('Este QR Code é do posto %s, e você está alocado em outro posto.', p.nome);
  elsif v_dist is null then
    v_motivo := 'Localização não recebida. Ligue o GPS e permita a localização.';
  elsif p_precisao is not null and p_precisao > 200 then
    v_motivo := format('Sinal de GPS fraco (precisão de %s m). Tente de novo em local aberto.', round(p_precisao));
  elsif v_dist > p.raio_m then
    v_motivo := format('Você está a %s m do posto %s (limite %s m).', round(v_dist), p.nome, p.raio_m);
  else
    v_perm := public.tipos_permitidos(c.id);
    if 'entrada' = any(v_perm) then
      v_motivo := 'Bata a entrada antes de fazer a ronda.';
    elsif v_perm = array['volta_intervalo'] then
      v_motivo := 'Você está em intervalo. Registre a volta antes de fazer a ronda.';
    end if;
  end if;

  if v_motivo is not null then
    insert into public.tentativas_bloqueadas (colaborador_id, posto_id, lat, lng, precisao_m, distancia_m, motivo)
    values (c.id, p.id, p_lat, p_lng, p_precisao, v_dist, 'Ronda ' || pr.nome || ': ' || v_motivo);
    return json_build_object('ok', false, 'motivo', v_motivo, 'ponto', pr.nome);
  end if;

  select max(registrado_em) into v_ult from public.rondas
   where colaborador_id = c.id and ponto_ronda_id = pr.id;
  if v_ult is not null and now() - v_ult < interval '2 minutes' then
    return json_build_object('ok', false, 'motivo', 'Este ponto da ronda já foi registrado agora há pouco.', 'ponto', pr.nome);
  end if;

  insert into public.rondas (colaborador_id, ponto_ronda_id, posto_id, lat, lng, precisao_m, distancia_m)
  values (c.id, pr.id, p.id, p_lat, p_lng, p_precisao, v_dist)
  returning * into r;

  return json_build_object('ok', true, 'ponto', pr.nome, 'posto', p.nome,
                           'registrado_em', r.registrado_em, 'distancia_m', round(r.distancia_m));
end;
$$;

-- situação do colaborador agora inclui a ronda do posto (pontos e se já passou na jornada atual)
create or replace function public.meu_status()
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare c public.colaboradores; p public.postos; v_ini timestamptz;
begin
  select * into c from public.colaboradores where user_id = auth.uid();
  if not found then
    return json_build_object('ok', false, 'motivo', 'Cadastro não encontrado.');
  end if;
  select * into p from public.postos where id = c.posto_id;
  select max(e.registrado_em) into v_ini from public.registros e
   where e.colaborador_id = c.id and e.tipo = 'entrada' and e.registrado_em > now() - interval '18 hours';
  return json_build_object(
    'ok', true,
    'colaborador', json_build_object('id', c.id, 'nome', c.nome, 'funcao', c.funcao, 'ativo', c.ativo),
    'posto', case when p.id is null then null else
             json_build_object('id', p.id, 'nome', p.nome, 'lat', p.lat, 'lng', p.lng,
                               'raio_m', p.raio_m, 'ativo', p.ativo) end,
    'permitidos', public.tipos_permitidos(c.id),
    'hoje', coalesce((
      select json_agg(json_build_object('id', r.id, 'tipo', r.tipo, 'registrado_em', r.registrado_em)
                      order by r.registrado_em)
        from public.registros r
       where r.colaborador_id = c.id and r.registrado_em >= coalesce(v_ini, now())
    ), '[]'::json),
    'ronda', coalesce((
      select json_agg(json_build_object('nome', pr.nome,
               'ultima', (select max(x.registrado_em) from public.rondas x
                           where x.ponto_ronda_id = pr.id and x.colaborador_id = c.id
                             and x.registrado_em >= coalesce(v_ini, now())))
             order by pr.ordem, pr.nome)
        from public.pontos_ronda pr
       where pr.posto_id = c.posto_id and pr.ativo
    ), '[]'::json)
  );
end;
$$;

alter table public.pontos_ronda enable row level security;
alter table public.rondas       enable row level security;

drop policy if exists pr_ler on public.pontos_ronda;
create policy pr_ler on public.pontos_ronda for select to authenticated
  using (public.is_admin() or posto_id in (select posto_id from public.colaboradores where user_id = auth.uid()));
drop policy if exists pr_admin on public.pontos_ronda;
create policy pr_admin on public.pontos_ronda for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists rondas_ler on public.rondas;
create policy rondas_ler on public.rondas for select to authenticated
  using (public.is_admin() or colaborador_id in
         (select id from public.colaboradores where user_id = auth.uid()));

revoke all on function public.registrar_ronda(text, double precision, double precision, double precision) from public, anon;
grant execute on function public.registrar_ronda(text, double precision, double precision, double precision) to authenticated;
grant execute on function public.meu_status() to authenticated;

-- ajuste de segurança
alter function public.distancia_m(double precision, double precision, double precision, double precision) set search_path = public;
alter function public.normaliza_nome(text) set search_path = public, extensions;
alter function public.bloqueia_alteracao() set search_path = public;
revoke execute on function public.tipos_permitidos(bigint) from public, anon, authenticated;
revoke execute on function public.meu_status() from public, anon;
revoke execute on function public.vincular_conta(text) from public, anon;
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.meu_status() to authenticated;
grant execute on function public.vincular_conta(text) to authenticated;
grant execute on function public.is_admin() to authenticated;

-- =====================================================================
-- DEPOIS DE RODAR: torne-se administrador (troque o e-mail abaixo
-- pelo e-mail do usuário que você criou em Authentication > Users)
--
--   insert into public.admins (user_id, nome)
--   select id, 'Anderson' from auth.users where email = 'lcs@lcsterceirizacao.com.br';
-- =====================================================================
