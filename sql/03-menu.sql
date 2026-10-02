-- =====================================================================
-- BizLaunch v4 · Menú / lista de precios por negocio
-- Requiere haber ejecutado antes bizlaunch-v3.sql
-- =====================================================================

alter table public.negocios add column if not exists menu jsonb not null default '{}'::jsonb;
grant select (menu) on public.negocios to anon;

-- Valida y limpia el menú (solo guarda los campos permitidos)
create or replace function public.validar_menu(m jsonb, lim int)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  secs jsonb; sec jsonb; it jsonb; fotos jsonb; f jsonb;
  out_secs jsonb := '[]'::jsonb; out_items jsonb; total int := 0; p numeric;
  prefix text := 'https://ufybfbydbregtrvdsscw.supabase.co/storage/v1/object/public/bizlaunch-fotos/';
  out_fotos jsonb := '[]'::jsonb;
begin
  if m is null or jsonb_typeof(m) <> 'object' then raise exception 'Menú inválido'; end if;
  if pg_column_size(m) > 120000 then raise exception 'El menú es demasiado grande'; end if;
  secs := coalesce(m->'secciones', '[]'::jsonb);
  if jsonb_typeof(secs) <> 'array' then raise exception 'Menú inválido'; end if;
  if jsonb_array_length(secs) > 15 then raise exception 'Máximo 15 secciones'; end if;
  for sec in select * from jsonb_array_elements(secs) loop
    out_items := '[]'::jsonb;
    for it in select * from jsonb_array_elements(coalesce(sec->'items', '[]'::jsonb)) loop
      if char_length(trim(coalesce(it->>'n',''))) = 0 then continue; end if;
      total := total + 1;
      if total > lim then raise exception 'Tu plan permite hasta % platos o servicios', lim; end if;
      p := null;
      if jsonb_typeof(it->'p') = 'number' then
        p := (it->>'p')::numeric;
        if p < 0 or p > 100000 then raise exception 'Precio inválido en "%"', it->>'n'; end if;
      end if;
      out_items := out_items || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
        'n', left(trim(it->>'n'), 80),
        'd', nullif(left(trim(coalesce(it->>'d','')), 200), ''),
        'p', round(p, 2),
        'top', case when (it->>'top')::boolean then true end)));
    end loop;
    if jsonb_array_length(out_items) > 0 or char_length(trim(coalesce(sec->>'nombre',''))) > 0 then
      out_secs := out_secs || jsonb_build_array(jsonb_build_object(
        'nombre', left(trim(coalesce(sec->>'nombre','')), 60), 'items', out_items));
    end if;
  end loop;
  fotos := coalesce(m->'fotos', '[]'::jsonb);
  if jsonb_typeof(fotos) <> 'array' then raise exception 'Menú inválido'; end if;
  for f in select * from jsonb_array_elements(fotos) loop
    if jsonb_typeof(f) = 'string' and left(f #>> '{}', length(prefix)) = prefix then
      out_fotos := out_fotos || jsonb_build_array(f);
    end if;
  end loop;
  if jsonb_array_length(out_fotos) > 4 then raise exception 'Máximo 4 fotos del menú'; end if;
  return jsonb_build_object('secciones', out_secs, 'fotos', out_fotos,
                            'nota', nullif(left(trim(coalesce(m->>'nota','')), 200), ''));
end $$;

create or replace function public.guardar_menu_dueno(p_token uuid, p_menu jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; lim int;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  lim := case n.plan when 'premium' then 200 when 'pro' then 80 else 25 end;
  update public.negocios set menu = public.validar_menu(p_menu, lim), updated_at = now() where id = n.id;
end $$;

-- panel del dueño: ahora también devuelve el menú
create or replace function public.panel_negocio(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare n public.negocios%rowtype; hoy date := (now() at time zone 'America/Panama')::date;
begin
  select * into n from public.negocios where stats_token = p_token;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', n.id, 'name', n.name, 'plan', n.plan, 'active', n.active, 'activated_at', n.activated_at,
    'slug', n.slug, 'category', n.category, 'province', n.province, 'photo', n.photos->>0,
    'visit_count', n.visit_count, 'menu', coalesce(n.menu, '{}'::jsonb),
    'actual', (select coalesce(jsonb_object_agg(tipo, c), '{}'::jsonb) from (
        select tipo, count(*) c from public.eventos
        where negocio_id = n.id and created_at >= now() - interval '30 days' group by tipo) a),
    'anterior', (select coalesce(jsonb_object_agg(tipo, c), '{}'::jsonb) from (
        select tipo, count(*) c from public.eventos
        where negocio_id = n.id and created_at >= now() - interval '60 days'
          and created_at < now() - interval '30 days' group by tipo) b),
    'diario', (select coalesce(jsonb_agg(jsonb_build_object(
          'dia', g.d, 'visitas', coalesce(e.v,0), 'whatsapp', coalesce(e.w,0)) order by g.d), '[]'::jsonb)
        from (select (hoy - i) as d from generate_series(0, 29) i) g
        left join (select (created_at at time zone 'America/Panama')::date dia,
                          count(*) filter (where tipo='visita') v,
                          count(*) filter (where tipo='whatsapp') w
                   from public.eventos where negocio_id = n.id and created_at >= now() - interval '31 days'
                   group by 1) e on e.dia = g.d),
    'ofertas', (select coalesce(jsonb_agg(jsonb_build_object(
          'id', o.id, 'titulo', o.titulo, 'descripcion', o.descripcion, 'precio_antes', o.precio_antes,
          'precio_ahora', o.precio_ahora, 'vence', o.vence, 'activa', o.activa, 'aprobada', o.aprobada)
          order by o.created_at desc), '[]'::jsonb)
        from public.ofertas o where o.negocio_id = n.id),
    'resenas', (select jsonb_build_object('total', count(*), 'promedio', round(avg(estrellas)::numeric, 1))
        from public.resenas where negocio_id = n.id and aprobada)
  );
end $$;
