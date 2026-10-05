-- =====================================================================
-- BizLaunch v8 · El dueño responde las reseñas desde su panel
-- =====================================================================
alter table public.resenas add column if not exists respuesta text;
alter table public.resenas add column if not exists respondida_at timestamptz;
grant select (respuesta, respondida_at) on public.resenas to anon, authenticated;

-- Reseñas aprobadas del negocio del dueño (para su panel)
create or replace function public.resenas_dueno(p_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'autor', r.autor, 'estrellas', r.estrellas, 'comentario', r.comentario,
           'created_at', r.created_at, 'respuesta', r.respuesta, 'respondida_at', r.respondida_at) order by r.created_at desc), '[]'::jsonb)
  from public.resenas r join public.negocios n on n.id = r.negocio_id
  where n.stats_token = p_token and r.aprobada;
$$;

-- Guardar (o borrar, si viene vacío) la respuesta del dueño
create or replace function public.responder_resena_dueno(p_token uuid, p_id integer, p_texto text)
returns void language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; t text := nullif(left(trim(coalesce(p_texto, '')), 400), '');
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  update public.resenas set respuesta = t, respondida_at = case when t is null then null else now() end
   where id = p_id and negocio_id = n.id and aprobada;
  if not found then raise exception 'No encontramos esa reseña'; end if;
end $$;

revoke execute on function public.resenas_dueno(uuid) from public;
revoke execute on function public.responder_resena_dueno(uuid, integer, text) from public;
grant execute on function public.resenas_dueno(uuid) to anon, authenticated;
grant execute on function public.responder_resena_dueno(uuid, integer, text) to anon, authenticated;
