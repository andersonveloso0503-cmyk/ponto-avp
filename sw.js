// Ponto AVP — service worker simples (necessário para o celular oferecer "Instalar app").
// Não guarda nada em cache: o ponto sempre precisa de internet.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  e.respondWith(fetch(e.request));
});

// avisos para fiscais
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { corpo: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.titulo || 'Ponto AVP', {
    body: d.corpo || '', icon: 'icone-192.png', badge: 'icone-192.png', tag: d.tag, renotify: true,
    data: { url: d.url || 'admin.html' }, vibrate: [200, 100, 200]
  }));
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const url = (e.notification.data && e.notification.data.url) || 'admin.html';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(cs => {
    const c = cs.find(x => x.url.includes('admin.html'));
    return c ? c.focus() : self.clients.openWindow(url);
  }));
});
