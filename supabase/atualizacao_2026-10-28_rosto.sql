-- Ponto AVP — atualização 28/10/2026: reconhecimento facial
alter table public.colaboradores add column if not exists face_ref double precision[];
alter table public.colaboradores add column if not exists face_foto_path text;
alter table public.colaboradores add column if not exists face_cadastrado_em timestamptz;
alter table public.registros add column if not exists face_status text;
alter table public.registros add column if not exists face_dist double precision;

create or replace function public.face_distancia(a double precision[], b double precision[])
returns double precision language sql immutable set search_path = public as $$
  select case when a is null or b is null or array_length(a, 1) is distinct from array_length(b, 1) then null
         else (select sqrt(sum((x - y) ^ 2)) from unnest(a, b) as t(x, y)) end;
$$;

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

revoke execute on function public.bater_ponto(double precision, double precision, double precision, text, text, text, double precision[]) from public, anon;
grant execute on function public.bater_ponto(double precision, double precision, double precision, text, text, text, double precision[]) to authenticated;
revoke execute on function public.meu_status() from public, anon;
grant execute on function public.meu_status() to authenticated;
revoke execute on function public.cadastrar_rosto(double precision[], text) from public, anon;
grant execute on function public.cadastrar_rosto(double precision[], text) to authenticated;
revoke execute on function public.face_distancia(double precision[], double precision[]) from public, anon, authenticated;
