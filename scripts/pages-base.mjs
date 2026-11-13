// Adapta dist/ para GitHub Pages, que publica el sitio en una subcarpeta
// (https://<usuario>.github.io/bizlaunch/) en vez de en la raíz de un dominio:
//  · cambia la dirección del sitio (SITE_URL) en páginas, sitemap, robots, etc.;
//  · antepone la subcarpeta a las rutas absolutas (/vendor/, /sw.js, /n/…).
// Uso: SITE_URL=https://usuario.github.io/bizlaunch/ node scripts/pages-base.mjs
import { readdir, readFile, writeFile } from 'node:fs/promises';

const OLD = 'https://bizlaunchpanama.netlify.app/';
const SITE = (process.env.SITE_URL || '').replace(/\/?$/, '/');
if (!/^https:\/\//.test(SITE)) { console.error('Falta SITE_URL'); process.exit(1); }
const BASE = new URL(SITE).pathname;                       // "/bizlaunch/"
const ROOT = new URL('../dist/', import.meta.url).pathname;
const PATHS = 'vendor/|paginas\\.json|geo\\.json|sw\\.js|site\\.webmanifest|apple-touch-icon\\.png|icon-192\\.png|icon-512\\.png|og-image\\.png|index\\.html|n/';
const ABS = new RegExp(`(["'\`(])/(${PATHS})`, 'g');
const TEXT = /\.(html|js|json|webmanifest|xml|txt)$/;

let files = 0;
async function walk(dir) {
  for (const f of await readdir(dir, { withFileTypes: true })) {
    const p = dir + f.name;
    if (f.isDirectory()) { await walk(p + '/'); continue; }
    if (!TEXT.test(f.name) || (dir.endsWith('/vendor/') && !f.name.endsWith('.webmanifest'))) continue;
    const src = await readFile(p, 'utf8');
    let out = src.split(OLD).join(SITE).split(OLD.slice(0, -1)).join(SITE.slice(0, -1));
    if (BASE !== '/') out = out.replace(ABS, `$1${BASE}$2`);
    if (out !== src) { await writeFile(p, out); files++; }
  }
}
await walk(ROOT);
console.log(`[pages] ${files} archivos adaptados a ${SITE}`);
