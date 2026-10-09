/* ==========================================================================
   CONTROL DE ASISTENCIA — Backend en Google Apps Script (v2)
   --------------------------------------------------------------------------
   Hojas que usa (se crean solas si no existen):
     • Estudiantes : ID, PrimerApellido, SegundoApellido, PrimerNombre,
                     SegundoNombre, TipoDocumento, Documento, Grupo, Nivel,
                     Email, Creado
     • Grupos      : Grupo, Nivel, Docente, Turno, Creado
     • Asistencia  : Fecha, Hora, ID, Documento, Nombre, Grupo, Nivel, Metodo

   Instalación: ver README.md de esta carpeta.
   ========================================================================== */

const CFG = {
  ZONA_HORARIA: 'America/Panama',
  HOJA_ESTUDIANTES: 'Estudiantes',
  HOJA_GRUPOS: 'Grupos',
  HOJA_ASISTENCIA: 'Asistencia',
  SESION_SEGUNDOS: 4 * 60 * 60,      // la sesión del administrador dura 4 horas
  MAX_INTENTOS_LOGIN: 5,             // intentos fallidos antes de bloquear
  BLOQUEO_SEGUNDOS: 15 * 60,         // bloqueo de 15 minutos

  // Usuario y contraseña del administrador.
  // La contraseña NO se guarda: solo su huella (sal + SHA-256 repetido).
  // Para cambiarla usa "Cuenta → Cambiar contraseña" en el panel; el cambio
  // queda en Propiedades del script y tiene prioridad sobre estos valores.
  ADMIN_USUARIO: 'RAAA1979',
  ADMIN_SAL: '189935d5f549c189e70b5ce8',
  ADMIN_HUELLA: 'e83f06d55968c52c80f622480d3d296744162000098d94b79b2c1d21e81f5f66',
  ITERACIONES: 2000
};

const COLS = {
  est: ['ID', 'PrimerApellido', 'SegundoApellido', 'PrimerNombre', 'SegundoNombre',
        'TipoDocumento', 'Documento', 'Grupo', 'Nivel', 'Email', 'Creado'],
  grp: ['Grupo', 'Nivel', 'Docente', 'Turno', 'Creado'],
  asi: ['Fecha', 'Hora', 'ID', 'Documento', 'Nombre', 'Grupo', 'Nivel', 'Metodo']
};

// Nombres de columna de la versión anterior que se reconocen automáticamente
const ALIAS = {
  Documento: ['Documento', 'Cedula', 'Cédula', 'CEDULA', 'Cédula/Pasaporte'],
  Nombre: ['Nombre', 'NombreCompleto', 'Nombre completo', 'Estudiante'],
  Fecha: ['Fecha', 'Día', 'Dia'],
  Hora: ['Hora', 'Hora de entrada']
};

/* ============================ ENTRADA HTTP ============================ */

function doGet(e) { return responder_(() => enrutar_(e.parameter || {}, 'GET')); }
function doPost(e) { return responder_(() => enrutar_(e.parameter || {}, 'POST')); }

function responder_(fn) {
  let out;
  try { out = fn(); }
  catch (err) { out = { ok: false, mensaje: 'Error del servidor: ' + (err && err.message ? err.message : err) }; }
  return ContentService.createTextOutput(JSON.stringify(out)).setMimeType(ContentService.MimeType.JSON);
}

function enrutar_(p, metodo) {
  const a = p.action || '';
  // ---- públicas ----
  if (a === 'roster') return accRoster_();
  if (a === 'historial') return accHistorial_();
  if (a === 'registrar' && metodo === 'POST') return accRegistrar_(p);
  if (a === 'registrarQR' && metodo === 'POST') return accRegistrarQR_(p);
  if (a === 'adminLogin' && metodo === 'POST') return accLogin_(p);

  // ---- administrador (requieren token, solo POST) ----
  if (metodo !== 'POST') return { ok: false, mensaje: 'Acción no válida.' };
  const usuario = validarToken_(p.token);
  if (!usuario) return { ok: false, sesionVencida: true, mensaje: 'Tu sesión venció. Vuelve a entrar.' };

  switch (a) {
    case 'adminLogout': CacheService.getScriptCache().remove('tok_' + p.token); return { ok: true };
    case 'adminListar': return accListar_();
    case 'adminAgregar': return accGuardarEstudiante_(p, true);
    case 'adminGuardar': return accGuardarEstudiante_(p, false);
    case 'adminEliminar': return accEliminarEstudiante_(p);
    case 'adminImportar': return accImportar_(p);
    case 'adminMarcar': return accMarcarManual_(p);
    case 'grupoGuardar': return accGuardarGrupo_(p);
    case 'grupoEliminar': return accEliminarGrupo_(p);
    case 'reporteDia': return accReporte_(p.fecha, p.fecha);
    case 'reporteRango': return accReporte_(p.desde, p.hasta);
    case 'adminCambiarClave': return accCambiarClave_(p, usuario);
  }
  return { ok: false, mensaje: 'Acción desconocida: ' + a };
}

/* ============================ UTILIDADES ============================ */

function libro_() { return SpreadsheetApp.getActiveSpreadsheet(); }

function hoja_(nombre, encabezados) {
  const ss = libro_();
  let sh = ss.getSheetByName(nombre);
  if (!sh) {
    sh = ss.insertSheet(nombre);
    sh.getRange(1, 1, 1, encabezados.length).setValues([encabezados]).setFontWeight('bold');
    sh.setFrozenRows(1);
  }
  // agrega columnas que falten (sin tocar las existentes)
  const actuales = encabezadosDe_(sh);
  const faltan = encabezados.filter(h => indiceCol_(actuales, h) < 0);
  if (faltan.length) {
    sh.getRange(1, actuales.length + 1, 1, faltan.length).setValues([faltan]).setFontWeight('bold');
  }
  // texto plano en columnas que Sheets podría convertir en fecha o número (una sola vez por hoja)
  const props = PropertiesService.getScriptProperties();
  if (faltan.length || !props.getProperty('FMT_' + nombre)) {
    const enc = encabezadosDe_(sh);
    ['Documento', 'Fecha', 'Hora', 'Grupo', 'Nivel'].forEach(h => {
      const i = indiceCol_(enc, h);
      if (i >= 0) sh.getRange(2, i + 1, sh.getMaxRows() - 1, 1).setNumberFormat('@');
    });
    props.setProperty('FMT_' + nombre, '1');
  }
  return sh;
}

function encabezadosDe_(sh) {
  const n = sh.getLastColumn();
  if (!n) return [];
  return sh.getRange(1, 1, 1, n).getValues()[0].map(v => String(v).trim());
}

function indiceCol_(enc, nombre) {
  const alias = ALIAS[nombre] || [nombre];
  const norm = s => quitarTildes_(String(s)).toLowerCase().replace(/\s+/g, '');
  for (const a of alias) {
    const i = enc.findIndex(h => norm(h) === norm(a));
    if (i >= 0) return i;
  }
  return -1;
}

function leer_(sh, campos) {
  const enc = encabezadosDe_(sh);
  const idx = {};
  campos.forEach(c => idx[c] = indiceCol_(enc, c));
  const n = sh.getLastRow() - 1;
  if (n < 1) return { filas: [], idx, enc };
  const datos = sh.getRange(2, 1, n, enc.length).getValues();
  const filas = datos.map((r, k) => {
    const o = { _fila: k + 2 };
    campos.forEach(c => o[c] = idx[c] >= 0 ? celdaTexto_(r[idx[c]], c) : '');
    return o;
  });
  return { filas, idx, enc };
}

function celdaTexto_(v, campo) {
  if (v instanceof Date) {
    if (campo === 'Hora') return Utilities.formatDate(v, CFG.ZONA_HORARIA, 'HH:mm:ss');
    return Utilities.formatDate(v, CFG.ZONA_HORARIA, 'yyyy-MM-dd');
  }
  return v === null || v === undefined ? '' : String(v).trim();
}

function escribirFila_(sh, fila, obj) {
  const enc = encabezadosDe_(sh);
  Object.keys(obj).forEach(k => {
    const i = indiceCol_(enc, k);
    if (i >= 0) sh.getRange(fila, i + 1).setValue(obj[k]);
  });
}

function agregarFila_(sh, obj) {
  const enc = encabezadosDe_(sh);
  const fila = enc.map(h => {
    for (const k of Object.keys(obj)) if (indiceCol_([h], k) === 0) return obj[k];
    return '';
  });
  sh.appendRow(fila);
}

function quitarTildes_(s) { return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, ''); }
function limpio_(s) { return String(s || '').replace(/\s+/g, ' ').trim(); }
function mayus_(s) { return limpio_(s).toUpperCase(); }
function normDoc_(s) { return String(s || '').toUpperCase().replace(/\s+/g, '').replace(/[‐–—]/g, '-'); }
function ahora_() { return new Date(); }
function hoy_() { return Utilities.formatDate(ahora_(), CFG.ZONA_HORARIA, 'yyyy-MM-dd'); }
function horaAhora_() { return Utilities.formatDate(ahora_(), CFG.ZONA_HORARIA, 'HH:mm:ss'); }

function nombreCompleto_(e) {
  const ap = [e.PrimerApellido, e.SegundoApellido].filter(Boolean).join(' ');
  const no = [e.PrimerNombre, e.SegundoNombre].filter(Boolean).join(' ');
  return ap && no ? ap + ', ' + no : (ap || no);
}

function compararEst_(a, b) {
  const k = e => [e.PrimerApellido, e.SegundoApellido, e.PrimerNombre, e.SegundoNombre]
    .map(x => quitarTildes_(x).toLowerCase()).join('\u0001');
  return k(a) < k(b) ? -1 : k(a) > k(b) ? 1 : 0;
}

function validarDocumento_(tipo, doc) {
  if (!doc) return 'Escribe el número de documento.';
  if (tipo === 'PASAPORTE') {
    if (!/^[A-Z0-9]{5,20}$/.test(doc)) return 'Pasaporte no válido: usa solo letras y números (5 a 20).';
  } else {
    // Cédula panameña: 8-123-4567, PE-12-345, E-8-12345, N-19-1234, 1AV-12-345, etc.
    if (!/^(PE|E|N|[0-9]{1,2}(AV|PI)?)-[0-9]{1,4}-[0-9]{1,6}$/.test(doc))
      return 'Cédula no válida. Formato: 8-123-4567 (con guiones).';
  }
  return '';
}

function estudiantes_() {
  const sh = hoja_(CFG.HOJA_ESTUDIANTES, COLS.est);
  migrarSiHaceFalta_(sh);
  return { sh, ...leer_(sh, COLS.est) };
}

function grupos_() {
  const sh = hoja_(CFG.HOJA_GRUPOS, COLS.grp);
  return { sh, ...leer_(sh, COLS.grp) };
}

function asistenciaHoja_() { return hoja_(CFG.HOJA_ASISTENCIA, COLS.asi); }

/* Lee la asistencia de una fecha empezando por el final (rápido aunque la hoja sea grande). */
function asistenciaDeFecha_(fecha) {
  const sh = asistenciaHoja_();
  const enc = encabezadosDe_(sh);
  const ix = c => indiceCol_(enc, c);
  const ult = sh.getLastRow();
  const res = [];
  const BLOQUE = 400;
  for (let fin = ult; fin >= 2; fin -= BLOQUE) {
    const ini = Math.max(2, fin - BLOQUE + 1);
    const datos = sh.getRange(ini, 1, fin - ini + 1, enc.length).getValues();
    let anteriores = 0;
    for (let k = datos.length - 1; k >= 0; k--) {
      const f = celdaTexto_(datos[k][ix('Fecha')], 'Fecha');
      if (f === fecha) res.push(filaAsistencia_(datos[k], ix));
      else if (f < fecha) anteriores++;
    }
    // si todo el bloque es de días anteriores, ya no hay más registros de esa fecha
    if (anteriores === datos.length) break;
  }
  return res;
}

function filaAsistencia_(r, ix) {
  return {
    fecha: celdaTexto_(r[ix('Fecha')], 'Fecha'),
    hora: celdaTexto_(r[ix('Hora')], 'Hora'),
    id: ix('ID') >= 0 ? String(r[ix('ID')]) : '',
    documento: ix('Documento') >= 0 ? String(r[ix('Documento')]) : '',
    nombre: ix('Nombre') >= 0 ? String(r[ix('Nombre')]) : '',
    grupo: ix('Grupo') >= 0 ? String(r[ix('Grupo')]) : '',
    metodo: ix('Metodo') >= 0 ? String(r[ix('Metodo')]) : ''
  };
}

/* ============================ MIGRACIÓN ============================ */
/* Si la hoja viene de la versión anterior (columna "Nombre" única),
   separa el nombre en sus 4 partes. Se ejecuta una sola vez. */
function migrarSiHaceFalta_(sh) {
  const props = PropertiesService.getScriptProperties();
  if (props.getProperty('MIGRADO_V2')) return;
  const enc = encabezadosDe_(sh);
  const iNom = indiceCol_(enc, 'Nombre');
  const iA1 = indiceCol_(enc, 'PrimerApellido');
  const iN1 = indiceCol_(enc, 'PrimerNombre');
  const iA2 = indiceCol_(enc, 'SegundoApellido');
  const iN2 = indiceCol_(enc, 'SegundoNombre');
  const iId = indiceCol_(enc, 'ID');
  const iTipo = indiceCol_(enc, 'TipoDocumento');
  const iDoc = indiceCol_(enc, 'Documento');
  const n = sh.getLastRow() - 1;
  if (n >= 1) {
    const datos = sh.getRange(2, 1, n, enc.length).getValues();
    let siguienteId = 1;
    datos.forEach(r => { const v = parseInt(r[iId], 10); if (v >= siguienteId) siguienteId = v + 1; });
    datos.forEach(r => {
      if (iId >= 0 && !String(r[iId]).trim()) r[iId] = siguienteId++;
      if (iTipo >= 0 && !String(r[iTipo]).trim() && iDoc >= 0 && String(r[iDoc]).trim()) {
        r[iTipo] = /^[A-Z0-9]+$/i.test(String(r[iDoc]).trim()) && !/-/.test(String(r[iDoc])) ? 'PASAPORTE' : 'CEDULA';
      }
      if (iNom >= 0 && !String(r[iA1]).trim() && !String(r[iN1]).trim() && String(r[iNom]).trim()) {
        const p = separarNombre_(String(r[iNom]));
        r[iA1] = p.a1; r[iA2] = p.a2; r[iN1] = p.n1; r[iN2] = p.n2;
      }
    });
    sh.getRange(2, 1, n, enc.length).setValues(datos);
  }
  props.setProperty('MIGRADO_V2', '1');
}

/* "PÉREZ GÓMEZ, JUAN CARLOS" → apellidos antes de la coma.
   "Juan Carlos Pérez Gómez"  → 4 palabras: 2 nombres + 2 apellidos.
   Revisa los resultados en el panel: los nombres compuestos pueden quedar mal. */
function separarNombre_(txt) {
  const t = mayus_(txt);
  if (t.indexOf(',') >= 0) {
    const [ap, no] = t.split(',').map(limpio_);
    const a = ap.split(' '), n = no.split(' ');
    return { a1: a[0] || '', a2: a.slice(1).join(' '), n1: n[0] || '', n2: n.slice(1).join(' ') };
  }
  const w = t.split(' ');
  if (w.length === 1) return { n1: w[0], n2: '', a1: '', a2: '' };
  if (w.length === 2) return { n1: w[0], n2: '', a1: w[1], a2: '' };
  if (w.length === 3) return { n1: w[0], n2: '', a1: w[1], a2: w[2] };
  return { n1: w[0], n2: w.slice(1, w.length - 2).join(' '), a1: w[w.length - 2], a2: w[w.length - 1] };
}

/* ============================ PÚBLICAS ============================ */

function accRoster_() {
  const { filas } = estudiantes_();
  const grupos = grupos_().filas;
  const nivelGrupo = {};
  grupos.forEach(g => nivelGrupo[g.Grupo] = g.Nivel);
  const lista = filas.filter(e => e.ID).sort(compararEst_).map(e => ({
    id: e.ID,
    nombre: nombreCompleto_(e),
    primerApellido: e.PrimerApellido, segundoApellido: e.SegundoApellido,
    primerNombre: e.PrimerNombre, segundoNombre: e.SegundoNombre,
    grupo: e.Grupo,
    nivel: e.Nivel || nivelGrupo[e.Grupo] || '',
    tieneCedula: !!e.Documento   // nunca se envía el documento al público
  }));
  return { ok: true, estudiantes: lista };
}

function accHistorial_() {
  const regs = asistenciaDeFecha_(hoy_());
  regs.sort((a, b) => a.hora < b.hora ? 1 : -1);
  return { ok: true, fecha: hoy_(), total: regs.length,
           registros: regs.slice(0, 60).map(r => ({ hora: r.hora, nombre: r.nombre, grupo: r.grupo })) };
}

function accRegistrar_(p) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const { sh, filas } = estudiantes_();
    const est = filas.find(e => String(e.ID) === String(p.id));
    if (!est) return { ok: false, mensaje: 'Estudiante no encontrado. Pide ayuda al administrador.' };

    const tipo = p.tipoDoc === 'PASAPORTE' ? 'PASAPORTE' : 'CEDULA';
    const doc = normDoc_(p.cedula || p.documento);
    let primerRegistro = false;

    if (!est.Documento) {
      const err = validarDocumento_(tipo, doc);
      if (err) return { ok: false, mensaje: err };
      if (filas.some(e => normDoc_(e.Documento) === doc))
        return { ok: false, mensaje: 'Ese documento ya pertenece a otro estudiante. Consulta al administrador.' };
      escribirFila_(sh, est._fila, { Documento: doc, TipoDocumento: tipo });
      est.Documento = doc; est.TipoDocumento = tipo;
      primerRegistro = true;
    } else if (normDoc_(est.Documento) !== doc) {
      return { ok: false, mensaje: 'El documento no coincide con el registrado para este estudiante.' };
    }
    return marcar_(est, 'Manual', { primerRegistro });
  } finally { lock.releaseLock(); }
}

/* El QR del carnet trae "CI:8-123-4567 | ..." o "PAS:AB12345 | ..." o "ID:15 | ..." */
function accRegistrarQR_(p) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const { filas } = estudiantes_();
    let est = null;
    if (p.documento) est = filas.find(e => e.Documento && normDoc_(e.Documento) === normDoc_(p.documento));
    else if (p.id) est = filas.find(e => String(e.ID) === String(p.id) && !e.Documento);
    if (!est) return { ok: false, mensaje: 'Carnet no reconocido. Verifica que el estudiante esté registrado.' };
    return marcar_(est, 'QR', {});
  } finally { lock.releaseLock(); }
}

function marcar_(est, metodo, extra, fechaForzada) {
  const fecha = fechaForzada || hoy_();
  const nombre = nombreCompleto_(est);
  const previos = asistenciaDeFecha_(fecha).filter(r => String(r.id) === String(est.ID) ||
    (est.Documento && normDoc_(r.documento) === normDoc_(est.Documento)));
  if (previos.length) {
    return Object.assign({ ok: true, duplicado: true, nombre, grupo: est.Grupo, nivel: est.Nivel, hora: previos[0].hora,
      mensaje: 'Ya tenías tu asistencia registrada hoy a las ' + previos[0].hora + '.' }, extra);
  }
  const hora = fechaForzada ? '—' : horaAhora_();
  agregarFila_(asistenciaHoja_(), {
    Fecha: fecha, Hora: hora, ID: est.ID, Documento: est.Documento, Nombre: nombre,
    Grupo: est.Grupo, Nivel: est.Nivel, Metodo: metodo
  });
  return Object.assign({ ok: true, duplicado: false, nombre, grupo: est.Grupo, nivel: est.Nivel, hora,
    mensaje: extra.primerRegistro ? '¡Documento guardado y asistencia registrada!' : '¡Asistencia registrada!' }, extra);
}

/* ============================ SESIÓN ADMIN ============================ */

function huella_(sal, clave, iter) {
  let h = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, sal + ':' + clave, Utilities.Charset.UTF_8);
  for (let i = 1; i < iter; i++) h = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, h);
  return h.map(b => ('0' + (b & 0xff).toString(16)).slice(-2)).join('');
}

function credenciales_() {
  const p = PropertiesService.getScriptProperties();
  return {
    usuario: p.getProperty('ADMIN_USUARIO') || CFG.ADMIN_USUARIO,
    sal: p.getProperty('ADMIN_SAL') || CFG.ADMIN_SAL,
    huella: p.getProperty('ADMIN_HUELLA') || CFG.ADMIN_HUELLA
  };
}

function accLogin_(p) {
  const cache = CacheService.getScriptCache();
  const claveBloqueo = 'fallos_' + String(p.usuario || '').toUpperCase();
  const fallos = parseInt(cache.get(claveBloqueo) || '0', 10);
  if (fallos >= CFG.MAX_INTENTOS_LOGIN)
    return { ok: false, mensaje: 'Demasiados intentos fallidos. Espera 15 minutos.' };

  const c = credenciales_();
  const usuarioOk = String(p.usuario || '').trim().toUpperCase() === c.usuario.toUpperCase();
  const claveOk = huella_(c.sal, String(p.clave || ''), CFG.ITERACIONES) === c.huella;
  if (!usuarioOk || !claveOk) {
    cache.put(claveBloqueo, String(fallos + 1), CFG.BLOQUEO_SEGUNDOS);
    Utilities.sleep(800);
    return { ok: false, mensaje: 'Usuario o contraseña incorrectos.' };
  }
  cache.remove(claveBloqueo);
  const token = Utilities.getUuid() + Utilities.getUuid().replace(/-/g, '');
  cache.put('tok_' + token, c.usuario, CFG.SESION_SEGUNDOS);
  return { ok: true, token, usuario: c.usuario, expiraEnSeg: CFG.SESION_SEGUNDOS };
}

function validarToken_(token) {
  if (!token || String(token).length < 30) return null;
  return CacheService.getScriptCache().get('tok_' + token);
}

function accCambiarClave_(p, usuario) {
  const c = credenciales_();
  if (huella_(c.sal, String(p.actual || ''), CFG.ITERACIONES) !== c.huella)
    return { ok: false, mensaje: 'La contraseña actual no es correcta.' };
  const nueva = String(p.nueva || '');
  if (nueva.length < 10 || !/[A-Za-z]/.test(nueva) || !/[0-9]/.test(nueva))
    return { ok: false, mensaje: 'La nueva contraseña debe tener al menos 10 caracteres, con letras y números.' };
  const sal = Utilities.getUuid().replace(/-/g, '').slice(0, 24);
  const props = PropertiesService.getScriptProperties();
  props.setProperties({ ADMIN_USUARIO: usuario, ADMIN_SAL: sal, ADMIN_HUELLA: huella_(sal, nueva, CFG.ITERACIONES) });
  return { ok: true, mensaje: 'Contraseña actualizada.' };
}

/* ============================ ESTUDIANTES ============================ */

function estudianteAPublico_(e) {
  return {
    id: e.ID, primerApellido: e.PrimerApellido, segundoApellido: e.SegundoApellido,
    primerNombre: e.PrimerNombre, segundoNombre: e.SegundoNombre,
    nombre: nombreCompleto_(e), tipoDoc: e.TipoDocumento || 'CEDULA', documento: e.Documento,
    grupo: e.Grupo, nivel: e.Nivel, email: e.Email, creado: e.Creado
  };
}

function accListar_() {
  const nivelGrupo = {};
  grupos_().filas.forEach(g => nivelGrupo[g.Grupo] = g.Nivel);
  const est = estudiantes_().filas.filter(e => e.ID).sort(compararEst_).map(e => {
    const o = estudianteAPublico_(e);
    if (!o.nivel) o.nivel = nivelGrupo[o.grupo] || '';
    return o;
  });
  const conteo = {};
  est.forEach(e => conteo[e.grupo] = (conteo[e.grupo] || 0) + 1);
  const grupos = grupos_().filas.filter(g => g.Grupo).map(g => ({
    grupo: g.Grupo, nivel: g.Nivel, docente: g.Docente, turno: g.Turno, total: conteo[g.Grupo] || 0
  }));
  // grupos usados por estudiantes pero que aún no están en la hoja Grupos
  Object.keys(conteo).filter(n => n && !grupos.some(g => g.grupo === n))
    .forEach(n => grupos.push({ grupo: n, nivel: '', docente: '', turno: '', total: conteo[n], sinRegistrar: true }));
  grupos.sort((a, b) => a.grupo.localeCompare(b.grupo, 'es', { numeric: true }));
  return { ok: true, estudiantes: est, grupos };
}

function datosEstudiante_(p) {
  return {
    PrimerApellido: mayus_(p.primerApellido), SegundoApellido: mayus_(p.segundoApellido),
    PrimerNombre: mayus_(p.primerNombre), SegundoNombre: mayus_(p.segundoNombre),
    Grupo: limpio_(p.grupo), Nivel: limpio_(p.nivel), Email: limpio_(p.email).toLowerCase()
  };
}

function validarEstudiante_(d) {
  if (!d.PrimerApellido) return 'El primer apellido es obligatorio.';
  if (!d.PrimerNombre) return 'El primer nombre es obligatorio.';
  if (!d.Grupo) return 'Elige un grupo.';
  if (d.Email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(d.Email)) return 'El email no es válido.';
  return '';
}

function accGuardarEstudiante_(p, nuevo) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const { sh, filas } = estudiantes_();
    const d = datosEstudiante_(p);
    const err = validarEstudiante_(d);
    if (err) return { ok: false, mensaje: err };
    if (!d.Nivel) d.Nivel = nivelDeGrupo_(d.Grupo);

    let est = null;
    if (!nuevo) {
      est = filas.find(e => String(e.ID) === String(p.id));
      if (!est) return { ok: false, mensaje: 'Estudiante no encontrado.' };
    }

    if (p.resetCedula === '1') {
      d.Documento = ''; d.TipoDocumento = '';
    } else if (p.documento !== undefined) {
      const tipo = p.tipoDoc === 'PASAPORTE' ? 'PASAPORTE' : 'CEDULA';
      const doc = normDoc_(p.documento);
      if (doc) {
        const e2 = validarDocumento_(tipo, doc);
        if (e2) return { ok: false, mensaje: e2 };
        if (filas.some(e => normDoc_(e.Documento) === doc && (!est || String(e.ID) !== String(est.ID))))
          return { ok: false, mensaje: 'Ese documento ya pertenece a otro estudiante.' };
      }
      d.Documento = doc; d.TipoDocumento = doc ? tipo : '';
    }

    const dup = filas.find(e => (!est || String(e.ID) !== String(est.ID)) &&
      nombreCompleto_(e) === nombreCompleto_(d) && e.Grupo === d.Grupo);
    if (dup && p.forzar !== '1')
      return { ok: false, duplicadoNombre: true, mensaje: 'Ya existe un estudiante con ese nombre en ' + d.Grupo + '.' };

    if (nuevo) {
      const maxId = filas.reduce((m, e) => Math.max(m, parseInt(e.ID, 10) || 0), 0);
      d.ID = maxId + 1;
      d.Creado = Utilities.formatDate(ahora_(), CFG.ZONA_HORARIA, 'yyyy-MM-dd HH:mm');
      agregarFila_(sh, d);
      return { ok: true, id: d.ID, mensaje: 'Estudiante agregado: ' + nombreCompleto_(d) + '.' };
    }
    escribirFila_(sh, est._fila, d);
    return { ok: true, mensaje: p.resetCedula === '1' ? 'Documento borrado. Lo registrará de nuevo.' : 'Cambios guardados.' };
  } finally { lock.releaseLock(); }
}

function nivelDeGrupo_(grupo) {
  const g = grupos_().filas.find(x => x.Grupo === grupo);
  return g ? g.Nivel : '';
}

function accEliminarEstudiante_(p) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const { sh, filas } = estudiantes_();
    const est = filas.find(e => String(e.ID) === String(p.id));
    if (!est) return { ok: false, mensaje: 'Estudiante no encontrado.' };
    sh.deleteRow(est._fila);
    return { ok: true, mensaje: 'Estudiante eliminado. Su historial de asistencia se conserva.' };
  } finally { lock.releaseLock(); }
}

/* Importación masiva: p.filas = JSON [{primerApellido, segundoApellido, primerNombre,
   segundoNombre, tipoDoc, documento, grupo, nivel, email}, ...] */
function accImportar_(p) {
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    let lista;
    try { lista = JSON.parse(p.filas || '[]'); } catch (e) { return { ok: false, mensaje: 'Datos no válidos.' }; }
    if (!Array.isArray(lista) || !lista.length) return { ok: false, mensaje: 'No hay filas para importar.' };
    if (lista.length > 2000) return { ok: false, mensaje: 'Máximo 2000 filas por importación.' };

    const { sh, filas } = estudiantes_();
    const enc = encabezadosDe_(sh);
    const gsh = grupos_();
    const gruposExist = new Set(gsh.filas.map(g => g.Grupo));
    const nivelGrupo = {};
    gsh.filas.forEach(g => nivelGrupo[g.Grupo] = g.Nivel);
    const docs = new Set(filas.map(e => normDoc_(e.Documento)).filter(Boolean));
    const nombres = new Set(filas.map(e => nombreCompleto_(e) + '|' + e.Grupo));
    let id = filas.reduce((m, e) => Math.max(m, parseInt(e.ID, 10) || 0), 0);
    const nuevas = [], errores = [], gruposNuevos = {};
    const creado = Utilities.formatDate(ahora_(), CFG.ZONA_HORARIA, 'yyyy-MM-dd HH:mm');

    lista.forEach((r, k) => {
      const d = datosEstudiante_(r);
      const err = validarEstudiante_(d);
      if (err) { errores.push('Fila ' + (k + 1) + ': ' + err); return; }
      if (!d.Nivel) d.Nivel = nivelGrupo[d.Grupo] || '';
      const llave = nombreCompleto_(d) + '|' + d.Grupo;
      if (nombres.has(llave)) { errores.push('Fila ' + (k + 1) + ': ya existe ' + nombreCompleto_(d) + '.'); return; }
      const tipo = String(r.tipoDoc || '').toUpperCase().indexOf('PAS') === 0 ? 'PASAPORTE' : 'CEDULA';
      const doc = normDoc_(r.documento);
      if (doc) {
        const e2 = validarDocumento_(tipo, doc);
        if (e2) { errores.push('Fila ' + (k + 1) + ': ' + e2); return; }
        if (docs.has(doc)) { errores.push('Fila ' + (k + 1) + ': documento ' + doc + ' repetido.'); return; }
        docs.add(doc);
      }
      nombres.add(llave);
      if (!gruposExist.has(d.Grupo)) gruposNuevos[d.Grupo] = d.Nivel;
      d.ID = ++id; d.Documento = doc; d.TipoDocumento = doc ? tipo : ''; d.Creado = creado;
      nuevas.push(enc.map(h => { for (const c of Object.keys(d)) if (indiceCol_([h], c) === 0) return d[c]; return ''; }));
    });

    if (nuevas.length) sh.getRange(sh.getLastRow() + 1, 1, nuevas.length, enc.length).setValues(nuevas);
    Object.keys(gruposNuevos).forEach(g => agregarFila_(gsh.sh, { Grupo: g, Nivel: gruposNuevos[g], Creado: creado }));
    return { ok: true, importados: nuevas.length, errores,
      mensaje: nuevas.length + ' estudiante(s) importado(s)' + (errores.length ? ', ' + errores.length + ' fila(s) con error.' : '.') };
  } finally { lock.releaseLock(); }
}

function accMarcarManual_(p) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const est = estudiantes_().filas.find(e => String(e.ID) === String(p.id));
    if (!est) return { ok: false, mensaje: 'Estudiante no encontrado.' };
    const fecha = /^\d{4}-\d{2}-\d{2}$/.test(p.fecha || '') ? p.fecha : hoy_();
    if (fecha > hoy_()) return { ok: false, mensaje: 'No se puede marcar asistencia en una fecha futura.' };
    return marcar_(est, 'Administrador', {}, fecha === hoy_() ? null : fecha);
  } finally { lock.releaseLock(); }
}

/* ============================ GRUPOS ============================ */

function accGuardarGrupo_(p) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const { sh, filas } = grupos_();
    const nombre = limpio_(p.grupo).toUpperCase();
    const original = limpio_(p.original || '');
    if (!nombre) return { ok: false, mensaje: 'Escribe el nombre del grupo.' };
    if (nombre.length > 60) return { ok: false, mensaje: 'El nombre del grupo es muy largo.' };
    const datos = { Grupo: nombre, Nivel: limpio_(p.nivel), Docente: limpio_(p.docente), Turno: limpio_(p.turno) };

    const existente = filas.find(g => g.Grupo === (original || nombre));
    if (original && original !== nombre && filas.some(g => g.Grupo === nombre))
      return { ok: false, mensaje: 'Ya existe un grupo llamado ' + nombre + '.' };
    if (!original && existente) return { ok: false, mensaje: 'Ya existe un grupo llamado ' + nombre + '.' };

    if (existente) escribirFila_(sh, existente._fila, datos);
    else agregarFila_(sh, Object.assign(datos, { Creado: Utilities.formatDate(ahora_(), CFG.ZONA_HORARIA, 'yyyy-MM-dd HH:mm') }));

    // renombrar o cambiar nivel: actualizar a los estudiantes del grupo
    if (original) {
      const est = estudiantes_();
      est.filas.filter(e => e.Grupo === original).forEach(e => {
        const cambio = { Grupo: nombre };
        if (!e.Nivel || e.Nivel === (existente ? existente.Nivel : '')) cambio.Nivel = datos.Nivel;
        escribirFila_(est.sh, e._fila, cambio);
      });
    }
    return { ok: true, mensaje: existente ? 'Grupo actualizado.' : 'Grupo creado.' };
  } finally { lock.releaseLock(); }
}

function accEliminarGrupo_(p) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const nombre = limpio_(p.grupo);
    const enUso = estudiantes_().filas.filter(e => e.Grupo === nombre).length;
    if (enUso) return { ok: false, mensaje: 'El grupo tiene ' + enUso + ' estudiante(s). Muévelos a otro grupo antes de eliminarlo.' };
    const { sh, filas } = grupos_();
    const g = filas.find(x => x.Grupo === nombre);
    if (!g) return { ok: false, mensaje: 'Grupo no encontrado.' };
    sh.deleteRow(g._fila);
    return { ok: true, mensaje: 'Grupo eliminado.' };
  } finally { lock.releaseLock(); }
}

/* ============================ REPORTES ============================ */

function accReporte_(desde, hasta) {
  const re = /^\d{4}-\d{2}-\d{2}$/;
  if (!re.test(desde || '') || !re.test(hasta || '')) return { ok: false, mensaje: 'Fechas no válidas.' };
  if (desde > hasta) return { ok: false, mensaje: 'La fecha inicial es posterior a la final.' };

  const sh = asistenciaHoja_();
  const enc = encabezadosDe_(sh);
  const ix = c => indiceCol_(enc, c);
  const n = sh.getLastRow() - 1;
  const registros = [];
  if (n >= 1) {
    sh.getRange(2, 1, n, enc.length).getValues().forEach(r => {
      const f = celdaTexto_(r[ix('Fecha')], 'Fecha');
      if (f >= desde && f <= hasta) registros.push(filaAsistencia_(r, ix));
    });
  }
  const lista = accListar_();
  return { ok: true, desde, hasta, estudiantes: lista.estudiantes, grupos: lista.grupos, registros };
}

/* ============================ INSTALACIÓN ============================ */
/* Ejecuta esta función una vez desde el editor (▶ Ejecutar) para crear las hojas. */
function instalar() {
  hoja_(CFG.HOJA_GRUPOS, COLS.grp);
  estudiantes_();
  asistenciaHoja_();
  Logger.log('Listo. Hojas creadas/actualizadas. Ahora: Implementar → Nueva implementación → Aplicación web.');
}
