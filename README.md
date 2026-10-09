# BizLaunch by Roosevelt

Directorio de negocios de Panamá: perfiles con fotos, WhatsApp directo, mapa, menú con pedidos,
reservas, Yappy, ofertas, reseñas y panel de estadísticas para cada dueño.

**Sitio:** https://bizlaunchpanama.netlify.app

## Cómo está hecho
- `index.html` — todo el sitio (portada, directorio, perfiles, registro, panel del dueño y panel de administración).
- **Supabase** — base de datos, fotos y acceso del administrador.
- **EmailJS** — correos de registro y activación.
- **Netlify** — alojamiento. Cada cambio que se sube a este repositorio se publica solo.
  Al publicar, `npm run build` (`scripts/build-pages.mjs`) copia el sitio a `dist/` y crea una
  página para Google por cada negocio activo (`/n/<slug>/`), el `sitemap.xml` y `paginas.json`.
- `sw.js` — permite instalar la web como app y abrirla con poca señal.

## Base de datos (Supabase)
Los archivos de `sql/` ya están aplicados. Si se crea un proyecto nuevo, ejecútalos en orden en
Supabase → SQL Editor:

1. `01-seguridad.sql` — permisos, ajustes, cupones, reseñas y fotos
2. `02-estadisticas-ofertas.sql` — estadísticas, clics de WhatsApp, ofertas y páginas para Google
3. `03-menu.sql` — menú y lista de precios
4. `04-gratis-reservas-destacados.sql` — Plan Gratis, reservas, Yappy y "Destacar"
5. `05-endurecimiento.sql` — límites del registro público, fotos solo imágenes de hasta 5 MB,
   estadísticas a prueba de recargas y limpieza de contraseñas antiguas
6. `06-plan-gratis-opcional.sql` — permite al administrador deshabilitar el Plan Gratis
7. `07-respuestas-resenas.sql` — el dueño responde sus reseñas desde su panel

Luego crea el usuario administrador en Authentication → Users y desactiva "Allow new users to sign up".

## Archivos del sitio
- `vendor/` — librerías (Supabase, EmailJS, QR, Excel, ZIP) alojadas en el propio sitio, con la versión en el nombre.
- `og-image.png`, `icon-*.png`, `apple-touch-icon.png`, `site.webmanifest` — imagen para compartir e íconos.
- `robots.txt`, `sitemap.xml`, `404.html` — para Google y para enlaces rotos.
- `netlify.toml` — cabeceras de seguridad (CSP, HSTS, etc.) y caché.

## Control de asistencia (`/asistencia/`)
Aplicación aparte para registrar la asistencia de estudiantes con carnet QR, grupos, reportes y carnets
imprimibles. Guarda los datos en Google Sheets mediante Google Apps Script.
- `asistencia/` — la página (se publica en `/asistencia/`).
- `asistencia-apps-script/` — el código del servidor (`Code.gs`) y la guía de instalación. **No se publica.**

Instrucciones y recomendaciones: [`asistencia-apps-script/README.md`](asistencia-apps-script/README.md).

## Configuración
En `index.html`, sección `CFG`: número de Yappy, datos bancarios, horario de oficina y enlaces de pago.

## Seguridad
- La clave de Supabase de `index.html` es la clave **pública** (anon): es normal que esté visible.
  La protección está en las reglas de la base de datos.
- **Nunca** subas a este repositorio la clave `service_role` ni contraseñas.
- La política de contenido (CSP) en `netlify.toml` solo permite conectarse a Supabase y EmailJS.
  Si agregas otro servicio externo, añádelo ahí o el navegador lo bloqueará.
- En EmailJS → Account → Security, limita los envíos a `bizlaunchpanama.netlify.app`.
