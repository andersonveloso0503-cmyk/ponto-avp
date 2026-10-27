-- Ponto AVP — atualização 27/10/2026
-- Postos podem ficar sem local (criados pela planilha) e colaborador ganha o campo "empresa" (AVP/TRI).
alter table public.postos alter column lat drop not null;
alter table public.postos alter column lng drop not null;
alter table public.colaboradores add column if not exists empresa text;

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
