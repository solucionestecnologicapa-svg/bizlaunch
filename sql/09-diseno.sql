-- =====================================================================
-- BizLaunch v10 · Diseño propio para la página de cada negocio
--  · negocios.diseno = { "tema": "terracota", "color": "#C2410C" }
--  · El dueño lo elige en su panel (Básico en adelante; color propio en Pro/Premium).
-- Se puede ejecutar más de una vez.
-- =====================================================================
alter table public.negocios add column if not exists diseno jsonb not null default '{}'::jsonb;
grant select (diseno) on public.negocios to anon;
grant select (diseno), update (diseno) on public.negocios to authenticated;

create or replace function public.guardar_diseno_dueno(p_token uuid, p_diseno jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; t text; c text; out jsonb;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  if n.plan = 'gratis' then raise exception 'Elegir el diseño está disponible desde el plan Básico'; end if;
  if p_diseno is null or jsonb_typeof(p_diseno) <> 'object' then raise exception 'Diseño inválido'; end if;
  t := nullif(p_diseno->>'tema', '');
  -- cualquier id de diseño corto (la web cae al diseño automático si no lo conoce)
  if t is not null and t !~ '^[a-z]{3,20}$' then
    raise exception 'Ese diseño no existe'; end if;
  c := nullif(p_diseno->>'color', '');
  if c is not null and (c !~ '^#[0-9A-Fa-f]{6}$' or n.plan not in ('pro','premium')) then c := null; end if;
  out := jsonb_strip_nulls(jsonb_build_object('tema', t, 'color', c));
  update public.negocios set diseno = out, updated_at = now() where id = n.id;
  return out;
end $$;
revoke execute on function public.guardar_diseno_dueno(uuid, jsonb) from public;
grant execute on function public.guardar_diseno_dueno(uuid, jsonb) to anon, authenticated;
