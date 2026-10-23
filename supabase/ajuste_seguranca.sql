-- Ponto AVP — ajuste de segurança (rodar uma vez, depois do schema.sql)
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
