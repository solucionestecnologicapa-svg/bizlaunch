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
  const og = SITE + 'og-image.png', map = {}, urls = [];
  await rm(ROOT + 'n', { recursive: true, force: true });
  for (const row of rows) {
    const b = norm(row);
    if (!b || !b.slug || !/^[a-z0-9-]{1,80}$/.test(b.slug) || !isLive(b)) continue;
    await mkdir(ROOT + 'n/' + b.slug, { recursive: true });
    await writeFile(ROOT + 'n/' + b.slug + '/index.html', seoPage(tpl, b, og));
    map[b.id] = b.slug; urls.push(SITE + 'n/' + b.slug + '/');
  }
  dom.window.close();
  const d = new Date().toISOString().slice(0, 10), x = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  await writeFile(ROOT + 'sitemap.xml', `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n  <url><loc>${x(SITE)}</loc><lastmod>${d}</lastmod><changefreq>daily</changefreq><priority>1.0</priority></url>\n` +
    urls.map(u => `  <url><loc>${x(u)}</loc><lastmod>${d}</lastmod><changefreq>weekly</changefreq><priority>0.8</priority></url>`).join('\n') + (urls.length ? '\n' : '') + '</urlset>\n');
  await writeFile(ROOT + 'paginas.json', JSON.stringify({ map, at: new Date().toISOString() }));
  log(urls.length, 'páginas generadas');
}

copySite()
  .then(() => main().catch(e => console.error('[páginas] No se generaron las páginas:', e.message)))
  .catch(e => { console.error('[páginas] No se pudo preparar dist/:', e); process.exit(1); });
