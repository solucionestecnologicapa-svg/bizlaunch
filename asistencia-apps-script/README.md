# Control de Asistencia v2 — instalación y recomendaciones

Sistema de asistencia estudiantil con carnet QR. Dos partes:

| Parte | Archivo | Dónde vive |
|---|---|---|
| Página (quiosco + panel de administración) | `asistencia/index.html` + `asistencia/vendor/` | Netlify: `https://bizlaunchpanama.netlify.app/asistencia/` (o cualquier hosting con **https**) |
| Servidor (datos) | `asistencia-apps-script/Code.gs` | Google Apps Script, dentro de tu hoja de Google Sheets |

> Esta carpeta (`asistencia-apps-script/`) **no se publica** en Netlify: el build la omite.

## Qué hace

**Quiosco (público)**
- Busca por apellido o nombre, en cualquier orden y sin importar las tildes.
- La primera vez, el estudiante registra su **cédula o pasaporte**. Las siguientes veces lo usa para confirmar que es él.
- **📷 Carnet QR**: lee el carnet con la cámara (celular, tablet o webcam), uno tras otro, con sonido y vibración.
- Funciona con **lectores de código USB/Bluetooth**: con el cursor en el buscador, al leer el carnet se registra solo.
- Muestra los registros de hoy en vivo y vuelve al inicio solo, después de cada registro (modo quiosco).

**Administrador** (5 clics sobre el ícono "ID", o `Ctrl + Alt + A`)
- **Estudiantes**: primer apellido, segundo apellido, primer nombre, segundo nombre, tipo de documento, número, grupo, nivel y email. Se listan ordenados por grupo y luego por apellidos y nombres. Puedes editarlos, borrarles el documento, eliminarlos, marcarles asistencia a mano y sacar un carnet individual.
- **Importar lista** desde Excel o Google Sheets (copiar y pegar, o archivo CSV).
- **Grupos**: puedes crear, editar, renombrar y eliminar grupos, cada uno con nivel, docente y turno. El nivel del grupo pasa solo a sus estudiantes.
- **Reportes**: el **diario** o el **de un período**, general (todos los grupos, cada uno en su sección y su página) o de un solo grupo. Se ordenan por primer apellido, segundo apellido, primer nombre y segundo nombre. Marcan **Presente / Tarde / Ausente** según la hora límite, traen resumen por grupo con totales, línea de firma del docente y números de página. Se descargan en PDF o Excel (CSV).
- **Carnets**: PDF tamaño carta con 8 carnets por hoja (85.6 × 54 mm, tamaño tarjeta de crédito), con marcas de corte y reverso opcional para imprimir a doble cara. El **QR** contiene la cédula o pasaporte, el nombre completo, el grupo y el nivel, por ejemplo:
  `CI:8-123-4567 | PÉREZ GÓMEZ, JUAN CARLOS | GRUPO: 10° E1 | NIVEL: DÉCIMO`
- **Cuenta**: cambiar la contraseña del administrador.

## Instalación (una sola vez, unos 10 minutos)

1. Abre tu hoja de Google Sheets → **Extensiones → Apps Script**.
2. Borra el código que haya y pega **todo** `Code.gs`. Guarda (💾).
3. **Configuración del proyecto (⚙)** → Zona horaria: **(GMT-05:00) Panamá**.
4. En el editor elige la función `instalar` y pulsa **▶ Ejecutar**. Acepta los permisos. Se crean o actualizan las hojas *Grupos*, *Estudiantes* y *Asistencia*.
5. **Implementar → Gestionar implementaciones → ✏ Editar** en la implementación que ya tienes → Versión: **Nueva versión** → **Implementar**.
   Así la URL **no cambia** y no hay que tocar `index.html`.
   (Si creas una implementación nueva: *Aplicación web*, ejecutar como **Yo**, acceso **Cualquier usuario**, y pega la URL nueva en `APPS_SCRIPT_URL` de `asistencia/index.html`.)
6. Abre la página y entra al panel con tu usuario y contraseña.
7. Ve a **Cuenta → Cambiar contraseña** y pon una contraseña nueva que solo tú conozcas (ver Seguridad).

### Si ya tenías datos de la versión anterior
- La hoja **Estudiantes** se migra sola la primera vez: la columna "Nombre" se separa en las 4 partes.
  "PÉREZ GÓMEZ, JUAN CARLOS" se separa por la coma. "Juan Carlos Pérez Gómez" se toma como 2 nombres + 2 apellidos.
  **Revisa los nombres compuestos** (ej.: "DE LA GUARDIA") y corrígelos en el panel.
- La columna "Cedula" se sigue usando tal cual. Los estudiantes conservan su cédula.
- Los grupos que ya usaban tus estudiantes salen en la pestaña Grupos marcados "sin datos". Pulsa **✎ Editar → Guardar grupo** para ponerles nivel, docente y turno.
- La asistencia vieja se lee si la hoja se llama **Asistencia** y tiene las columnas Fecha y Hora. Si tenía otro nombre, renómbrala a "Asistencia".

### Personalizar (arriba de todo en `asistencia/index.html`, sección `CONFIG`)
- `INSTITUCION`: nombre que sale en la página, los reportes y los carnets.
- `LOGO`: pon `logo.png` en la carpeta `asistencia/` y escribe `"logo.png"`.
- `CONTACTO_CARNET`: teléfono o dirección para el reverso del carnet.
- `HORA_LIMITE_TARDE`: hora límite por defecto. También se cambia en la pestaña Reportes.
- `COLOR_CARNET`: color de los carnets. También se elige al generarlos.

## Seguridad: qué cambió
- **La contraseña ya no viaja ni se guarda en la página.** El servidor solo guarda una *huella* (SHA-256 con sal, repetido 2000 veces). Al entrar se recibe un **token de sesión de 4 horas** y la contraseña no se vuelve a enviar.
- **Bloqueo**: después de 5 intentos fallidos se bloquea 15 minutos.
- **Datos privados**: la lista pública ya **no incluye cédulas**, y los reportes solo se generan desde el panel.
- Todos los textos se muestran escapados: un nombre con código no puede romper la página.
- `LockService` evita registros duplicados cuando dos personas marcan al mismo tiempo.
- La cédula no puede repetirse entre estudiantes y se valida su formato panameño (8-123-4567, PE-, E-, N-, AV, PI). El pasaporte acepta letras y números.

## Cómo imprimir los carnets
1. En el diálogo de impresión elige **Tamaño real / 100 %** (no "Ajustar a la página"). Si no, el carnet sale más pequeño.
2. Usa **cartulina blanca de 180–250 g** o papel adhesivo. Lo ideal es **PVC para impresora** o enmicado (plastificado) en caliente.
3. Para el reverso: imprime a doble cara, **voltear por el borde largo**. Cada reverso tiene en pequeño el ID y el apellido para comprobar que coincide con su frente.
4. Recorta por las marcas de corte. Si usas guillotina, mejor.
5. Prueba **un carnet con la cámara** antes de imprimir todo el grupo.

---

## Recomendaciones para nivel profesional

### Operación diaria
1. **Quiosco dedicado**: una tablet Android barata en un soporte a la entrada, en *modo kiosco* (fijar pantalla) y con brillo alto. Agrega la página a la pantalla de inicio.
2. **Lector de códigos USB o Bluetooth** (unos $20–40): es mucho más rápido que la cámara, de 1 a 2 segundos por estudiante. Conéctalo a la tablet o PC y deja el cursor en el buscador.
3. **Supervisión en la entrada**: el QR del carnet basta para marcar asistencia. Un docente o conserje cerca evita que alguien marque por otro con una foto del carnet.
4. **Hora límite por turno**: si tienes turnos matutino y vespertino, genera el reporte de cada turno con su propia hora límite.
5. **Revisión diaria**: al final del día, genera el reporte diario y usa **✔ Hoy** (o el reporte) para registrar justificaciones.

### Datos
6. **Importa la matrícula completa** al inicio del año desde el Excel de secretaría (pestaña Estudiantes → Importar lista).
7. **Registra cédulas desde el panel** antes de imprimir carnets. Así todos los QR llevan la cédula y no el ID interno.
8. **Respaldo**: en Google Sheets, *Archivo → Hacer una copia* cada mes, o activa el historial de versiones.
9. **Archivo anual**: al cerrar el año, copia la hoja *Asistencia* a otro archivo y vacíala. El sistema se mantiene rápido.
10. **Nombres compuestos**: escribe "DE LA GUARDIA" o "DE LEÓN" completos en el segundo apellido, para que el orden alfabético sea correcto.

### Mejoras futuras (si las necesitas, se pueden agregar)
- **Fotos en el carnet**: subir la foto del estudiante a Google Drive y que salga impresa.
- **Aviso a acudientes**: correo automático (MailApp) o WhatsApp cuando un estudiante falta 3 días seguidos.
- **Registro de salida**, además de la entrada.
- **Justificaciones**: estado "Excusa" con motivo, para que no cuente como ausencia.
- **Calendario escolar**: días feriados y sin clases, para calcular porcentajes exactos.
- **Funcionar sin internet**: guardar los registros en el dispositivo y enviarlos al volver la conexión.
- **Panel con gráficas**: asistencia por grupo y por semana, y estudiantes en riesgo (menos de 80 %).
- **Varios administradores** (docentes por grupo), cada uno con su usuario y viendo solo su grupo.
- **Migrar a una base de datos** (por ejemplo Supabase, la que ya usa BizLaunch) si pasas de ~3 000 estudiantes o de varios quioscos marcando al mismo tiempo.
