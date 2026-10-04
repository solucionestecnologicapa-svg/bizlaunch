-- =====================================================================
-- BizLaunch v6 · Endurecimiento de seguridad
-- Requiere haber ejecutado antes 01 → 04. Se puede ejecutar más de una vez.
-- =====================================================================

-- 1) Contraseñas antiguas en texto plano: la web ya no las usa (el admin entra
--    con Supabase Auth). Se borran para que no queden expuestas en la base.
update public.negocios set password = null where password is not null;

-- 2) Registro público: el visitante solo puede enviar las columnas del formulario.
--    Antes podía escribir también slug, stats_token, notas internas, menú, etc.
revoke insert on public.negocios from anon;
grant insert (id, plan, plan_n, plan_p, owner, cedula, email, phone, province, name, category, ruc,
              description, address, hours, whatsapp, website, map_url, socials, photos, payment,
              active, notes, registered_at)
  on public.negocios to anon;

-- Límites de tamaño y fotos solo desde nuestro almacenamiento
drop policy if exists neg_anon_ins on public.negocios;
create policy neg_anon_ins on public.negocios for insert to anon
  with check (
    active = false and coalesce(notes, '') = ''
    and plan in ('gratis','basico','pro','premium')
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

-- 3) Reseñas: solo para negocios publicados y con tamaño limitado
drop policy if exists rv_insert on public.resenas;
create policy rv_insert on public.resenas for insert to anon, authenticated
  with check (
    aprobada = false and estrellas between 1 and 5
    and char_length(coalesce(comentario,'')) <= 600
    and char_length(coalesce(autor,'')) <= 60
    and exists (select 1 from public.negocios n where n.id = negocio_id and n.active)
  );

-- 4) Fotos: solo imágenes de hasta 5 MB
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg','image/png','image/webp']
 where id = 'bizlaunch-fotos';

-- 5) Estadísticas confiables: la misma persona no puede inflar los números
--    recargando la página (1 visita cada 30 min y 1 clic por tipo cada 2 min)
alter table public.eventos add column if not exists huella text;
create index if not exists eventos_huella on public.eventos (negocio_id, tipo, huella, created_at desc);

create or replace function public.registrar_evento(p_id text, p_tipo text)
returns void language plpgsql security definer set search_path = public as $$
declare hdr json; ip text; h text; ventana interval;
begin
  if p_tipo not in ('visita','whatsapp','llamada','mapa','web','compartir','oferta','reserva','yappy') then return; end if;
  if not exists (select 1 from public.negocios where id = p_id and active) then return; end if;
  begin hdr := current_setting('request.headers', true)::json; exception when others then hdr := null; end;
  ip := split_part(coalesce(hdr->>'cf-connecting-ip', hdr->>'x-real-ip', hdr->>'x-forwarded-for', ''), ',', 1);
  h := md5(ip || '|' || coalesce(hdr->>'user-agent', '') || '|' || (now() at time zone 'utc')::date);
  ventana := case when p_tipo = 'visita' then interval '30 minutes' else interval '2 minutes' end;
  if ip <> '' and exists (select 1 from public.eventos where negocio_id = p_id and tipo = p_tipo and huella = h
                           and created_at > now() - ventana) then return; end if;
  -- tope de seguridad por negocio
  if (select count(*) from public.eventos where negocio_id = p_id and created_at > now() - interval '10 minutes') > 400 then return; end if;
  insert into public.eventos(negocio_id, tipo, huella) values (p_id, p_tipo, case when ip <> '' then h end);
  if p_tipo = 'visita' then
    update public.negocios set visit_count = coalesce(visit_count,0) + 1 where id = p_id;
  end if;
end $$;

-- La función vieja de visitas ya no se usa: se cierra al público
revoke execute on function public.incrementar_visita(text) from anon, authenticated, public;
