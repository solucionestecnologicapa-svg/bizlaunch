# BizLaunch by Roosevelt

Directorio de negocios de Panamá: perfiles con fotos, WhatsApp directo, mapa, menú con pedidos,
reservas, Yappy, ofertas, reseñas y panel de estadísticas para cada dueño.

**Sitio:** https://bizlaunchpanama.netlify.app

## Cómo está hecho
- `index.html` — todo el sitio (portada, directorio, perfiles, registro, panel del dueño y panel de administración).
- **Supabase** — base de datos, fotos y acceso del administrador.
- **EmailJS** — correos de registro y activación.
- **Netlify** — alojamiento. Cada cambio que se sube a este repositorio se publica solo.

## Base de datos (Supabase)
Los archivos de `sql/` ya están aplicados. Si se crea un proyecto nuevo, ejecútalos en orden en
Supabase → SQL Editor:

1. `01-seguridad.sql` — permisos, ajustes, cupones, reseñas y fotos
2. `02-estadisticas-ofertas.sql` — estadísticas, clics de WhatsApp, ofertas y páginas para Google
3. `03-menu.sql` — menú y lista de precios
4. `04-gratis-reservas-destacados.sql` — Plan Gratis, reservas, Yappy y "Destacar"

Luego crea el usuario administrador en Authentication → Users y desactiva "Allow new users to sign up".

## Configuración
En `index.html`, sección `CFG`: número de Yappy, datos bancarios, horario de oficina y enlaces de pago.

## Seguridad
- La clave de Supabase de `index.html` es la clave **pública** (anon): es normal que esté visible.
  La protección está en las reglas de la base de datos.
- **Nunca** subas a este repositorio la clave `service_role` ni contraseñas.
