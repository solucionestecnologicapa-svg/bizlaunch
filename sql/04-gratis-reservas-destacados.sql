-- =====================================================================
-- BizLaunch v5 · Plan Gratis, reservas, Yappy y destacados
-- Requiere haber ejecutado antes v3 y v4
-- =====================================================================

alter table public.negocios add column if not exists extras jsonb not null default '{}'::jsonb;
alter table public.negocios add column if not exists destacado_hasta timestamptz;
grant select (extras, destacado_hasta) on public.negocios to anon;

-- Registro público: nunca puede venir destacado ni con extras ya configurados
drop policy if exists neg_anon_ins on public.negocios;
create policy neg_anon_ins on public.negocios for insert to anon
  with check (active = false and coalesce(visit_count,0) = 0 and activated_at is null
              and destacado_hasta is null and extras = '{}'::jsonb
              and plan in ('gratis','basico','pro','premium'));

-- Nuevos tipos de evento
alter table public.eventos drop constraint if exists eventos_tipo_check;
alter table public.eventos add constraint eventos_tipo_check
  check (tipo in ('visita','whatsapp','llamada','mapa','web','compartir','oferta','reserva','yappy'));

create or replace function public.registrar_evento(p_id text, p_tipo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_tipo not in ('visita','whatsapp','llamada','mapa','web','compartir','oferta','reserva','yappy') then return; end if;
  if not exists (select 1 from public.negocios where id = p_id and active) then return; end if;
  insert into public.eventos(negocio_id, tipo) values (p_id, p_tipo);
  if p_tipo = 'visita' then
    update public.negocios set visit_count = coalesce(visit_count,0) + 1 where id = p_id;
  end if;
end $$;

-- Plan Gratis: sin menú ni ofertas
create or replace function public.guardar_menu_dueno(p_token uuid, p_menu jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; lim int;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  lim := case n.plan when 'premium' then 200 when 'pro' then 80 when 'basico' then 25 else 0 end;
  if lim = 0 then raise exception 'El menú está disponible desde el plan Básico'; end if;
  update public.negocios set menu = public.validar_menu(p_menu, lim), updated_at = now() where id = n.id;
end $$;

create or replace function public.crear_oferta_dueno(p_token uuid, p_titulo text, p_descripcion text,
  p_precio_antes numeric, p_precio_ahora numeric, p_vence date)
returns bigint language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; lim int; cnt int; nid bigint;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  lim := case n.plan when 'premium' then 3 when 'pro' then 2 when 'basico' then 1 else 0 end;
  if lim = 0 then raise exception 'Las ofertas están disponibles desde el plan Básico'; end if;
  select count(*) into cnt from public.ofertas
   where negocio_id = n.id and activa and (vence is null or vence >= current_date);
  if cnt >= lim then raise exception 'Tu plan permite % oferta(s) activa(s) a la vez', lim; end if;
  if char_length(trim(coalesce(p_titulo,''))) < 3 then raise exception 'El título es muy corto'; end if;
  if p_vence is not null and p_vence < current_date then raise exception 'La fecha de vencimiento ya pasó'; end if;
  insert into public.ofertas(negocio_id, titulo, descripcion, precio_antes, precio_ahora, vence, aprobada, origen)
  values (n.id, left(trim(p_titulo), 80), left(trim(coalesce(p_descripcion,'')), 300),
          p_precio_antes, p_precio_ahora, p_vence, false, 'dueno')
  returning id into nid;
  return nid;
end $$;

-- Reservas + Yappy: valida y limpia
create or replace function public.validar_extras(m jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare r jsonb; y jsonb; dias jsonb := '[]'::jsonb; d jsonb; iv int; mp int; ant int; num text; qr text;
  prefix text := 'https://ufybfbydbregtrvdsscw.supabase.co/storage/v1/object/public/bizlaunch-fotos/';
  out_r jsonb; out_y jsonb;
begin
  if m is null or jsonb_typeof(m) <> 'object' then raise exception 'Datos inválidos'; end if;
  r := coalesce(m->'reservas', '{}'::jsonb);
  if jsonb_typeof(r) <> 'object' then r := '{}'::jsonb; end if;
  for d in select * from jsonb_array_elements(case when jsonb_typeof(r->'dias') = 'array' then r->'dias' else '[]'::jsonb end) loop
    if jsonb_typeof(d) = 'number' and (d #>> '{}')::int between 0 and 6 and not dias @> jsonb_build_array((d #>> '{}')::int) then
      dias := dias || jsonb_build_array((d #>> '{}')::int);
    end if;
  end loop;
  iv := case when jsonb_typeof(r->'intervalo') = 'number' then (r->>'intervalo')::int else 30 end;
  if iv not in (15,20,30,45,60,90,120) then iv := 30; end if;
  mp := least(50, greatest(1, case when jsonb_typeof(r->'max_personas') = 'number' then (r->>'max_personas')::int else 10 end));
  ant := least(60, greatest(1, case when jsonb_typeof(r->'anticipacion') = 'number' then (r->>'anticipacion')::int else 14 end));
  out_r := jsonb_build_object(
    'activo', coalesce((r->>'activo')::boolean, false),
    'tipo', case when r->>'tipo' = 'mesa' then 'mesa' else 'cita' end,
    'dias', dias,
    'desde', case when coalesce(r->>'desde','') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then r->>'desde' else '09:00' end,
    'hasta', case when coalesce(r->>'hasta','') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then r->>'hasta' else '18:00' end,
    'intervalo', iv, 'max_personas', mp, 'anticipacion', ant,
    'nota', nullif(left(trim(coalesce(r->>'nota','')), 150), ''));
  y := coalesce(m->'yappy', '{}'::jsonb);
  if jsonb_typeof(y) <> 'object' then y := '{}'::jsonb; end if;
  num := left(trim(coalesce(y->>'numero','')), 40);
  if num !~ '^[0-9A-Za-z+@ ._-]*$' then raise exception 'El número o usuario de Yappy tiene caracteres no válidos'; end if;
  qr := coalesce(y->>'qr','');
  if qr <> '' and left(qr, length(prefix)) <> prefix then qr := ''; end if;
  out_y := jsonb_strip_nulls(jsonb_build_object('numero', nullif(num,''), 'qr', nullif(qr,''),
                                                'nombre', nullif(left(trim(coalesce(y->>'nombre','')), 60), '')));
  return jsonb_build_object('reservas', jsonb_strip_nulls(out_r), 'yappy', out_y);
end $$;

create or replace function public.guardar_extras_dueno(p_token uuid, p_extras jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  if n.plan not in ('pro','premium') then raise exception 'Reservas y Yappy están disponibles en los planes Pro y Premium'; end if;
  update public.negocios set extras = public.validar_extras(p_extras), updated_at = now() where id = n.id;
end $$;

-- Panel del dueño: ahora incluye extras y destacado
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
    'extras', coalesce(n.extras, '{}'::jsonb), 'destacado_hasta', n.destacado_hasta,
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
                          count(*) filter (where tipo in ('whatsapp','reserva')) w
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
