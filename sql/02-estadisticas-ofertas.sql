-- =====================================================================
-- BizLaunch v3 · Estadísticas, clics de WhatsApp, ofertas y páginas por negocio
-- Requiere haber ejecutado antes bizlaunch-seguridad.sql
-- =====================================================================

-- ---------- 1. Slug (dirección de la página) y token del panel del dueño ----------
alter table public.negocios add column if not exists slug text;
alter table public.negocios add column if not exists stats_token uuid default gen_random_uuid();
update public.negocios set stats_token = gen_random_uuid() where stats_token is null;
create unique index if not exists negocios_slug_key        on public.negocios(slug);
create unique index if not exists negocios_stats_token_key on public.negocios(stats_token);

create or replace function public.slugify(t text)
returns text language sql immutable set search_path = public as $$
  select coalesce(nullif(trim(both '-' from left(
    regexp_replace(translate(lower(coalesce(t,'')),
      'áàäâéèëêíìïîóòöôúùüûñç', 'aaaaeeeeiiiioooouuuunc'), '[^a-z0-9]+', '-', 'g'), 60)), ''), 'negocio')
$$;

create or replace function public.negocio_set_slug()
returns trigger language plpgsql security definer set search_path = public as $$
declare base text; cand text; n int := 1;
begin
  if tg_op = 'UPDATE' and new.slug is not distinct from old.slug and coalesce(new.slug,'') <> '' then
    return new;
  end if;
  base := public.slugify(coalesce(nullif(new.slug,''), new.name));
  cand := base;
  while exists (select 1 from public.negocios where slug = cand and id <> new.id) loop
    n := n + 1; cand := base || '-' || n;
  end loop;
  new.slug := cand;
  return new;
end $$;
drop trigger if exists trg_slug on public.negocios;
create trigger trg_slug before insert or update of slug on public.negocios
  for each row execute function public.negocio_set_slug();

do $$ declare r record; begin
  for r in select id from public.negocios where coalesce(slug,'') = '' order by registered_at loop
    update public.negocios set slug = '' where id = r.id;
  end loop;
end $$;

grant select (slug) on public.negocios to anon;   -- stats_token NO es público

-- ---------- 2. Eventos (visitas, clics de WhatsApp, llamadas, mapa, web) ----------
create table if not exists public.eventos (
  id          bigserial primary key,
  negocio_id  text not null references public.negocios(id) on delete cascade,
  tipo        text not null check (tipo in ('visita','whatsapp','llamada','mapa','web','compartir','oferta')),
  created_at  timestamptz not null default now()
);
create index if not exists eventos_neg_fecha on public.eventos(negocio_id, created_at desc);
alter table public.eventos enable row level security;
drop policy if exists ev_admin_read on public.eventos;
create policy ev_admin_read on public.eventos for select to authenticated using (public.is_admin());
revoke all on public.eventos from anon;

create or replace function public.registrar_evento(p_id text, p_tipo text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_tipo not in ('visita','whatsapp','llamada','mapa','web','compartir','oferta') then return; end if;
  if not exists (select 1 from public.negocios where id = p_id and active) then return; end if;
  insert into public.eventos(negocio_id, tipo) values (p_id, p_tipo);
  if p_tipo = 'visita' then
    update public.negocios set visit_count = coalesce(visit_count,0) + 1 where id = p_id;
  end if;
end $$;

create or replace function public.admin_resumen_eventos(p_dias int default 30)
returns table(negocio_id text, tipo text, total bigint)
language sql stable security invoker set search_path = public as $$
  select e.negocio_id, e.tipo, count(*) from public.eventos e
  where e.created_at >= now() - make_interval(days => p_dias)
  group by 1, 2
$$;

-- ---------- 3. Ofertas ----------
create table if not exists public.ofertas (
  id            bigserial primary key,
  negocio_id    text not null references public.negocios(id) on delete cascade,
  titulo        text not null check (char_length(titulo) between 3 and 80),
  descripcion   text check (char_length(coalesce(descripcion,'')) <= 300),
  precio_antes  numeric(10,2),
  precio_ahora  numeric(10,2),
  vence         date,
  activa        boolean not null default true,
  aprobada      boolean not null default false,
  origen        text not null default 'admin',
  created_at    timestamptz not null default now()
);
create index if not exists ofertas_neg on public.ofertas(negocio_id);
alter table public.ofertas enable row level security;
drop policy if exists of_public_read on public.ofertas;
drop policy if exists of_admin       on public.ofertas;
create policy of_public_read on public.ofertas for select to anon, authenticated
  using (aprobada and activa and (vence is null or vence >= current_date)
         and exists (select 1 from public.negocios n where n.id = negocio_id and n.active));
create policy of_admin on public.ofertas for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke insert, update, delete on public.ofertas from anon;

-- ---------- 4. Panel privado del dueño (por link secreto) ----------
create or replace function public.panel_negocio(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare n public.negocios%rowtype; hoy date := (now() at time zone 'America/Panama')::date;
begin
  select * into n from public.negocios where stats_token = p_token;
  if not found then return null; end if;
  return jsonb_build_object(
    'id', n.id, 'name', n.name, 'plan', n.plan, 'active', n.active, 'activated_at', n.activated_at,
    'slug', n.slug, 'category', n.category, 'province', n.province, 'photo', n.photos->>0,
    'visit_count', n.visit_count,
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

create or replace function public.crear_oferta_dueno(p_token uuid, p_titulo text, p_descripcion text,
  p_precio_antes numeric, p_precio_ahora numeric, p_vence date)
returns bigint language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; lim int; cnt int; nid bigint;
begin
  select * into n from public.negocios where stats_token = p_token and active;
  if not found then raise exception 'Tu perfil no está activo'; end if;
  lim := case n.plan when 'premium' then 3 when 'pro' then 2 else 1 end;
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

create or replace function public.eliminar_oferta_dueno(p_token uuid, p_id bigint)
returns void language sql security definer set search_path = public as $$
  delete from public.ofertas
  where id = p_id and negocio_id = (select id from public.negocios where stats_token = p_token);
$$;

-- ---------- 5. Permisos de funciones ----------
revoke execute on function public.negocio_set_slug()            from public, anon, authenticated;
revoke execute on function public.admin_resumen_eventos(int)    from public, anon;
grant  execute on function public.admin_resumen_eventos(int)    to authenticated;
