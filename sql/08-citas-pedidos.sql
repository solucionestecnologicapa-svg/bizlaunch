-- =====================================================================
-- BizLaunch v9 · Agenda real de citas/reservas y pedidos con estados
--  · Las citas y los pedidos se guardan; las horas llenas se bloquean.
--  · El dueño los ve y cambia su estado desde su panel privado.
--  · El cliente sigue su pedido o cita con un código (sin datos personales).
-- Requiere 01 → 07. Se puede ejecutar más de una vez.
-- =====================================================================

-- ---------- Tablas ----------
create table if not exists public.citas (
  id          bigserial primary key,
  codigo      text not null unique,
  negocio_id  text not null references public.negocios(id) on delete cascade,
  tipo        text not null default 'cita' check (tipo in ('cita','mesa')),
  cliente     text not null,
  telefono    text not null,
  servicio    text,
  precio      numeric(10,2),
  duracion    int  not null default 30,
  personas    int  not null default 1,
  fecha       date not null,
  hora        time not null,
  nota        text,
  estado      text not null default 'pendiente'
              check (estado in ('pendiente','confirmada','completada','cancelada','no_asistio')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists citas_neg_fecha on public.citas (negocio_id, fecha, hora);

create table if not exists public.pedidos (
  id          bigserial primary key,
  codigo      text not null unique,
  negocio_id  text not null references public.negocios(id) on delete cascade,
  cliente     text not null,
  telefono    text not null,
  items       jsonb not null,
  subtotal    numeric(10,2) not null,
  envio       numeric(10,2),
  total       numeric(10,2) not null,
  modo        text not null check (modo in ('entrega','retiro')),
  direccion   text,
  ubicacion   text,
  nota        text,
  estado      text not null default 'recibido'
              check (estado in ('recibido','preparando','listo','entregado','cancelado')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists pedidos_neg_fecha on public.pedidos (negocio_id, created_at desc);

-- Nadie las lee directo: todo pasa por las funciones de abajo. El administrador sí puede verlas.
alter table public.citas   enable row level security;
alter table public.pedidos enable row level security;
revoke all on public.citas, public.pedidos from anon, authenticated;
grant select, update, delete on public.citas, public.pedidos to authenticated;
drop policy if exists citas_admin on public.citas;
create policy citas_admin on public.citas for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists pedidos_admin on public.pedidos;
create policy pedidos_admin on public.pedidos for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- Ayudantes ----------
create or replace function public.bl_codigo()
returns text language sql volatile set search_path = public as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
  from generate_series(1, 8);
$$;

create or replace function public.bl_negocio_vivo(n public.negocios)
returns boolean language sql stable as $$
  select n.active and (n.plan = 'gratis' or n.activated_at is null or n.activated_at + interval '365 days' > now());
$$;

create or replace function public.bl_tel(t text)
returns text language sql immutable as $$
  select case when length(regexp_replace(coalesce(t,''), '\D', '', 'g')) between 7 and 15
              then regexp_replace(t, '[^0-9+ -]', '', 'g') end;
$$;

-- ---------- Reservas: servicios con precio/duración y cupo por horario ----------
create or replace function public.validar_extras(m jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare r jsonb; y jsonb; dias jsonb := '[]'::jsonb; d jsonb; iv int; mp int; ant int; num text; qr text; cupo int;
  sv jsonb; servs jsonb := '[]'::jsonb; sp numeric; smin int;
  prefix text := 'https://ufybfbydbregtrvdsscw.supabase.co/storage/v1/object/public/bizlaunch-fotos/';
  out_r jsonb; out_y jsonb; tipo text;
begin
  if m is null or jsonb_typeof(m) <> 'object' then raise exception 'Datos inválidos'; end if;
  r := coalesce(m->'reservas', '{}'::jsonb);
  if jsonb_typeof(r) <> 'object' then r := '{}'::jsonb; end if;
  tipo := case when r->>'tipo' = 'mesa' then 'mesa' else 'cita' end;
  for d in select * from jsonb_array_elements(case when jsonb_typeof(r->'dias') = 'array' then r->'dias' else '[]'::jsonb end) loop
    if jsonb_typeof(d) = 'number' and (d #>> '{}')::int between 0 and 6 and not dias @> jsonb_build_array((d #>> '{}')::int) then
      dias := dias || jsonb_build_array((d #>> '{}')::int);
    end if;
  end loop;
  iv := case when jsonb_typeof(r->'intervalo') = 'number' then (r->>'intervalo')::int else 30 end;
  if iv not in (15,20,30,45,60,90,120) then iv := 30; end if;
  mp := least(50, greatest(1, case when jsonb_typeof(r->'max_personas') = 'number' then (r->>'max_personas')::int else 10 end));
  ant := least(60, greatest(1, case when jsonb_typeof(r->'anticipacion') = 'number' then (r->>'anticipacion')::int else 14 end));
  cupo := least(50, greatest(1, case when jsonb_typeof(r->'cupo') = 'number' then (r->>'cupo')::int
                                     when tipo = 'mesa' then 4 else 1 end));
  -- servicios (solo citas): nombre, precio opcional, duración en minutos
  if tipo = 'cita' and jsonb_typeof(r->'servicios') = 'array' then
    for sv in select * from jsonb_array_elements(r->'servicios') loop
      if jsonb_typeof(sv) <> 'object' or char_length(trim(coalesce(sv->>'n',''))) = 0 then continue; end if;
      if jsonb_array_length(servs) >= 30 then raise exception 'Máximo 30 servicios para citas'; end if;
      sp := case when jsonb_typeof(sv->'p') = 'number' then round((sv->>'p')::numeric, 2) end;
      if sp is not null and (sp < 0 or sp > 100000) then raise exception 'Precio inválido en "%"', sv->>'n'; end if;
      smin := case when jsonb_typeof(sv->'min') = 'number' then (sv->>'min')::int else iv end;
      smin := least(480, greatest(5, smin));
      servs := servs || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object('n', left(trim(sv->>'n'), 60), 'p', sp, 'min', smin)));
    end loop;
  end if;
  out_r := jsonb_build_object(
    'activo', coalesce((r->>'activo')::boolean, false),
    'tipo', tipo, 'dias', dias,
    'desde', case when coalesce(r->>'desde','') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then r->>'desde' else '09:00' end,
    'hasta', case when coalesce(r->>'hasta','') ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then r->>'hasta' else '18:00' end,
    'intervalo', iv, 'max_personas', mp, 'anticipacion', ant, 'cupo', cupo,
    'servicios', case when jsonb_array_length(servs) > 0 then servs end,
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

-- ---------- Menú: ahora guarda también las opciones de pedido ----------
create or replace function public.validar_menu(m jsonb, lim int)
returns jsonb language plpgsql immutable set search_path = public as $$
declare
  secs jsonb; sec jsonb; it jsonb; fotos jsonb; f jsonb;
  out_secs jsonb := '[]'::jsonb; out_items jsonb; total int := 0; p numeric;
  prefix text := 'https://ufybfbydbregtrvdsscw.supabase.co/storage/v1/object/public/bizlaunch-fotos/';
  out_fotos jsonb := '[]'::jsonb; pe jsonb; env numeric; mn numeric; out_pe jsonb;
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
  pe := m->'pedidos';
  if jsonb_typeof(pe) = 'object' then
    env := case when jsonb_typeof(pe->'envio') = 'number' then round((pe->>'envio')::numeric, 2) end;
    mn  := case when jsonb_typeof(pe->'minimo') = 'number' then round((pe->>'minimo')::numeric, 2) end;
    if env is not null and (env < 0 or env > 1000) then raise exception 'Costo de envío inválido'; end if;
    if mn is not null and (mn < 0 or mn > 10000) then raise exception 'Pedido mínimo inválido'; end if;
    out_pe := jsonb_strip_nulls(jsonb_build_object(
      'activo',  coalesce((pe->>'activo')::boolean, false),
      'entrega', coalesce((pe->>'entrega')::boolean, false),
      'retiro',  coalesce((pe->>'retiro')::boolean, true),
      'envio', env, 'minimo', mn,
      'zona', nullif(left(trim(coalesce(pe->>'zona','')), 120), ''),
      'tiempo', nullif(left(trim(coalesce(pe->>'tiempo','')), 40), '')));
    if not (out_pe->>'entrega')::boolean and not (out_pe->>'retiro')::boolean then
      out_pe := out_pe || '{"retiro":true}'::jsonb;
    end if;
  end if;
  return jsonb_strip_nulls(jsonb_build_object('secciones', out_secs, 'fotos', out_fotos,
                            'nota', nullif(left(trim(coalesce(m->>'nota','')), 200), ''), 'pedidos', out_pe));
end $$;

-- ---------- Público: horas ocupadas de un día (sin datos personales) ----------
create or replace function public.horas_ocupadas(p_id text, p_fecha date)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('h', to_char(hora, 'HH24:MI'), 'd', duracion) order by hora), '[]'::jsonb)
  from public.citas
  where negocio_id = p_id and fecha = p_fecha and estado in ('pendiente','confirmada');
$$;

-- ---------- Público: crear cita o reserva ----------
create or replace function public.crear_cita(p_id text, p_cliente text, p_telefono text, p_servicio text,
                                             p_fecha date, p_hora text, p_personas int, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; r jsonb; sv jsonb; dur int; precio numeric; serv text; cupo int;
  ahora timestamp := now() at time zone 'America/Panama'; h time; ini int; fin int; m int; usados int;
  cod text; tel text := public.bl_tel(p_telefono); nombre text := left(trim(coalesce(p_cliente,'')), 60); ppl int;
begin
  select * into n from public.negocios where id = p_id;
  if not found or not public.bl_negocio_vivo(n) then raise exception 'Este negocio no está disponible'; end if;
  if n.plan not in ('pro','premium') then raise exception 'Este negocio no recibe reservas en línea'; end if;
  r := public.validar_extras(coalesce(n.extras, '{}'::jsonb))->'reservas';
  if not coalesce((r->>'activo')::boolean, false) then raise exception 'Este negocio no está recibiendo reservas'; end if;
  if char_length(nombre) < 2 then raise exception 'Escribe tu nombre'; end if;
  if tel is null then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if coalesce(p_hora,'') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Hora inválida'; end if;
  h := p_hora::time;
  -- día permitido y dentro de la anticipación
  if p_fecha < ahora::date or p_fecha > ahora::date + (r->>'anticipacion')::int then raise exception 'Esa fecha no está disponible'; end if;
  if not (r->'dias') @> jsonb_build_array(extract(dow from p_fecha)::int) then raise exception 'Ese día no atienden'; end if;
  if p_fecha + h < ahora + interval '60 minutes' then raise exception 'Elige una hora con al menos 1 hora de anticipación'; end if;
  -- servicio y duración
  dur := (r->>'intervalo')::int; serv := nullif(left(trim(coalesce(p_servicio,'')), 60), ''); precio := null;
  if r->>'tipo' = 'cita' and jsonb_typeof(r->'servicios') = 'array' then
    select x into sv from jsonb_array_elements(r->'servicios') x where x->>'n' = serv limit 1;
    if sv is null then raise exception 'Elige un servicio'; end if;
    dur := (sv->>'min')::int; precio := (sv->>'p')::numeric;
  end if;
  -- la hora debe caer en la grilla y terminar antes del cierre
  ini := extract(hour from (r->>'desde')::time) * 60 + extract(minute from (r->>'desde')::time);
  fin := extract(hour from (r->>'hasta')::time) * 60 + extract(minute from (r->>'hasta')::time);
  if fin <= ini then fin := fin + 1440; end if;
  m := extract(hour from h) * 60 + extract(minute from h);
  if m < ini then m := m + 1440; end if;
  usados := case when r->>'tipo' = 'cita' then dur else 0 end;   -- (aquí: minutos que ocupa la cita)
  if (m - ini) % (r->>'intervalo')::int <> 0 or m + usados > fin then
    raise exception 'Esa hora no está disponible';
  end if;
  ppl := case when r->>'tipo' = 'mesa' then least((r->>'max_personas')::int, greatest(1, coalesce(p_personas, 2))) else 1 end;
  cupo := (r->>'cupo')::int;
  -- evitar que dos personas tomen el último cupo al mismo tiempo
  perform pg_advisory_xact_lock(hashtext(n.id || p_fecha::text));
  select count(*) into usados from public.citas c
   where c.negocio_id = n.id and c.fecha = p_fecha and c.estado in ('pendiente','confirmada')
     and c.hora < h + make_interval(mins => dur) and c.hora + make_interval(mins => c.duracion) > h;
  if usados >= cupo then raise exception 'Esa hora se acaba de llenar. Elige otra, por favor.'; end if;
  -- límites contra abuso
  if (select count(*) from public.citas where negocio_id = n.id and created_at > now() - interval '1 day') > 300
     or (select count(*) from public.citas where negocio_id = n.id and telefono = tel and fecha = p_fecha and estado in ('pendiente','confirmada')) >= 3
  then raise exception 'Ya tienes varias reservas para ese día. Escríbele al negocio por WhatsApp.'; end if;
  loop cod := public.bl_codigo(); exit when not exists (select 1 from public.citas where codigo = cod); end loop;
  insert into public.citas(codigo, negocio_id, tipo, cliente, telefono, servicio, precio, duracion, personas, fecha, hora, nota)
  values (cod, n.id, r->>'tipo', nombre, tel, serv, precio, dur, ppl, p_fecha, h, nullif(left(trim(coalesce(p_nota,'')), 200), ''));
  insert into public.eventos(negocio_id, tipo) values (n.id, 'reserva');
  return jsonb_build_object('codigo', cod, 'duracion', dur, 'precio', precio);
end $$;

-- ---------- Público: crear pedido (el total se calcula aquí, no en el navegador) ----------
create or replace function public.crear_pedido(p_id text, p_cliente text, p_telefono text, p_items jsonb,
                                               p_modo text, p_direccion text, p_ubicacion text, p_nota text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; pe jsonb; lim int; x jsonb; s int; i int; q int; pos int; it jsonb;
  linea jsonb := '[]'::jsonb; sub numeric := 0; env numeric; tot numeric; cod text; ub text;
  tel text := public.bl_tel(p_telefono); nombre text := left(trim(coalesce(p_cliente,'')), 60);
  dir text := nullif(left(trim(coalesce(p_direccion,'')), 300), '');
begin
  select * into n from public.negocios where id = p_id;
  if not found or not public.bl_negocio_vivo(n) then raise exception 'Este negocio no está disponible'; end if;
  lim := case n.plan when 'premium' then 200 when 'pro' then 80 when 'basico' then 25 else 0 end;
  pe := coalesce(n.menu->'pedidos', '{}'::jsonb);
  if lim = 0 or not coalesce((pe->>'activo')::boolean, false) then raise exception 'Este negocio no recibe pedidos en línea'; end if;
  if char_length(nombre) < 2 then raise exception 'Escribe tu nombre'; end if;
  if tel is null then raise exception 'Escribe un número de WhatsApp válido'; end if;
  if p_modo not in ('entrega','retiro') then raise exception 'Elige entrega o retiro'; end if;
  if p_modo = 'entrega' and not coalesce((pe->>'entrega')::boolean, false) then raise exception 'Este negocio no hace entregas'; end if;
  if p_modo = 'retiro' and not coalesce((pe->>'retiro')::boolean, true) then raise exception 'Este negocio solo hace entregas'; end if;
  if p_modo = 'entrega' and coalesce(char_length(dir), 0) < 5 then raise exception 'Escribe la dirección de entrega'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'Tu pedido está vacío'; end if;
  if jsonb_array_length(p_items) > 60 then raise exception 'Demasiados productos en un pedido'; end if;
  for x in select * from jsonb_array_elements(p_items) loop
    s := (x->>'s')::int; i := (x->>'i')::int; q := (x->>'q')::int;
    if s is null or i is null or q is null or q < 1 or q > 50 then raise exception 'Pedido inválido'; end if;
    it := n.menu->'secciones'->s->'items'->i;
    if it is null or jsonb_typeof(it->'p') <> 'number' then raise exception 'Un producto ya no está disponible. Actualiza la página.'; end if;
    select coalesce(sum(jsonb_array_length(coalesce(e->'items','[]'::jsonb))), 0) into pos
      from jsonb_array_elements(n.menu->'secciones') with ordinality t(e, k) where k <= s;
    if pos + i + 1 > lim then raise exception 'Un producto ya no está disponible. Actualiza la página.'; end if;
    linea := linea || jsonb_build_array(jsonb_build_object('n', it->>'n', 'p', (it->>'p')::numeric, 'q', q));
    sub := sub + (it->>'p')::numeric * q;
  end loop;
  if (pe->>'minimo') is not null and sub < (pe->>'minimo')::numeric then
    raise exception 'El pedido mínimo es de $%', to_char((pe->>'minimo')::numeric, 'FM999990.00');
  end if;
  env := case when p_modo = 'entrega' then (pe->>'envio')::numeric else 0 end;   -- null = a coordinar
  tot := sub + coalesce(env, 0);
  ub := case when coalesce(p_ubicacion,'') ~ '^-?[0-9]{1,2}\.[0-9]{3,8},-?[0-9]{1,3}\.[0-9]{3,8}$' then p_ubicacion end;
  if (select count(*) from public.pedidos where negocio_id = n.id and created_at > now() - interval '1 day') > 500
     or (select count(*) from public.pedidos where negocio_id = n.id and telefono = tel and created_at > now() - interval '1 hour') >= 5
  then raise exception 'Hiciste varios pedidos seguidos. Escríbele al negocio por WhatsApp.'; end if;
  loop cod := public.bl_codigo(); exit when not exists (select 1 from public.pedidos where codigo = cod); end loop;
  insert into public.pedidos(codigo, negocio_id, cliente, telefono, items, subtotal, envio, total, modo, direccion, ubicacion, nota)
  values (cod, n.id, nombre, tel, linea, sub, env, tot, p_modo, case when p_modo = 'entrega' then dir end, ub,
          nullif(left(trim(coalesce(p_nota,'')), 200), ''));
  insert into public.eventos(negocio_id, tipo) values (n.id, 'whatsapp');
  return jsonb_build_object('codigo', cod, 'subtotal', sub, 'envio', env, 'total', tot, 'items', linea);
end $$;

-- ---------- Público: seguimiento por código (sin nombre ni teléfono) ----------
create or replace function public.seguimiento(p_codigo text)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(
    (select jsonb_build_object('tipo', 'pedido', 'codigo', p.codigo, 'negocio_id', n.id, 'negocio', n.name, 'whatsapp', n.whatsapp,
            'estado', p.estado, 'modo', p.modo, 'items', p.items, 'subtotal', p.subtotal, 'envio', p.envio, 'total', p.total,
            'tiempo', n.menu->'pedidos'->>'tiempo', 'created_at', p.created_at, 'updated_at', p.updated_at)
       from public.pedidos p join public.negocios n on n.id = p.negocio_id where p.codigo = upper(trim(p_codigo))),
    (select jsonb_build_object('tipo', c.tipo, 'codigo', c.codigo, 'negocio_id', n.id, 'negocio', n.name, 'whatsapp', n.whatsapp,
            'estado', c.estado, 'servicio', c.servicio, 'precio', c.precio, 'duracion', c.duracion, 'personas', c.personas,
            'fecha', c.fecha, 'hora', to_char(c.hora, 'HH24:MI'), 'created_at', c.created_at, 'updated_at', c.updated_at)
       from public.citas c join public.negocios n on n.id = c.negocio_id where c.codigo = upper(trim(p_codigo))));
$$;

-- El cliente puede cancelar su cita con el código (hasta 1 hora antes)
create or replace function public.cancelar_cita_cliente(p_codigo text)
returns void language plpgsql security definer set search_path = public as $$
declare c public.citas%rowtype;
begin
  select * into c from public.citas where codigo = upper(trim(p_codigo));
  if not found then raise exception 'No encontramos esa reserva'; end if;
  if c.estado not in ('pendiente','confirmada') then raise exception 'Esta reserva ya no se puede cancelar'; end if;
  if c.fecha + c.hora < (now() at time zone 'America/Panama') + interval '60 minutes' then
    raise exception 'Falta menos de 1 hora: escríbele al negocio por WhatsApp'; end if;
  update public.citas set estado = 'cancelada', updated_at = now() where id = c.id;
end $$;

-- ---------- Dueño: ver y atender ----------
create or replace function public.bandeja_dueno(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare n public.negocios%rowtype; hoy date := (now() at time zone 'America/Panama')::date;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  return jsonb_build_object(
    'pedidos', (select coalesce(jsonb_agg(to_jsonb(p) - 'negocio_id' order by p.created_at desc), '[]'::jsonb) from (
        select * from public.pedidos where negocio_id = n.id
          and (created_at > now() - interval '3 days' or estado in ('recibido','preparando','listo'))
        order by created_at desc limit 150) p),
    'citas', (select coalesce(jsonb_agg(to_jsonb(c) - 'negocio_id' order by c.fecha, c.hora), '[]'::jsonb) from (
        select id, codigo, negocio_id, tipo, cliente, telefono, servicio, precio, duracion, personas, fecha,
               to_char(hora, 'HH24:MI') as hora, nota, estado, created_at, updated_at
        from public.citas where negocio_id = n.id and fecha between hoy - 1 and hoy + 60
        order by fecha, hora limit 400) c));
end $$;

create or replace function public.estado_pedido_dueno(p_token uuid, p_id bigint, p_estado text)
returns void language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  if p_estado not in ('recibido','preparando','listo','entregado','cancelado') then raise exception 'Estado inválido'; end if;
  update public.pedidos set estado = p_estado, updated_at = now() where id = p_id and negocio_id = n.id;
  if not found then raise exception 'No encontramos ese pedido'; end if;
end $$;

create or replace function public.estado_cita_dueno(p_token uuid, p_id bigint, p_estado text)
returns void language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  if p_estado not in ('pendiente','confirmada','completada','cancelada','no_asistio') then raise exception 'Estado inválido'; end if;
  update public.citas set estado = p_estado, updated_at = now() where id = p_id and negocio_id = n.id;
  if not found then raise exception 'No encontramos esa reserva'; end if;
end $$;

-- ---------- Permisos ----------
revoke execute on function public.bl_codigo() from public, anon, authenticated;
revoke execute on function public.horas_ocupadas(text, date) from public;
revoke execute on function public.crear_cita(text, text, text, text, date, text, int, text) from public;
revoke execute on function public.crear_pedido(text, text, text, jsonb, text, text, text, text) from public;
revoke execute on function public.seguimiento(text) from public;
revoke execute on function public.cancelar_cita_cliente(text) from public;
revoke execute on function public.bandeja_dueno(uuid) from public;
revoke execute on function public.estado_pedido_dueno(uuid, bigint, text) from public;
revoke execute on function public.estado_cita_dueno(uuid, bigint, text) from public;
grant execute on function public.horas_ocupadas(text, date) to anon, authenticated;
grant execute on function public.crear_cita(text, text, text, text, date, text, int, text) to anon, authenticated;
grant execute on function public.crear_pedido(text, text, text, jsonb, text, text, text, text) to anon, authenticated;
grant execute on function public.seguimiento(text) to anon, authenticated;
grant execute on function public.cancelar_cita_cliente(text) to anon, authenticated;
grant execute on function public.bandeja_dueno(uuid) to anon, authenticated;
grant execute on function public.estado_pedido_dueno(uuid, bigint, text) to anon, authenticated;
grant execute on function public.estado_cita_dueno(uuid, bigint, text) to anon, authenticated;
