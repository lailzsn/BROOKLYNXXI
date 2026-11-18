// PWA: cache apenas arquivos visuais; chamadas Supabase continuam online.
const CACHE='brooklynxxi-v39-agenda';
const ASSETS=['./','./index.html','./logo.jpg','./barbearia-fundo.jpg','./instagram.svg','./whatsapp.svg','./maps.svg','./manifest.webmanifest','./icons/icon-192.png','./icons/icon-512.png','./icons/apple-touch-icon.png','./apple-touch-icon.png','./favicon.png'];
// Não falhar a instalação inteira se um recurso estático estiver indisponível.
self.addEventListener('install',event=>{
 event.waitUntil(caches.open(CACHE).then(async cache=>{
  await Promise.allSettled(ASSETS.filter(a=>a!=='./'&&a!=='./index.html').map(a=>cache.add(a)));
 }).then(()=>self.skipWaiting()));
});
self.addEventListener('activate',event=>{
 event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('brooklynxxi-')&&k!==CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch',event=>{
 const req=event.request,url=new URL(req.url);
 if(req.method!=='GET'||url.origin!==self.location.origin)return;
 // HTML sempre vem da rede, para não manter código antigo no iPhone.
 if(req.mode==='navigate'||url.pathname.endsWith('/index.html')){
  event.respondWith(fetch(req));return;
 }
 event.respondWith(fetch(req).then(response=>{
  if(response.ok&&ASSETS.some(a=>new URL(a,self.registration.scope).pathname===url.pathname)){
   const copy=response.clone();event.waitUntil(caches.open(CACHE).then(c=>c.put(req,copy)));
  }
  return response;
 }).catch(()=>caches.match(req)));
});

// V24 — push recebido mesmo com o app fechado.
self.addEventListener('push',event=>{
 let data={};try{data=event.data?.json()||{}}catch{}
 event.waitUntil(self.registration.showNotification(String(data.title||'BROOKLYNXXI • Novo agendamento').slice(0,90),{
  body:String(data.body||'Você recebeu uma nova solicitação de agendamento.').slice(0,180),
  icon:'./icons/icon-192.png',badge:'./favicon.png',tag:String(data.tag||'novo-agendamento'),
  data:{url:(typeof data.url==='string'&&data.url.startsWith(self.registration.scope))?data.url:new URL('./',self.registration.scope).href}
 }));
});
self.addEventListener('notificationclick',event=>{
 event.notification.close();const url=event.notification.data?.url||self.registration.scope;
 event.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(async list=>{
  for(const c of list){if(c.url.startsWith(self.registration.scope)){await c.focus();c.navigate(url);return}}
  return clients.openWindow(url);
 }));
});
