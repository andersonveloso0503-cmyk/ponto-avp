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

-- postos podem ser criados sem local (vindos da planilha); o ponto fica bloqueado até marcar no mapa
alter table public.postos alter column lat drop not null;
alter table public.postos alter column lng drop not null;
alter table public.colaboradores add column if not exists empresa text;

-- reconhecimento facial: foto de cadastro do rosto (vetor de 128 números) e resultado em cada batida
alter table public.colaboradores add column if not exists face_ref double precision[];
alter table public.colaboradores add column if not exists face_foto_path text;
alter table public.colaboradores add column if not exists face_cadastrado_em timestamptz;

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
alter table public.registros add column if not exists face_status text;   -- ok | nao_confere | sem_rosto | sem_cadastro
alter table public.registros add column if not exists face_dist double precision;
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

-- distância entre dois rostos (vetores de 128 números). Mesma pessoa: normalmente abaixo de 0,5
create or replace function public.face_distancia(a double precision[], b double precision[])
returns double precision language sql immutable set search_path = public as $$
  select case when a is null or b is null or array_length(a, 1) is distinct from array_length(b, 1) then null
         else (select sqrt(sum((x - y) ^ 2)) from unnest(a, b) as t(x, y)) end;
$$;

create or replace function public.normaliza_nome(t text)
returns text language sql immutable as $$
  select regexp_replace(lower(extensions.unaccent(coalesce(t, ''))), '\s+', ' ', 'g');
$$;

-- primeiro acesso: basta o primeiro nome bater (sem acento, maiúscula ou espaço sobrando)
create or replace function public.primeiro_nome_confere(cadastro text, digitado text)
returns boolean language sql immutable set search_path = public, extensions as $$
  select split_part(public.normaliza_nome(trim(cadastro)), ' ', 1) <> ''
     and split_part(public.normaliza_nome(trim(cadastro)), ' ', 1) = split_part(public.normaliza_nome(trim(digitado)), ' ', 1);
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
  if not public.primeiro_nome_confere(c.nome, p_nome) then
    return json_build_object('ok', false, 'motivo', 'O nome não confere com o cadastro. Digite seu primeiro nome.');
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
     or not public.primeiro_nome_confere(c.nome, p_nome) then
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
declare ult public.registros; v_gap interval;
begin
  select * into ult from public.registros
   where colaborador_id = p_colab order by registrado_em desc limit 1;
  if not found then
    return array['entrada'];
  end if;
  v_gap := now() - ult.registrado_em;
  if ult.tipo = 'saida' or v_gap > interval '16 hours' then
    return array['entrada'];
  elsif ult.tipo = 'saida_intervalo' then
    -- intervalo não passa de algumas horas: se passou de 10h, esqueceram a saída — começa nova jornada
    if v_gap > interval '10 hours' then return array['entrada']; end if;
    return array['volta_intervalo'];
  elsif ult.tipo = 'volta_intervalo' then
    return array['saida', 'saida_intervalo'];   -- depois do intervalo, o normal é encerrar o dia
  else  -- entrada
    return array['saida_intervalo', 'saida'];
  end if;
end;
$$;

-- (meu_status fica mais abaixo, junto com as rondas)

-- A ÚNICA forma de gravar um ponto. Confere posto, distância, GPS e selfie.
drop function if exists public.bater_ponto(double precision, double precision, double precision, text, text, text);
create or replace function public.bater_ponto(
  p_lat double precision, p_lng double precision, p_precisao double precision,
  p_foto text, p_tipo text default null, p_dispositivo text default null,
  p_face double precision[] default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  c public.colaboradores; p public.postos;
  v_dist double precision; v_permitidos text[]; v_tipo text;
  v_ultimo timestamptz; v_hash_ant text; v_hash text; v_ts timestamptz := now();
  r public.registros; v_motivo text; v_face_dist double precision; v_face_status text;
begin
  select * into c from public.colaboradores where user_id = auth.uid();
  if not found or not c.ativo then
    return json_build_object('ok', false, 'motivo', 'Cadastro não encontrado ou inativo. Fale com o RH.');
  end if;

  select * into p from public.postos where id = c.posto_id and ativo;
  if not found then
    return json_build_object('ok', false, 'motivo', 'Você não está ligado a um posto. Fale com o RH.');
  end if;

  if p.lat is null or p.lng is null then
    return json_build_object('ok', false, 'motivo', format('O local do posto %s ainda não foi marcado no mapa. Fale com o RH.', p.nome));
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

  -- reconhecimento facial: não bloqueia, só marca para o empregador conferir
  v_face_dist := public.face_distancia(c.face_ref, p_face);
  v_face_status := case when c.face_ref is null then 'sem_cadastro'
                        when p_face is null or v_face_dist is null then 'sem_rosto'
                        when v_face_dist <= 0.55 then 'ok'
                        else 'nao_confere' end;

  -- assinatura encadeada: qualquer alteração por fora quebra a sequência
  v_hash := encode(extensions.digest(concat_ws('|', coalesce(v_hash_ant, 'inicio'), c.cpf, v_tipo,
                                    to_char(v_ts at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
                                    p_lat, p_lng, p.id), 'sha256'), 'hex');

  insert into public.registros (colaborador_id, posto_id, tipo, registrado_em, lat, lng,
                                precisao_m, distancia_m, foto_path, dispositivo, hash, face_status, face_dist)
  values (c.id, p.id, v_tipo, v_ts, p_lat, p_lng, p_precisao, v_dist, p_foto, left(p_dispositivo, 300), v_hash,
          v_face_status, v_face_dist)
  returning * into r;

  return json_build_object('ok', true,
    'registro', json_build_object('nsr', r.id, 'tipo', r.tipo, 'registrado_em', r.registrado_em,
                                  'distancia_m', round(r.distancia_m), 'hash', r.hash, 'face_status', r.face_status),
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

revoke all on function public.bater_ponto(double precision, double precision, double precision, text, text, text, double precision[]) from public, anon;
grant execute on function public.bater_ponto(double precision, double precision, double precision, text, text, text, double precision[]) to authenticated;
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

  if p_lat is not null and p_lng is not null and p.lat is not null then
    v_dist := public.distancia_m(p_lat, p_lng, p.lat, p.lng);
  end if;

  if pr.posto_id is distinct from c.posto_id then
    v_motivo := format('Este QR Code é do posto %s, e você está alocado em outro posto.', p.nome);
  elsif p.lat is null or p.lng is null then
    v_motivo := format('O local do posto %s ainda não foi marcado no mapa. Fale com o RH.', p.nome);
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

-- cadastro do rosto (uma vez; para refazer, o RH apaga pelo painel)
create or replace function public.cadastrar_rosto(p_face double precision[], p_foto text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare c public.colaboradores;
begin
  select * into c from public.colaboradores where user_id = auth.uid();
  if not found or not c.ativo then
    return json_build_object('ok', false, 'motivo', 'Cadastro não encontrado ou inativo. Fale com o RH.');
  end if;
  if coalesce(array_length(p_face, 1), 0) <> 128 then
    return json_build_object('ok', false, 'motivo', 'Não consegui ler seu rosto. Tente de novo com boa luz.');
  end if;
  if p_foto is null or split_part(p_foto, '/', 1) <> auth.uid()::text then
    return json_build_object('ok', false, 'motivo', 'Foto de cadastro obrigatória.');
  end if;
  if c.face_ref is not null then
    return json_build_object('ok', false, 'motivo', 'Seu rosto já está cadastrado. Para refazer, fale com o RH.');
  end if;
  update public.colaboradores set face_ref = p_face, face_foto_path = p_foto, face_cadastrado_em = now() where id = c.id;
  return json_build_object('ok', true);
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
  if v_ini is null and not ('entrada' = any(public.tipos_permitidos(c.id))) then
    -- jornada sem 'entrada' (ex.: começou por engano com volta do intervalo): mostra desde a última saída
    select min(e.registrado_em) into v_ini from public.registros e
     where e.colaborador_id = c.id and e.registrado_em > now() - interval '12 hours'
       and e.registrado_em > coalesce((select max(x.registrado_em) from public.registros x
                                        where x.colaborador_id = c.id and x.tipo = 'saida'), '-infinity'::timestamptz);
  end if;
  return json_build_object(
    'ok', true,
    'colaborador', json_build_object('id', c.id, 'nome', c.nome, 'funcao', c.funcao, 'ativo', c.ativo,
                                     'rosto_cadastrado', c.face_ref is not null),
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
revoke execute on function public.primeiro_nome_confere(text, text) from public, anon, authenticated;
revoke execute on function public.cadastrar_rosto(double precision[], text) from public, anon;
grant execute on function public.cadastrar_rosto(double precision[], text) to authenticated;
revoke execute on function public.face_distancia(double precision[], double precision[]) from public, anon, authenticated;

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


-- marcações que valem (originais + ajustes do RH): usada para decidir o próximo botão e a jornada atual
create or replace function public.marcas_efetivas(p_colab bigint, p_desde timestamptz default now() - interval '3 days')
returns table(registro_id bigint, tipo text, registrado_em timestamptz, rh boolean)
language sql stable security definer set search_path = public as $$
  select r.id, coalesce(a.tipo, r.tipo), r.registrado_em, a.id is not null
    from public.registros r
    left join public.ajustes a on a.registro_id = r.id and a.anulado_em is null
   where r.colaborador_id = p_colab and r.registrado_em >= p_desde and coalesce(a.acao, '') <> 'desconsiderar'
  union all
  select null, a.tipo, a.marcacao_em, true
    from public.ajustes a
   where a.colaborador_id = p_colab and a.acao = 'incluir' and a.anulado_em is null
     and a.marcacao_em >= p_desde and a.marcacao_em <= now();
$$;
revoke execute on function public.marcas_efetivas(bigint, timestamptz) from public, anon, authenticated;

create or replace function public.tipos_permitidos(p_colab bigint)
returns text[] language plpgsql stable security definer set search_path = public, extensions as $$
declare ult record; v_gap interval;
begin
  select * into ult from public.marcas_efetivas(p_colab) m order by m.registrado_em desc limit 1;
  if not found then
    return array['entrada'];
  end if;
  v_gap := now() - ult.registrado_em;
  if ult.tipo = 'saida' or v_gap > interval '16 hours' then
    return array['entrada'];
  elsif ult.tipo = 'saida_intervalo' then
    if v_gap > interval '10 hours' then return array['entrada']; end if;
    return array['volta_intervalo'];
  elsif ult.tipo = 'volta_intervalo' then
    return array['saida', 'saida_intervalo'];
  else
    return array['saida_intervalo', 'saida'];
  end if;
end;
$$;
revoke execute on function public.tipos_permitidos(bigint) from public, anon, authenticated;

create or replace function public.meu_status()
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare c public.colaboradores; p public.postos; v_ini timestamptz;
begin
  select * into c from public.colaboradores where user_id = auth.uid();
  if not found then
    return json_build_object('ok', false, 'motivo', 'Cadastro não encontrado.');
  end if;
  select * into p from public.postos where id = c.posto_id;
  if not ('entrada' = any(public.tipos_permitidos(c.id))) then
    select max(m.registrado_em) into v_ini from public.marcas_efetivas(c.id) m
     where m.tipo = 'entrada' and m.registrado_em > now() - interval '18 hours';
    if v_ini is null then
      select min(m.registrado_em) into v_ini from public.marcas_efetivas(c.id) m
       where m.registrado_em > now() - interval '12 hours'
         and m.registrado_em > coalesce((select max(x.registrado_em) from public.marcas_efetivas(c.id) x
                                          where x.tipo = 'saida'), '-infinity'::timestamptz);
    end if;
  else
    -- jornada encerrada: mostra a última jornada (desde a última entrada) por até 18h
    select max(m.registrado_em) into v_ini from public.marcas_efetivas(c.id) m
     where m.tipo = 'entrada' and m.registrado_em > now() - interval '18 hours';
  end if;
  return json_build_object(
    'ok', true,
    'colaborador', json_build_object('id', c.id, 'nome', c.nome, 'funcao', c.funcao, 'ativo', c.ativo,
                                     'rosto_cadastrado', c.face_ref is not null),
    'posto', case when p.id is null then null else
             json_build_object('id', p.id, 'nome', p.nome, 'lat', p.lat, 'lng', p.lng,
                               'raio_m', p.raio_m, 'ativo', p.ativo) end,
    'permitidos', public.tipos_permitidos(c.id),
    'hoje', coalesce((
      select json_agg(json_build_object('id', m.registro_id, 'tipo', m.tipo, 'registrado_em', m.registrado_em, 'rh', m.rh)
                      order by m.registrado_em)
        from public.marcas_efetivas(c.id) m
       where m.registrado_em >= coalesce(v_ini, now())
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
revoke execute on function public.meu_status() from public, anon;
grant execute on function public.meu_status() to authenticated;

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

-- =====================================================================
-- DEPOIS DE RODAR: torne-se administrador (troque o e-mail abaixo
-- pelo e-mail do usuário que você criou em Authentication > Users)
--
--   insert into public.admins (user_id, nome)
--   select id, 'Anderson' from auth.users where email = 'lcs@lcsterceirizacao.com.br';
-- =====================================================================
