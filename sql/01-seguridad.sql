-- =====================================================================
-- BizLaunch · Seguridad y tablas nuevas para Supabase
-- Ejecútalo UNA vez en Supabase → SQL Editor → New query → Run.
-- Es seguro volver a ejecutarlo (usa IF NOT EXISTS / DROP IF EXISTS).
--
-- ANTES de ejecutar:
--   1. Authentication → Users → "Add user": crea el usuario
--      bizlaunchbyroosevelt@gmail.com con una contraseña fuerte.
--   2. Authentication → Sign In / Providers → desactiva "Allow new users to sign up".
-- =====================================================================

-- ---------- 0. ¿Quién es admin? ----------
create or replace function public.is_admin()
returns boolean language sql stable
set search_path = public
as $$
  select coalesce(lower(auth.jwt() ->> 'email'), '') = 'bizlaunchbyroosevelt@gmail.com'
$$;

-- ---------- 1. Columnas que usa el sitio nuevo ----------
alter table public.negocios add column if not exists visit_count  integer default 0;
alter table public.negocios add column if not exists activated_at timestamptz;
alter table public.negocios add column if not exists expired_at   timestamptz;
alter table public.negocios add column if not exists updated_at   timestamptz;

-- ---------- 2. negocios: RLS ----------
alter table public.negocios enable row level security;

do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname='public' and tablename='negocios' loop
    execute format('drop policy %I on public.negocios', r.policyname);
  end loop;
end $$;

-- Público: solo ve negocios activos
create policy neg_anon_read  on public.negocios for select to anon          using (active = true);
-- Admin: ve y gestiona todo
create policy neg_admin_read on public.negocios for select to authenticated using (public.is_admin());
create policy neg_admin_upd  on public.negocios for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy neg_admin_del  on public.negocios for delete to authenticated using (public.is_admin());
create policy neg_admin_ins  on public.negocios for insert to authenticated with check (public.is_admin());
-- Público: puede registrarse, pero siempre como PENDIENTE
create policy neg_anon_ins   on public.negocios for insert to anon
  with check (active = false and coalesce(visit_count,0) = 0 and activated_at is null);

-- Público: solo puede leer las columnas públicas (cédula, correo, teléfono, pago, notas = privados)
revoke select on public.negocios from anon;
grant select (id, plan, plan_n, plan_p, name, category, description, address, hours,
              whatsapp, website, map_url, socials, photos, province, active,
              activated_at, visit_count)
  on public.negocios to anon;
grant insert on public.negocios to anon;
revoke update, delete on public.negocios from anon;

-- ---------- 3. Funciones públicas seguras ----------
create or replace function public.incrementar_visita(p_id text)
returns void language sql security definer set search_path = public as $$
  update public.negocios set visit_count = coalesce(visit_count,0) + 1
  where id::text = p_id and active = true;
$$;

create or replace function public.email_registrado(p_email text)
returns boolean language sql security definer set search_path = public as $$
  select exists(select 1 from public.negocios where lower(email) = lower(trim(p_email)));
$$;

-- ---------- 4. Ajustes (precios y promoción) ----------
create table if not exists public.ajustes (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_at timestamptz default now()
);
alter table public.ajustes enable row level security;
drop policy if exists aj_read  on public.ajustes;
drop policy if exists aj_write on public.ajustes;
create policy aj_read  on public.ajustes for select to anon, authenticated using (true);
create policy aj_write on public.ajustes for all    to authenticated using (public.is_admin()) with check (public.is_admin());
insert into public.ajustes (key, value)
values ('site', '{"precios":{"basico":50,"pro":100,"premium":150},"promo":{"active":false,"pct":0}}')
on conflict (key) do nothing;

-- ---------- 5. Cupones (nadie del público puede listarlos) ----------
create table if not exists public.cupones (
  code        text primary key,
  pct         integer not null check (pct between 1 and 90),
  descripcion text,
  activo      boolean not null default true,
  usos        integer not null default 0,
  created_at  timestamptz default now()
);
alter table public.cupones enable row level security;
drop policy if exists cp_admin on public.cupones;
create policy cp_admin on public.cupones for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.validar_cupon(p_code text)
returns integer language sql security definer set search_path = public as $$
  select pct from public.cupones where code = upper(trim(p_code)) and activo = true;
$$;

-- Cuenta usos automáticamente cuando un registro usa un cupón
create or replace function public.contar_uso_cupon()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.payment ->> 'coupon', '') <> '' then
    update public.cupones set usos = usos + 1 where code = upper(new.payment ->> 'coupon');
  end if;
  return new;
end $$;
drop trigger if exists trg_uso_cupon on public.negocios;
create trigger trg_uso_cupon after insert on public.negocios
  for each row execute function public.contar_uso_cupon();

-- ---------- 6. Reseñas con moderación ----------
create table if not exists public.resenas (
  id          bigserial primary key,
  negocio_id  text not null,
  autor       text,
  estrellas   integer not null check (estrellas between 1 and 5),
  comentario  text,
  aprobada    boolean not null default false,
  created_at  timestamptz default now()
);
alter table public.resenas add column if not exists aprobada boolean not null default false;
alter table public.resenas enable row level security;

do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname='public' and tablename='resenas' loop
    execute format('drop policy %I on public.resenas', r.policyname);
  end loop;
end $$;

create policy rv_anon_read  on public.resenas for select to anon          using (aprobada = true);
create policy rv_admin_read on public.resenas for select to authenticated using (aprobada = true or public.is_admin());
create policy rv_insert     on public.resenas for insert to anon, authenticated
  with check (aprobada = false and estrellas between 1 and 5 and length(coalesce(comentario,'')) <= 600);
create policy rv_admin_upd  on public.resenas for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy rv_admin_del  on public.resenas for delete to authenticated using (public.is_admin());

-- ---------- 7. Fotos (Storage) ----------
insert into storage.buckets (id, name, public)
values ('bizlaunch-fotos', 'bizlaunch-fotos', true)
on conflict (id) do update set public = true;

-- Políticas antiguas: permitían a cualquiera borrar y listar todas las fotos
drop policy if exists fotos_eliminar on storage.objects;
drop policy if exists fotos_ver      on storage.objects;
drop policy if exists fotos_subir    on storage.objects;
drop policy if exists bl_fotos_insert on storage.objects;
drop policy if exists bl_fotos_admin  on storage.objects;
create policy bl_fotos_insert on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'bizlaunch-fotos'
              and lower(storage.extension(name)) in ('jpg','jpeg','png','webp'));
create policy bl_fotos_admin on storage.objects for delete to authenticated
  using (bucket_id = 'bizlaunch-fotos' and public.is_admin());

-- ---------- 8. (Opcional) Vencer planes automáticamente cada noche ----------
-- Requiere activar la extensión pg_cron en Database → Extensions.
-- select cron.schedule('bizlaunch-vencer', '0 6 * * *', $$
--   update public.negocios set active = false, expired_at = now()
--   where active and activated_at < now() - interval '365 days';
-- $$);
