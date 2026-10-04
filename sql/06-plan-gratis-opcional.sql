-- =====================================================================
-- BizLaunch v7 · Plan Gratis opcional
-- Cuando el administrador deshabilita el Plan Gratis (botón en Ajustes),
-- la base de datos también rechaza registros gratis nuevos.
-- Los negocios gratis que ya existen no se tocan.
-- =====================================================================
create or replace function public.plan_gratis_activo()
returns boolean language sql stable security definer set search_path = public as $$
  select not coalesce((select (value->>'gratis_off')::boolean from public.ajustes where key = 'site'), false);
$$;
revoke execute on function public.plan_gratis_activo() from public;
grant execute on function public.plan_gratis_activo() to anon, authenticated;

drop policy if exists neg_anon_ins on public.negocios;
create policy neg_anon_ins on public.negocios for insert to anon
  with check (
    active = false and coalesce(notes, '') = ''
    and plan in ('gratis','basico','pro','premium')
    and (plan <> 'gratis' or public.plan_gratis_activo())
    and char_length(coalesce(name,''))        between 2 and 120
    and char_length(coalesce(owner,''))       <= 120
    and char_length(coalesce(email,''))       between 5 and 160
    and char_length(coalesce(phone,''))       <= 30
    and char_length(coalesce(cedula,''))      <= 30
    and char_length(coalesce(ruc,''))         <= 40
    and char_length(coalesce(category,''))    <= 80
    and char_length(coalesce(province,''))    <= 40
    and char_length(coalesce(description,'')) <= 1200
    and char_length(coalesce(address,''))     <= 300
    and char_length(coalesce(hours,''))       <= 200
    and char_length(coalesce(whatsapp,''))    <= 30
    and char_length(coalesce(website,''))     <= 300
    and char_length(coalesce(map_url,''))     <= 1500
    and jsonb_typeof(coalesce(photos,'[]'::jsonb)) = 'array'
    and jsonb_array_length(coalesce(photos,'[]'::jsonb)) <= 15
    and not exists (
      select 1 from jsonb_array_elements(coalesce(photos,'[]'::jsonb)) p
      where jsonb_typeof(p) <> 'string'
         or (p #>> '{}') not like 'https://ufybfbydbregtrvdsscw.supabase.co/storage/v1/object/public/bizlaunch-fotos/%')
    and jsonb_typeof(coalesce(socials,'[]'::jsonb)) = 'array'
    and jsonb_array_length(coalesce(socials,'[]'::jsonb)) <= 6
    and coalesce(pg_column_size(payment), 0) < 2000
  );
