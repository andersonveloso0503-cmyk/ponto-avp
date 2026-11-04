-- Ponto AVP — o app segue os ajustes do RH (próximo botão e jornada atual)

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
