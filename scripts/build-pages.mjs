// Prepara la carpeta dist/ que publica Netlify:
//  1. copia los archivos del sitio (sin node_modules, sql, scripts ni configuración);
//  2. genera una página propia para cada negocio activo (/n/<slug>/), el sitemap.xml
//     y paginas.json, usando el mismo código de index.html (seoPage) en jsdom.
// Si el paso 2 falla, el sitio se publica igual: solo se omiten las páginas nuevas.
import { readFile, writeFile, mkdir, rm, readdir, cp } from 'node:fs/promises';
import { JSDOM, VirtualConsole } from 'jsdom';

const SRC = new URL('..', import.meta.url).pathname;
const ROOT = SRC + 'dist/';
const log = (...a) => console.log('[páginas]', ...a);
const SKIP = new Set(['node_modules', 'dist', 'sql', 'scripts', 'package.json', 'package-lock.json', 'netlify.toml', 'README.md']);

async function copySite() {
  await rm(ROOT, { recursive: true, force: true }); await mkdir(ROOT, { recursive: true });
  for (const f of await readdir(SRC, { withFileTypes: true })) {
    if (f.name.startsWith('.') || SKIP.has(f.name)) continue;
    await cp(SRC + f.name, ROOT + f.name, { recursive: true });
  }
  log('sitio copiado a dist/');
}

// ---------- share image (1200×630) for each business, in its own page design ----------
let RESVG = null, FONTS = [];
async function ogTools() {
  if (RESVG !== null) return RESVG;
  try {
    RESVG = (await import('@resvg/resvg-js')).Resvg;
    const dir = SRC + 'node_modules/@expo-google-fonts/sora/';
    FONTS = [dir + '800ExtraBold/Sora_800ExtraBold.ttf', dir + '600SemiBold/Sora_600SemiBold.ttf', dir + '400Regular/Sora_400Regular.ttf'];
  } catch (e) { log('sin generador de imágenes para compartir:', e.message); RESVG = false; }
  return RESVG;
}
const xe = s => String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
function wrap(text, size, maxW, maxLines) {
  const words = String(text || '').split(/\s+/).filter(Boolean), lines = []; let cur = '';
  const w = t => t.length * size * 0.6;
  for (const word of words) { const t = cur ? cur + ' ' + word : word; if (w(t) <= maxW || !cur) cur = t; else { lines.push(cur); cur = word; } }
  if (cur) lines.push(cur);
  if (lines.length > maxLines) { lines.length = maxLines; lines[maxLines - 1] = lines[maxLines - 1].replace(/\s*\S*$/, '') + '…'; }
  return lines;
}
async function photoData(url) {
  if (!url || !/^https:/.test(url)) return '';
  try {
    const u = /images\.pexels\.com/.test(url) ? url.replace(/([?&])w=\d+/, '$1w=900') : url;
    const r = await fetch(u, { signal: AbortSignal.timeout(10000) }); if (!r.ok) return '';
    const type = (r.headers.get('content-type') || 'image/jpeg').split(';')[0];
    if (!/^image\/(jpeg|png|webp)$/.test(type)) return '';
    const buf = Buffer.from(await r.arrayBuffer()); if (buf.length > 6e6) return '';
    return `data:${type};base64,${buf.toString('base64')}`;
  } catch (e) { return ''; }
}
async function ogImage(b, T, cat, prov, tag) {
  const Resvg = await ogTools(); if (!Resvg) return null;
  const photo = await photoData(b.photos && b.photos[0]);
  const nameLines = wrap(b.name, 62, photo ? 520 : 1040, 3), fs = nameLines.length > 2 ? 54 : 62;
  const tagLines = wrap(tag, 25, photo ? 520 : 960, 2);
  const y0 = 205;
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630" viewBox="0 0 1200 630">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${T.acc}"/><stop offset="1" stop-color="${T.acc2}"/></linearGradient>
    <radialGradient id="o1" cx="0.12" cy="0.1" r="0.6"><stop offset="0" stop-color="${T.acc}" stop-opacity="${T.dark ? .35 : .22}"/><stop offset="1" stop-color="${T.acc}" stop-opacity="0"/></radialGradient>
    <radialGradient id="o2" cx="0.95" cy="0.95" r="0.55"><stop offset="0" stop-color="${T.acc2}" stop-opacity="${T.dark ? .3 : .2}"/><stop offset="1" stop-color="${T.acc2}" stop-opacity="0"/></radialGradient>
    <clipPath id="c"><rect x="652" y="52" width="496" height="526" rx="34"/></clipPath>
  </defs>
  <rect width="1200" height="630" fill="${T.bg}"/>
  <rect width="1200" height="630" fill="url(#o1)"/><rect width="1200" height="630" fill="url(#o2)"/>
  ${photo ? `<rect x="640" y="40" width="520" height="550" rx="44" fill="url(#g)"/><image href="${photo}" x="652" y="52" width="496" height="526" preserveAspectRatio="xMidYMid slice" clip-path="url(#c)"/>` : ''}
  <rect x="64" y="70" width="${Math.min(570, 44 + (cat + ' · ' + prov).length * 12.6)}" height="40" rx="20" fill="${T.acc}" fill-opacity=".14" stroke="${T.acc}" stroke-opacity=".45"/>
  <text x="84" y="96" font-family="Sora" font-weight="600" font-size="17" letter-spacing="2" fill="${T.acct}">${xe((cat + ' · ' + prov).toUpperCase())}</text>
  ${nameLines.map((l, i) => `<text x="64" y="${y0 + i * fs * 1.08}" font-family="Sora" font-weight="800" font-size="${fs}" fill="${T.txt}">${xe(l)}</text>`).join('')}
  ${tagLines.map((l, i) => `<text x="64" y="${y0 + nameLines.length * fs * 1.08 + 18 + i * 34}" font-family="Sora" font-weight="400" font-size="25" fill="${T.mut}">${xe(l)}</text>`).join('')}
  <rect x="64" y="496" width="340" height="64" rx="32" fill="#25D366"/>
  <text x="234" y="536" text-anchor="middle" font-family="Sora" font-weight="600" font-size="21" fill="#fff">Escríbenos por WhatsApp</text>
  <text x="430" y="536" font-family="Sora" font-weight="600" font-size="19" fill="${T.mut}">BizLaunch · Panamá</text>
  <rect x="0" y="618" width="1200" height="12" fill="url(#g)"/>
</svg>`;
  try {
    const png = new Resvg(svg, { fitTo: { mode: 'width', value: 1200 }, font: { fontFiles: FONTS, loadSystemFonts: false, defaultFontFamily: 'Sora' } }).render().asPng();
    return png;
  } catch (e) { log('imagen para compartir falló en', b.slug, e.message); return null; }
}

async function main() {
  const tpl = await readFile(ROOT + 'index.html', 'utf8');
  const cfg = k => (tpl.match(new RegExp(k + ":\\s*'([^']+)'")) || [])[1];
  const SB_URL = cfg('SB_URL'), SB_KEY = cfg('SB_KEY'), SITE = (cfg('SITE') || '').replace(/\/?$/, '/');
  if (!SB_URL || !SB_KEY || !SITE) throw new Error('No se encontró la configuración en index.html');
  const cols = (tpl.match(/const PUB_COLS = '([^']+)'/) || [])[1];
  const res = await fetch(`${SB_URL}/rest/v1/negocios?select=${cols}&active=eq.true`, { headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY } });
  if (!res.ok) throw new Error('Supabase respondió ' + res.status);
  const rows = await res.json();
  log(rows.length, 'negocios activos');

  // load the real page logic with every network call stubbed out
  const html = tpl.replace(/<script src="[^"]+"><\/script>/g, '');
  const q = () => { const api = { select: () => api, eq: () => api, gte: () => api, order: () => api, limit: () => api, in: () => api, maybeSingle: () => api, then: (r) => Promise.resolve({ data: [], error: null }).then(r) }; return api; };
  const fake = { from: q, rpc: () => Promise.resolve({ data: null, error: null }), auth: { getSession: () => Promise.resolve({ data: {} }), onAuthStateChange() {} }, storage: { from: () => ({}) } };
  const vc = new VirtualConsole();
  const dom = new JSDOM(html, { runScripts: 'dangerously', url: SITE, virtualConsole: vc, pretendToBeVisual: true,
    beforeParse(w) { w.supabase = { createClient: () => fake }; w.IntersectionObserver = class { observe() {} unobserve() {} }; w.matchMedia = () => ({ matches: true, addListener() {}, addEventListener() {} }); w.HTMLElement.prototype.scrollTo = function () {}; w.scrollTo = () => {}; } });
  await new Promise(r => setTimeout(r, 300));
  const W = dom.window, seoPage = W.eval('seoPage'), norm = W.eval('norm'), isLive = W.eval('isLive');
  const og = SITE + 'og-image.png', map = {}, urls = []; let ogs = 0;
  const themeOf = W.eval('themeOf'), catOf = W.eval('catOf'), provLabel0 = W.eval('provLabel'), tagline = W.eval('tagline');
  const provLabel = provLabel0;
  await rm(ROOT + 'n', { recursive: true, force: true });
  for (const row of rows) {
    const b = norm(row);
    if (!b || !b.slug || !/^[a-z0-9-]{1,80}$/.test(b.slug) || !isLive(b)) continue;
    await mkdir(ROOT + 'n/' + b.slug, { recursive: true });
    let page = seoPage(tpl, b, og);
    const T = themeOf(b), png = await ogImage(b, T, catOf(b.category)[1], provLabel(b.province) || 'Panamá', tagline(b.desc) || (catOf(b.category)[1] + ' en ' + (provLabel(b.province) || 'Panamá')));
    if (png) {
      await writeFile(ROOT + 'n/' + b.slug + '/og.png', png); ogs++;
      const ogUrl = SITE + 'n/' + b.slug + '/og.png?v=' + Date.now().toString(36);
      page = page.replace(/<meta property="og:image" content="[^"]*">/, () => `<meta property="og:image" content="${xe(ogUrl)}">`)
        .replace(/<meta name="twitter:image" content="[^"]*">/, () => `<meta name="twitter:image" content="${xe(ogUrl)}">`);
    }
    await writeFile(ROOT + 'n/' + b.slug + '/index.html', page);
    map[b.id] = b.slug; urls.push(SITE + 'n/' + b.slug + '/');
  }
  // geo.json: coordinates for the directory map. Google Maps links already carry them;
  // other addresses are looked up once per build on OpenStreetMap (max 1 request/second).
  const coordsOf = W.eval('coordsOf'), geo = {};
  let lookups = 0;
  for (const row of rows) {
    const b = norm(row); if (!b || !isLive(b)) continue;
    const c = coordsOf(b.map); if (c) { geo[b.id] = [c[0], c[1], 1]; continue; }
    const text = (/^https?:/i.test(b.map) ? '' : b.map) || b.address; if (!text || lookups >= 150) continue;
    try {
      lookups++; await new Promise(r => setTimeout(r, 1100));
      const u = 'https://nominatim.openstreetmap.org/search?format=json&limit=1&countrycodes=pa&q=' + encodeURIComponent(text + ', ' + (provLabel(b.province) || '') + ', Panamá');
      const r = await fetch(u, { headers: { 'User-Agent': 'BizLaunch/1.0 (' + SITE + ')', 'Accept-Language': 'es' }, signal: AbortSignal.timeout(8000) });
      const j = r.ok ? await r.json() : [];
      if (j[0]) geo[b.id] = [+(+j[0].lat).toFixed(5), +(+j[0].lon).toFixed(5), 1];
    } catch (e) { /* the map falls back to the province */ }
  }
  await writeFile(ROOT + 'geo.json', JSON.stringify(geo));
  log(Object.keys(geo).length, 'negocios con ubicación para el mapa');
  dom.window.close();
  const d = new Date().toISOString().slice(0, 10), x = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  await writeFile(ROOT + 'sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url><loc>${x(SITE)}</loc><lastmod>${d}</lastmod><changefreq>daily</changefreq><priority>1.0</priority></url>\n` +
    urls.map(u => `  <url><loc>${x(u)}</loc><lastmod>${d}</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>`).join('\n') + (urls.length ? '\n' : '') + '</urlset>\n');
  await writeFile(ROOT + 'paginas.json', JSON.stringify({ map, at: new Date().toISOString() }));
  log(urls.length, 'páginas generadas,', ogs, 'imágenes para compartir');
}

copySite()
  .then(() => main().catch(e => console.error('[páginas] No se generaron las páginas:', e.message)))
  .catch(e => { console.error('[páginas] No se pudo preparar dist/:', e); process.exit(1); });
