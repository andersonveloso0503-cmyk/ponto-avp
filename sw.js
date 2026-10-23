// Ponto AVP — service worker simples (necessário para o celular oferecer "Instalar app").
// Não guarda nada em cache: o ponto sempre precisa de internet.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  e.respondWith(fetch(e.request));
});
