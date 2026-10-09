/* =============================================================================
   GerMoonBank (GMB) · sw.js
   Service worker — version 5
   -----------------------------------------------------------------------------
   - Pages, scripts, feuilles de style et données : la version en ligne, toujours.
     Le serveur est interrogé à chaque fois (sans passer par la mémoire du
     navigateur, qui garde les fichiers dix minutes) : après une mise à jour du
     site, pages et scripts sont de la même version dès le rechargement suivant.
     La copie locale ne sert qu'hors ligne.
   - Polices et images : la copie locale d'abord (elles changent rarement).
   - Espaces privés (Espace client, Mon Dossier, ouverture de compte,
     authentification, back-office, module d'installation) : la version en ligne,
     jamais de copie locale.
   - Services extérieurs (Supabase, taux de la BCE) : jamais interceptés.
   - Changer VERSION supprime les anciennes copies à la mise à jour suivante et
     recharge les pages ouvertes : une page chargée pendant la mise à jour ne reste
     jamais avec des scripts de deux versions.
   ========================================================================== */

// Version 5 : remplace les copies de polices enregistrées alors que leurs fichiers étaient vides
const VERSION = 'gmb-v6-2026-10-09';
const DURABLES = /\.(?:woff2|png|jpg|jpeg|webp|svg|ico)$/i;
const PRIVES = /\/(?:app|auth|bo|mon-dossier|clients|public\/inscription|supabase)\//;

const PAGE_HORS_LIGNE = `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Hors ligne — GerMoonBank</title></head>
<body style="margin:0;min-height:100vh;display:grid;place-items:center;background:#F3F5FA;color:#1A1838;font-family:Manrope,system-ui,sans-serif">
<main style="max-width:28rem;padding:2rem;text-align:center"><h1 style="font-size:1.6rem">Vous êtes hors ligne</h1>
<p>Cette page n’a pas encore été consultée sur cet appareil. Vérifiez votre connexion internet, puis réessayez.</p></main></body></html>`;

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (evenement) => {
  const travail = (async () => {
    const anciennes = (await caches.keys()).filter((c) => c.startsWith('gmb-') && c !== VERSION);
    await Promise.all(anciennes.map((c) => caches.delete(c)));
    await self.clients.claim();
    return anciennes.length > 0;
  })();
  evenement.waitUntil(travail);
  // Une version précédente du site était en service : une fois celle-ci en place, les pages ouvertes
  // sont rechargées, pour que chaque page et ses scripts soient de la même version (le navigateur
  // garde les fichiers dix minutes). Le rechargement part après l'activation, jamais pendant.
  travail.then(async (miseAJour) => {
    if (!miseAJour) return;
    const fenetres = await self.clients.matchAll({ type: 'window' });
    fenetres.forEach((f) => f.navigate(f.url).catch(() => null));
  }).catch(() => null);
});

async function copieDAbord(requete) {
  const cache = await caches.open(VERSION);
  const copie = await cache.match(requete);
  if (copie) return copie;
  const reponse = await fetch(requete);
  if (reponse.ok) cache.put(requete, reponse.clone());
  return reponse;
}

/** La version en ligne : le serveur confirme ou renvoie le fichier, la mémoire du navigateur ne décide pas seule. */
const enLigne = (requete) => fetch(requete, { cache: 'no-cache' });

async function reseauDAbord(requete) {
  const cache = await caches.open(VERSION);
  try {
    const reponse = await enLigne(requete);
    if (reponse.ok) cache.put(requete, reponse.clone());
    return reponse;
  } catch (erreur) {
    const copie = await cache.match(requete);
    if (copie) return copie;
    if (requete.mode === 'navigate') {
      return new Response(PAGE_HORS_LIGNE, { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
    }
    throw erreur;
  }
}

self.addEventListener('fetch', (evenement) => {
  const requete = evenement.request;
  if (requete.method !== 'GET') return;
  const adresse = new URL(requete.url);
  if (adresse.origin !== self.location.origin) return;
  if (DURABLES.test(adresse.pathname)) evenement.respondWith(copieDAbord(requete));
  else if (PRIVES.test(adresse.pathname)) evenement.respondWith(enLigne(requete));
  else evenement.respondWith(reseauDAbord(requete));
});
