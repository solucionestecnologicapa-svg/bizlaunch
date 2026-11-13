-- =====================================================================
-- BizLaunch v11 · Correos automáticos al dueño del negocio
--  · Aviso inmediato con cada pedido o reserva nueva.
--  · Reporte semanal (lunes 8:00 a. m. de Panamá): visitas, WhatsApp, pedidos,
--    reservas y reseñas de los últimos 7 días.
-- Se envían desde la base de datos con EmailJS. Mientras falten las claves en
-- public.config_privada, las funciones no hacen nada (no fallan los pedidos).
-- Se puede ejecutar más de una vez.
-- =====================================================================
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

-- Claves privadas: nadie las lee desde la web (sin permisos para anon/authenticated)
create table if not exists public.config_privada (clave text primary key, valor text not null);
alter table public.config_privada enable row level security;
revoke all on public.config_privada from anon, authenticated;
insert into public.config_privada(clave, valor) values
  ('emailjs_service', 'service_8dhmsct'),
  ('emailjs_public',  'cJ1InEmDa6Uwabi45'),
  ('sitio',           'https://bizlaunchpanama.netlify.app/')
on conflict (clave) do nothing;
-- Faltan (las pone el administrador):  emailjs_template_aviso  y  emailjs_private

create or replace function public.bl_cfg(k text) returns text
language sql stable security definer set search_path = public as $$ select valor from public.config_privada where clave = k $$;
revoke execute on function public.bl_cfg(text) from public, anon, authenticated;

create or replace function public.bl_enviar_correo(p_to text, p_nombre text, p_asunto text, p_mensaje text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare svc text := bl_cfg('emailjs_service'); tpl text := bl_cfg('emailjs_template_aviso');
        pub text := bl_cfg('emailjs_public'); priv text := bl_cfg('emailjs_private');
begin
  if coalesce(p_to, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or svc is null or tpl is null or pub is null or priv is null then return false; end if;
  perform net.http_post(
    url := 'https://api.emailjs.com/api/v1.0/email/send',
    body := jsonb_build_object('service_id', svc, 'template_id', tpl, 'user_id', pub, 'accessToken', priv,
              'template_params', jsonb_build_object('to_email', p_to, 'to_name', coalesce(p_nombre, ''), 'subject', p_asunto, 'message', p_mensaje)),
    headers := '{"Content-Type": "application/json"}'::jsonb, timeout_milliseconds := 8000);
  return true;
exception when others then return false;   -- un correo nunca debe impedir un pedido
end $$;
revoke execute on function public.bl_enviar_correo(text, text, text, text) from public, anon, authenticated;

-- ---------- aviso inmediato ----------
create or replace function public.bl_aviso_pedido() returns trigger
language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; lineas text; panel text;
begin
  select * into n from public.negocios where id = new.negocio_id;
  if not found or n.id like 'demo\_%' then return new; end if;
  panel := coalesce(bl_cfg('sitio'), '') || '#panel/' || n.stats_token;
  select string_agg('• ' || (x->>'q') || ' × ' || (x->>'n') || ' — $' || to_char((x->>'p')::numeric * (x->>'q')::int, 'FM999990.00'), E'\n')
    into lineas from jsonb_array_elements(new.items) x;
  perform bl_enviar_correo(n.email, n.owner,
    '🛒 Nuevo pedido ' || new.codigo || ' — ' || n.name,
    'Tienes un pedido nuevo en BizLaunch.' || E'\n\n' ||
    'Cliente: ' || new.cliente || ' · WhatsApp ' || new.telefono || E'\n' ||
    case when new.modo = 'entrega' then '🛵 Entrega en: ' || coalesce(new.direccion, '') || coalesce(E'\n📍 https://maps.google.com/?q=' || new.ubicacion, '')
         else '🏪 Pasa a retirar al local' end || E'\n\n' ||
    coalesce(lineas, '') || E'\n' ||
    case when new.modo = 'entrega' then 'Envío: ' || coalesce('$' || to_char(new.envio, 'FM999990.00'), 'a coordinar') || E'\n' else '' end ||
    'Total: $' || to_char(new.total, 'FM999990.00') ||
    coalesce(E'\n📝 ' || nullif(new.nota, ''), '') || E'\n\n' ||
    'Atiéndelo y cambia su estado aquí: ' || panel);
  return new;
end $$;

create or replace function public.bl_aviso_cita() returns trigger
language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; panel text;
begin
  select * into n from public.negocios where id = new.negocio_id;
  if not found or n.id like 'demo\_%' then return new; end if;
  panel := coalesce(bl_cfg('sitio'), '') || '#panel/' || n.stats_token;
  perform bl_enviar_correo(n.email, n.owner,
    '📅 Nueva ' || case when new.tipo = 'mesa' then 'reserva' else 'cita' end || ' — ' || to_char(new.fecha, 'DD/MM') || ' ' || to_char(new.hora, 'HH24:MI') || ' — ' || n.name,
    'Tienes una ' || case when new.tipo = 'mesa' then 'reserva de mesa' else 'cita' end || ' nueva por confirmar.' || E'\n\n' ||
    '📅 ' || to_char(new.fecha, 'DD/MM/YYYY') || ' a las ' || to_char(new.hora, 'HH24:MI') || E'\n' ||
    coalesce('💈 ' || new.servicio || coalesce(' · $' || to_char(new.precio, 'FM999990.00'), '') || E'\n', '') ||
    case when new.tipo = 'mesa' then '👥 ' || new.personas || ' personas' || E'\n' else '' end ||
    '👤 ' || new.cliente || ' · WhatsApp ' || new.telefono ||
    coalesce(E'\n📝 ' || nullif(new.nota, ''), '') || E'\n\n' ||
    'Confírmala aquí: ' || panel);
  return new;
end $$;

drop trigger if exists bl_aviso_pedido on public.pedidos;
create trigger bl_aviso_pedido after insert on public.pedidos for each row execute function public.bl_aviso_pedido();
drop trigger if exists bl_aviso_cita on public.citas;
create trigger bl_aviso_cita after insert on public.citas for each row execute function public.bl_aviso_cita();

-- ---------- reporte semanal ----------
create or replace function public.bl_reporte_semanal() returns int
language plpgsql security definer set search_path = public as $$
declare n public.negocios%rowtype; v int; w int; p int; pt numeric; c int; r int; enviados int := 0; panel text;
begin
  for n in select * from public.negocios where active and plan <> 'gratis' and id not like 'demo\_%' and coalesce(email, '') <> '' loop
    select count(*) filter (where tipo = 'visita'), count(*) filter (where tipo in ('whatsapp','llamada','reserva'))
      into v, w from public.eventos where negocio_id = n.id and created_at > now() - interval '7 days';
    select count(*), coalesce(sum(total), 0) into p, pt from public.pedidos where negocio_id = n.id and created_at > now() - interval '7 days' and estado <> 'cancelado';
    select count(*) into c from public.citas where negocio_id = n.id and created_at > now() - interval '7 days' and estado <> 'cancelada';
    select count(*) into r from public.resenas where negocio_id = n.id and created_at > now() - interval '7 days';
    panel := coalesce(bl_cfg('sitio'), '') || '#panel/' || n.stats_token;
    if bl_enviar_correo(n.email, n.owner, '📊 Tu semana en BizLaunch — ' || n.name,
         'Así le fue a ' || n.name || ' en los últimos 7 días:' || E'\n\n' ||
         '👀 Visitas a tu página: ' || v || E'\n' ||
         '💬 Clientes que te escribieron o llamaron: ' || w || E'\n' ||
         '🛒 Pedidos en línea: ' || p || case when p > 0 then ' (total $' || to_char(pt, 'FM999990.00') || ')' else '' end || E'\n' ||
         '📅 Reservas y citas: ' || c || E'\n' ||
         '⭐ Reseñas nuevas: ' || r || E'\n\n' ||
         case when v = 0 then 'Consejo: comparte tu página en tus estados de WhatsApp e Instagram para recibir más visitas.' || E'\n\n' else '' end ||
         'Mira el detalle en tu panel: ' || panel) then
      enviados := enviados + 1;
    end if;
  end loop;
  return enviados;
end $$;
revoke execute on function public.bl_reporte_semanal() from public, anon, authenticated;

-- lunes 8:00 a. m. en Panamá (13:00 UTC)
select cron.unschedule(jobid) from cron.job where jobname = 'bl-reporte-semanal';
select cron.schedule('bl-reporte-semanal', '0 13 * * 1', $$select public.bl_reporte_semanal()$$);
