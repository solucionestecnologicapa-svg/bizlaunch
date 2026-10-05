/* BizLaunch service worker: makes the site installable and lets it open with a weak signal.
   Pages and data always come from the network first; the cache is only a fallback. */
const V = 'bl-v1';
const SHELL = ['/', '/index.html', '/404.html', '/site.webmanifest', '/icon-192.png', '/icon-512.png', '/apple-touch-icon.png', '/og-image.png',
  '/vendor/supabase-2.117.2.js', '/vendor/emailjs-4.4.1.min.js', '/vendor/qrcode-1.0.0.min.js'];
self.addEventListener('install', e => { e.waitUntil(caches.open(V).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', e => {
  const r = e.request, u = new URL(r.url);
  if (r.method !== 'GET' || u.origin !== location.origin) return;            // Supabase, EmailJS, maps… untouched
  if (u.pathname.startsWith('/vendor/') || /\.(png|svg|webmanifest)$/.test(u.pathname)) {   // versioned files: cache first
    e.respondWith(caches.match(r).then(hit => hit || fetch(r).then(res => { if (res.ok) { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); } return res; })));
    return;
  }
  if (r.mode === 'navigate' || u.pathname.endsWith('.html') || u.pathname === '/paginas.json') {               // pages: network first
    e.respondWith(fetch(r).then(res => { if (res.ok) { const cp = res.clone(); caches.open(V).then(c => c.put(r, cp)); } return res; })
      .catch(() => caches.match(r).then(hit => hit || caches.match('/index.html'))));
  }
});
