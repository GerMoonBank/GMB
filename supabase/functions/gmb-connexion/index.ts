// =============================================================================
// GerMoonBank (GMB) · supabase/functions/gmb-connexion/index.ts
// Fonction serveur de connexion à l'Espace client — version 5 (2026-10-07)
// -----------------------------------------------------------------------------
// Une simple ouverture de son adresse dans un navigateur (GET) répond par son état :
// {"statut":"ok", ...} quand tout est en service. Aucune donnée, aucun secret.
// Actions (POST JSON { action, ... }) :
//   etat                     la fonction répond-elle, joint-elle la base et le service
//                            des comptes avec la clé secrète du projet ? (aucune donnée)
//   clavier                  grille aléatoire à usage unique, touches dessinées
//                            (jamais les chiffres), valable 120 s ; réponse
//                            identique pour tout identifiant
//   code                     vérification des 8 positions ; appareil de confiance
//                            reconnu → session ; sinon code par e-mail (validation)
//   validation               code reçu par e-mail → session + appareil de confiance
//   activation-envoi         code par e-mail pour activer l'accès (première connexion)
//   activation               code e-mail + code secret saisi deux fois → compte
//                            technique bancaire distinct de Mon Dossier, appareil,
//                            session
//   reinitialisation-envoi   code par e-mail pour un code secret oublié ou bloqué
//   reinitialisation         code e-mail + nouveau code secret saisi deux fois →
//                            blocage levé, appareil, session
// Les codes sont toujours envoyés par e-mail, à l'adresse du dossier du client.
// Aucun jeton remis au navigateur ne contient d'adresse e-mail : le serveur la
// retrouve lui-même. Les réponses sont identiques que l'identifiant existe ou non.
// Secrets   : SUPABASE_URL et les clés du projet sont fournis par Supabase. La fonction
//             utilise les nouvelles clés (SUPABASE_SECRET_KEYS, SUPABASE_PUBLISHABLE_KEYS)
//             et, si elles sont absentes ou refusées, les anciennes (SUPABASE_SERVICE_ROLE_KEY,
//             SUPABASE_ANON_KEY), que Supabase retire fin 2026. Elle choisit seule celles
//             qui fonctionnent ; la clé secrète ne quitte jamais ce serveur.
//             Facultatif : GMB_ORIGINES (adresses autorisées, séparées par des virgules).
// Déploiement : Supabase › Edge Functions › nom « gmb-connexion », vérification du JWT
//             DÉSACTIVÉE (la fonction est appelée avant toute connexion, avec la clé
//             publiable du site, qui n'est pas un JWT).
// =============================================================================

import { createClient } from 'npm:@supabase/supabase-js@2';

const VERSION = '2026-10-07';

/** Clés du projet, dans l'ordre d'essai : la nouvelle (JSON { "default": "…" }), puis l'ancienne. */
function clesProjet(nouvelle: string, ancienne: string): string[] {
  const liste: string[] = [];
  try {
    const objet = JSON.parse(Deno.env.get(nouvelle) ?? '{}') as Record<string, unknown>;
    const cle = objet.default ?? Object.values(objet)[0];
    if (typeof cle === 'string' && cle) liste.push(cle);
  } catch {
    // variable absente ou illisible : l'ancienne clé prend le relais
  }
  const directe = Deno.env.get(ancienne);
  if (directe && !liste.includes(directe)) liste.push(directe);
  return liste;
}

const URL_SUPABASE = Deno.env.get('SUPABASE_URL') ?? '';
const CLES_SERVICE = clesProjet('SUPABASE_SECRET_KEYS', 'SUPABASE_SERVICE_ROLE_KEY');
const CLES_ANON = clesProjet('SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_ANON_KEY');
// Secret des jetons de transaction : toujours la première clé secrète connue, quelle que soit
// celle qui sert aux appels, pour qu'un jeton signé reste lisible d'une exécution à l'autre
const SECRET_JETONS = CLES_SERVICE[0] ?? '';
const ORIGINES = (Deno.env.get('GMB_ORIGINES') ?? 'https://germoonbank.github.io,http://localhost:8765,http://localhost:8766')
  .split(',').map((o) => o.trim()).filter(Boolean);
const DOMAINE_TECHNIQUE = 'clients.germoonbank.eu';
const DUREE_MIN_MS = 400; // temps de réponse homogène, quel que soit l'identifiant
const VALIDITE_CODE_EMAIL_MS = 600_000; // 10 minutes, comme la validité des codes e-mail de Supabase

// Tracés des chiffres (police Manrope 700, boîte de 40 × 40), déformés à chaque grille
const CHIFFRES: Record<string, string> = {"0": "M20 31.5Q17.7 31.5 15.9 30.5Q14.1 29.5 13.1 27.7Q12.1 25.9 12.1 23.6L12.1 16.6Q12.1 14.2 13.1 12.5Q14.1 10.7 15.9 9.7Q17.7 8.7 20 8.7Q22.3 8.7 24.1 9.7Q25.9 10.7 26.9 12.5Q27.9 14.2 27.9 16.6L27.9 23.6Q27.9 25.9 26.9 27.7Q25.9 29.5 24.1 30.5Q22.3 31.5 20 31.5ZM20 28Q21.2 28 22.1 27.4Q23 26.9 23.6 25.9Q24.1 25 24.1 23.9L24.1 16.3Q24.1 15.1 23.6 14.2Q23 13.2 22.1 12.7Q21.2 12.1 20 12.1Q18.8 12.1 17.9 12.7Q17 13.2 16.4 14.2Q15.9 15.1 15.9 16.3L15.9 23.9Q15.9 25 16.4 25.9Q17 26.9 17.9 27.4Q18.8 28 20 28Z", "1": "M19.3 31L19.3 13.1L15.2 15.6L15.2 11.6L19.3 9.2L23 9.2L23 31Z", "2": "M12.5 31L12.5 27.8L21.8 19.5Q22.9 18.5 23.3 17.6Q23.8 16.8 23.8 15.9Q23.8 14.9 23.3 14Q22.8 13.1 22 12.6Q21.2 12.1 20.1 12.1Q19 12.1 18.1 12.7Q17.2 13.2 16.7 14.1Q16.2 14.9 16.3 15.9L12.5 15.9Q12.5 13.7 13.5 12.1Q14.5 10.5 16.2 9.6Q17.9 8.7 20.2 8.7Q22.3 8.7 23.9 9.6Q25.6 10.6 26.6 12.2Q27.5 13.9 27.5 16Q27.5 17.6 27.1 18.6Q26.7 19.7 25.8 20.6Q25 21.5 23.7 22.6L17.1 28.4L16.8 27.5L27.5 27.5L27.5 31Z", "3": "M19.6 31.4Q17.9 31.4 16.5 30.8Q15 30.1 13.9 29Q12.9 27.8 12.4 26.2L15.9 25.2Q16.3 26.6 17.3 27.3Q18.3 28 19.5 28Q20.6 28 21.5 27.4Q22.3 26.9 22.8 26.1Q23.3 25.2 23.3 24.2Q23.3 22.5 22.2 21.5Q21.2 20.4 19.5 20.4Q19 20.4 18.6 20.5Q18.1 20.6 17.6 20.9L16 18L23.3 11.7L23.6 12.6L13.2 12.6L13.2 9.2L26.6 9.2L26.6 12.6L20.7 18.3L20.7 17.2Q22.7 17.3 24.1 18.3Q25.5 19.3 26.3 20.8Q27 22.4 27 24.2Q27 26.2 26 27.9Q25 29.5 23.3 30.5Q21.6 31.4 19.6 31.4Z", "4": "M22 31L22 27.4L12.3 27.4L12.3 24L19.3 9.2L23.5 9.2L16.5 24L22 24L22 18.3L25.7 18.3L25.7 24L27.7 24L27.7 27.4L25.7 27.4L25.7 31Z", "5": "M19.7 31.5Q18 31.5 16.6 30.8Q15.2 30.1 14.1 28.9Q13.1 27.6 12.6 26L16.1 25.1Q16.4 26 16.9 26.6Q17.5 27.3 18.3 27.6Q19 28 19.8 28Q20.9 28 21.8 27.4Q22.7 26.9 23.2 26Q23.7 25.2 23.7 24.1Q23.7 23 23.2 22.2Q22.7 21.3 21.8 20.8Q20.9 20.3 19.8 20.3Q18.6 20.3 17.8 20.7Q16.9 21.2 16.5 21.7L13.4 20.7L14 9.2L25.9 9.2L25.9 12.6L16 12.6L17.4 11.3L16.9 19.3L16.2 18.5Q17.1 17.7 18.2 17.4Q19.3 17 20.3 17Q22.4 17 24 17.9Q25.6 18.8 26.5 20.5Q27.4 22.1 27.4 24.1Q27.4 26.2 26.3 27.8Q25.2 29.5 23.5 30.5Q21.8 31.5 19.7 31.5Z", "6": "M20.3 31.5Q18.1 31.5 16.4 30.4Q14.7 29.4 13.7 27.6Q12.7 25.9 12.7 23.5L12.7 16.9Q12.7 14.4 13.7 12.6Q14.7 10.7 16.5 9.7Q18.3 8.7 20.7 8.7Q22.3 8.7 23.8 9.3Q25.3 9.8 26.4 11L23.8 13.6Q23.2 12.9 22.4 12.5Q21.6 12.1 20.7 12.1Q19.4 12.1 18.4 12.7Q17.5 13.3 17 14.3Q16.4 15.3 16.4 16.4L16.4 20L15.8 19.3Q16.7 18.2 18 17.6Q19.3 17 20.8 17Q22.8 17 24.4 17.9Q26 18.8 26.9 20.4Q27.8 22.1 27.8 24.1Q27.8 26.2 26.8 27.8Q25.7 29.5 24 30.5Q22.3 31.5 20.3 31.5ZM20.3 28Q21.3 28 22.2 27.4Q23.1 26.9 23.6 26.1Q24.1 25.2 24.1 24.1Q24.1 23.1 23.6 22.2Q23.1 21.3 22.2 20.8Q21.3 20.3 20.3 20.3Q19.2 20.3 18.3 20.8Q17.5 21.3 16.9 22.2Q16.4 23.1 16.4 24.1Q16.4 25.2 16.9 26Q17.4 26.9 18.3 27.4Q19.2 28 20.3 28Z", "7": "M15.1 31L22.7 12.6L13.1 12.6L13.1 9.2L26.6 9.2L26.6 12.6L19.1 31Z", "8": "M20 31.5Q17.8 31.5 16.1 30.6Q14.4 29.7 13.5 28.1Q12.5 26.6 12.5 24.6Q12.5 22.7 13.4 21.2Q14.2 19.7 15.8 18.7L15.7 19.9Q14.5 18.9 13.8 17.7Q13.1 16.4 13.1 14.9Q13.1 13 14 11.6Q14.9 10.2 16.4 9.5Q18 8.7 20 8.7Q22 8.7 23.6 9.5Q25.1 10.2 26 11.6Q26.9 13 26.9 14.9Q26.9 16.4 26.2 17.7Q25.6 18.9 24.2 19.9L24.2 18.7Q25.8 19.6 26.6 21.2Q27.5 22.7 27.5 24.6Q27.5 26.6 26.5 28.1Q25.5 29.7 23.9 30.6Q22.2 31.5 20 31.5ZM20 28Q21.6 28 22.6 27.1Q23.6 26.3 23.6 24.6Q23.6 22.9 22.6 22Q21.6 21.1 20 21.1Q18.4 21.1 17.4 22Q16.4 22.9 16.4 24.6Q16.4 26.3 17.4 27.1Q18.4 28 20 28ZM20 17.6Q21.3 17.6 22.2 16.9Q23 16.3 23 14.9Q23 13.5 22.2 12.8Q21.3 12.1 20 12.1Q18.6 12.1 17.8 12.8Q17 13.5 17 14.9Q17 16.3 17.8 16.9Q18.6 17.6 20 17.6Z", "9": "M19.7 8.7Q21.9 8.7 23.6 9.7Q25.3 10.7 26.3 12.5Q27.3 14.3 27.3 16.6L27.3 23.3Q27.3 25.8 26.3 27.6Q25.3 29.5 23.5 30.5Q21.7 31.5 19.3 31.5Q17.7 31.5 16.2 30.9Q14.7 30.3 13.6 29.1L16.2 26.6Q16.8 27.3 17.6 27.6Q18.4 28 19.3 28Q20.6 28 21.6 27.4Q22.5 26.8 23.1 25.9Q23.6 24.9 23.6 23.8L23.6 20.2L24.2 20.9Q23.3 22 22 22.6Q20.7 23.2 19.2 23.2Q17.2 23.2 15.6 22.3Q14 21.3 13.1 19.7Q12.2 18.1 12.2 16.1Q12.2 14 13.2 12.3Q14.3 10.7 16 9.7Q17.7 8.7 19.7 8.7ZM19.7 12.2Q18.7 12.2 17.8 12.7Q16.9 13.2 16.4 14.1Q15.9 15 15.9 16.1Q15.9 17.1 16.4 18Q16.9 18.9 17.8 19.4Q18.7 19.9 19.7 19.9Q20.8 19.9 21.7 19.4Q22.5 18.9 23.1 18Q23.6 17.1 23.6 16.1Q23.6 15 23.1 14.2Q22.6 13.3 21.7 12.7Q20.8 12.2 19.7 12.2Z"};

const creerClient = (cle: string) => createClient(URL_SUPABASE || 'http://localhost', cle || 'cle-absente', { auth: { persistSession: false, autoRefreshToken: false } });
// Clés retenues : la première de chaque liste, jusqu'au contrôle fait au premier appel (choisirCles)
let admin = creerClient(CLES_SERVICE[0] ?? '');
let cleAnonyme = CLES_ANON[0] ?? '';
let clesRetenues = 'non contrôlées';
const anonyme = () => creerClient(cleAnonyme);

/** Une clé refusée par Supabase : inconnue, désactivée, ou sans les droits du rôle serveur. */
const cleRefusee = (statut: number, code?: string) => statut === 401 || statut === 403 || code === '42501' || code === 'PGRST301' || code === 'PGRST302';
const sorte = (cle: string) => (cle.startsWith('sb_') ? 'nouvelles' : 'anciennes');

/** Retient, une fois par démarrage, la première clé secrète et la première clé publique acceptées. */
let choix: Promise<void> | null = null;
function choisirCles(): Promise<void> {
  choix ??= (async () => {
    let service = '';
    for (const cle of CLES_SERVICE) {
      const candidat = creerClient(cle);
      // Fonction réservée au rôle serveur : une clé publique ou refusée ne passe pas
      const { error, status } = await candidat.rpc('gmb_code_secret_controler', { p_identifiant: '00000000', p_code: '' });
      if (!error || !cleRefusee(status, error.code)) {
        admin = candidat;
        service = sorte(cle);
        break;
      }
    }
    let publique = '';
    for (const cle of CLES_ANON) {
      const { error, status } = await creerClient(cle).rpc('gmb_version');
      if (!error || !cleRefusee(status, error.code)) {
        cleAnonyme = cle;
        publique = sorte(cle);
        break;
      }
    }
    clesRetenues = service && publique ? (service === publique ? service : `secrète ${service}, publique ${publique}`) : 'refusées';
    if (!service || !publique) choix = null; // un prochain appel réessaiera
  })().catch((erreur) => {
    choix = null;
    console.error('gmb-connexion choix des clés', erreur instanceof Error ? erreur.message : 'erreur');
  });
  return choix;
}

type Corps = Record<string, unknown>;
type Reponse = Record<string, unknown>;

// -----------------------------------------------------------------------------
// Outils
// -----------------------------------------------------------------------------
function entetes(origine: string | null, demandes: string | null = null, public_ = false): HeadersInit {
  const autorisee = origine !== null && ORIGINES.includes(origine);
  return {
    // L'état de la fonction (GET) ne contient aucune donnée : toute page peut le lire, dont le module d'installation
    'Access-Control-Allow-Origin': public_ ? '*' : autorisee ? origine : ORIGINES[0],
    'Access-Control-Allow-Headers': demandes && /^[A-Za-z0-9, -]{1,400}$/.test(demandes) ? demandes : 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Max-Age': '600',
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    Vary: 'Origin',
  };
}

const octetsEnHex = (o: Uint8Array) => [...o].map((x) => x.toString(16).padStart(2, '0')).join('');

function aleatoireHex(octets: number): string {
  return octetsEnHex(crypto.getRandomValues(new Uint8Array(octets)));
}

async function sha256(texte: string): Promise<string> {
  return octetsEnHex(new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texte))));
}

function cleHmac(): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', new TextEncoder().encode(`gmb-transaction:${SECRET_JETONS}`), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}

const b64url = (texte: string) => btoa(unescape(encodeURIComponent(texte))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const deB64url = (texte: string) => decodeURIComponent(escape(atob(texte.replace(/-/g, '+').replace(/_/g, '/'))));

/** Jeton de transaction signé (aucune donnée sensible lisible côté navigateur). */
async function signer(contenu: Record<string, unknown>): Promise<string> {
  const charge = b64url(JSON.stringify(contenu));
  const signature = octetsEnHex(new Uint8Array(await crypto.subtle.sign('HMAC', await cleHmac(), new TextEncoder().encode(charge))));
  return `${charge}.${signature}`;
}

async function lireJeton(jeton: unknown): Promise<Record<string, unknown> | null> {
  if (typeof jeton !== 'string' || !jeton.includes('.')) return null;
  const [charge, signature] = jeton.split('.');
  const attendue = octetsEnHex(new Uint8Array(await crypto.subtle.sign('HMAC', await cleHmac(), new TextEncoder().encode(charge))));
  if (attendue.length !== signature.length || attendue !== signature) return null;
  try {
    return JSON.parse(deB64url(charge));
  } catch {
    return null;
  }
}

function masquer(email: string): string {
  const [local, domaine] = email.split('@');
  return `${local.slice(0, 1)}${'•'.repeat(Math.max(3, Math.min(8, local.length - 1)))}@${domaine}`;
}

function nomAppareil(propose: unknown, req: Request): string {
  const texte = typeof propose === 'string' ? propose.replace(/[^\p{L}\p{N} .,'’()-]/gu, '').slice(0, 60).trim() : '';
  if (texte) return texte;
  const agent = req.headers.get('user-agent') ?? '';
  const navigateur = /Edg\//.test(agent) ? 'Edge' : /Firefox\//.test(agent) ? 'Firefox' : /Chrome\//.test(agent) ? 'Chrome' : /Safari\//.test(agent) ? 'Safari' : 'Navigateur';
  const systeme = /Android/.test(agent) ? 'Android' : /iPhone|iPad/.test(agent) ? 'iOS' : /Windows/.test(agent) ? 'Windows' : /Mac OS/.test(agent) ? 'macOS' : /Linux/.test(agent) ? 'Linux' : '';
  return systeme ? `${navigateur} sur ${systeme}` : navigateur;
}

/** Déforme légèrement un tracé (rotation, échelle, décalage) pour qu'il soit unique. */
function deformer(trace: string): string {
  const angle = ((Math.random() - 0.5) * 10 * Math.PI) / 180;
  const echelle = 0.94 + Math.random() * 0.12;
  const dx = (Math.random() - 0.5) * 3;
  const dy = (Math.random() - 0.5) * 3;
  const cos = Math.cos(angle) * echelle;
  const sin = Math.sin(angle) * echelle;
  const jetons = trace.match(/[MLQCZ]|-?\d+(?:\.\d+)?/g) ?? [];
  const sortie: string[] = [];
  let tampon: number[] = [];
  for (const j of jetons) {
    if (/[MLQCZ]/.test(j)) {
      sortie.push(j);
      continue;
    }
    tampon.push(Number(j));
    if (tampon.length === 2) {
      const [x, y] = tampon;
      const cx = x - 20;
      const cy = y - 20;
      const nx = 20 + cx * cos - cy * sin + dx;
      const ny = 20 + cx * sin + cy * cos + dy;
      sortie.push(`${nx.toFixed(2)} ${ny.toFixed(2)}`);
      tampon = [];
    }
  }
  return sortie.join(' ').replace(/ ([MLQCZ])/g, '$1').replace(/([MLQCZ]) /g, '$1');
}

// -----------------------------------------------------------------------------
// Session et second facteur
// -----------------------------------------------------------------------------
async function ouvrirSession(authUserId: string): Promise<Reponse> {
  const { data: u, error } = await admin.auth.admin.getUserById(authUserId);
  if (error || !u?.user?.email) throw new Error('compte technique introuvable');
  const { data: lien, error: e2 } = await admin.auth.admin.generateLink({ type: 'magiclink', email: u.user.email });
  if (e2 || !lien?.properties?.hashed_token) throw new Error('lien de session impossible');
  const client = anonyme();
  let r = await client.auth.verifyOtp({ type: 'email', token_hash: lien.properties.hashed_token });
  if (r.error) r = await client.auth.verifyOtp({ type: 'magiclink', token_hash: lien.properties.hashed_token });
  if (r.error || !r.data?.session) throw new Error('session impossible');
  const s = r.data.session;
  return { access_token: s.access_token, refresh_token: s.refresh_token, expires_at: s.expires_at };
}

/** Client et adresse de contact (celle de son dossier) : elle reçoit les codes. */
type LigneClient = { id: string; auth_user_id: string | null; statut: string; personnes: { email: string | null } | null };
type Contact = { clientId: string; authUserId: string | null; email: string | null };
async function contactParIdentifiant(identifiant: string): Promise<Contact | null> {
  const { data } = await admin.from('clients').select('id, auth_user_id, statut, personnes(email)').eq('identifiant', identifiant).maybeSingle();
  const ligne = data as unknown as LigneClient | null;
  if (!ligne || ligne.statut !== 'actif') return null;
  return { clientId: ligne.id, authUserId: ligne.auth_user_id ?? null, email: ligne.personnes?.email ?? null };
}
async function contactParClient(clientId: string): Promise<string | null> {
  const { data } = await admin.from('clients').select('personnes(email)').eq('id', clientId).maybeSingle();
  return (data as unknown as Pick<LigneClient, 'personnes'> | null)?.personnes?.email ?? null;
}

/** Envoie un code à 6 chiffres par e-mail. Supabase n'envoie qu'un e-mail par minute à une
 *  même adresse, et un nombre limité d'e-mails par heure pour tout le projet. */
type Envoi = { ok: true } | { ok: false; attente: number | null; limite: boolean; detail: string };
async function envoyerCode(email: string): Promise<Envoi> {
  const { error } = await anonyme().auth.signInWithOtp({ email, options: { shouldCreateUser: false } });
  if (!error) return { ok: true };
  const texte = error.message ?? '';
  const secondes = /after (\d+) seconds?/i.exec(texte);
  // deno-lint-ignore no-explicit-any
  const limite = (error as any).status === 429 || /rate limit/i.test(texte);
  console.error('gmb-connexion envoi du code', (error as { code?: string }).code ?? '', texte);
  return { ok: false, attente: secondes ? Number(secondes[1]) : null, limite, detail: texte };
}

async function envoyerSecondFacteur(authUserId: string, clientId: string): Promise<Reponse> {
  const destination = await contactParClient(clientId);
  if (!destination) return { statut: 'erreur', message: 'Aucun moyen de validation n’est disponible. Contactez votre conseiller.' };
  const envoi = await envoyerCode(destination);
  if (!envoi.ok) {
    if (envoi.attente) return { statut: 'patienter', attente: envoi.attente, message: `Un code vient déjà d’être envoyé à votre adresse e-mail. Pour en recevoir un nouveau, patientez ${envoi.attente} seconde${envoi.attente > 1 ? 's' : ''}, puis saisissez de nouveau votre code secret.` };
    if (envoi.limite) return { statut: 'patienter', attente: null, message: 'Trop de codes ont été demandés en peu de temps. Réessayez dans quelques minutes.' };
    return { statut: 'erreur', message: 'Le code de validation n’a pas pu être envoyé par e-mail. Réessayez dans un instant ; si le problème persiste, contactez le service clients (référence : envoi-code).' };
  }
  const expiration = Date.now() + VALIDITE_CODE_EMAIL_MS;
  return {
    statut: 'validation',
    transaction: await signer({ u: authUserId, c: clientId, x: expiration }),
    expire_le: new Date(expiration).toISOString(),
    destination: masquer(destination),
  };
}

async function enregistrerAppareil(clientId: string, nom: string): Promise<{ id: string; cle: string }> {
  const cle = aleatoireHex(32);
  const { data, error } = await admin.rpc('gmb_appareil_enregistrer', { p_client: clientId, p_nom: nom, p_plateforme: 'web', p_cle_hash: await sha256(cle) });
  if (error) throw error;
  return { id: data as string, cle };
}

// -----------------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------------
async function clavier(c: Corps): Promise<Reponse> {
  const identifiant = String(c.identifiant ?? '');
  if (!/^\d{8}$/.test(identifiant)) return { statut: 'format', message: 'L’identifiant comporte 8 chiffres.' };
  const { data, error } = await admin.rpc('gmb_clavier_nouveau', { p_identifiant: identifiant });
  if (error) return error.code === '54000'
    ? { statut: 'limite', message: 'Trop de tentatives. Patientez une minute.' }
    : { statut: 'erreur', message: 'Service momentanément indisponible. Réessayez dans un instant.' };
  const accessible = c.accessible === true;
  const touches = (data.touches as number[]).map((v) => {
    if (v === -1) return { type: 'vide' };
    if (v === -2) return { type: 'effacer' };
    return { type: 'chiffre', trace: deformer(CHIFFRES[String(v)]), ...(accessible ? { libelle: String(v) } : {}) };
  });
  return { statut: 'ok', grille: data.grille, touches, expire_le: data.expire_le };
}

async function verifierCode(c: Corps): Promise<Reponse> {
  const positions = Array.isArray(c.positions) ? c.positions.map(Number) : [];
  if (typeof c.grille !== 'string' || positions.length !== 8 || positions.some((p) => !Number.isInteger(p))) return { statut: 'format' };
  const { data: r, error } = await admin.rpc('gmb_clavier_verifier', { p_grille: c.grille, p_positions: positions });
  if (error) throw error;
  if (r.statut !== 'ok' || !r.auth_user_id) {
    if (r.statut === 'ok') return { statut: 'non_active', message: 'Votre accès n’est pas encore activé : activez-le avec le code envoyé par e-mail.' };
    return { statut: r.statut, essais_restants: r.essais_restants ?? null, bloque_jusqu: r.bloque_jusqu ?? null };
  }
  // deno-lint-ignore no-explicit-any
  const appareil = c.appareil as any;
  if (appareil?.id && typeof appareil?.cle === 'string') {
    const { data: connu } = await admin.rpc('gmb_appareil_reconnaitre', { p_client: r.client_id, p_appareil: appareil.id, p_cle_hash: await sha256(appareil.cle) });
    if (connu === true) return { statut: 'connecte', session: await ouvrirSession(r.auth_user_id) };
  }
  return envoyerSecondFacteur(r.auth_user_id, r.client_id);
}

async function validerAppareil(c: Corps, req: Request): Promise<Reponse> {
  const t = await lireJeton(c.transaction);
  if (!t || typeof t.x !== 'number' || t.x < Date.now()) return { statut: 'expire', message: 'La demande de validation a expiré. Reconnectez-vous.' };
  const code = String(c.code ?? '');
  if (!/^\d{6}$/.test(code)) return { statut: 'code_incorrect', message: 'Saisissez les 6 chiffres du code reçu.' };
  const client = anonyme();
  const email = await contactParClient(String(t.c));
  if (!email) return { statut: 'code_incorrect', message: 'Ce code est incorrect ou n’est plus valable.' };
  const v = await client.auth.verifyOtp({ email, token: code, type: 'email' });
  if (v.error) return { statut: 'code_incorrect', message: 'Ce code est incorrect ou n’est plus valable.' };
  await client.auth.signOut({ scope: 'local' });
  const appareil = await enregistrerAppareil(String(t.c), nomAppareil(c.appareil_nom, req));
  return { statut: 'connecte', session: await ouvrirSession(String(t.u)), appareil };
}

async function compteTechnique(identifiant: string): Promise<{ id: string; cree: boolean } | null> {
  const { data: client } = await admin.from('clients').select('id, auth_user_id').eq('identifiant', identifiant).maybeSingle();
  if (!client) return null;
  if (client.auth_user_id) {
    const { data: u } = await admin.auth.admin.getUserById(client.auth_user_id);
    if (u?.user?.app_metadata?.espace === 'client') return { id: client.auth_user_id, cree: false };
  }
  const email = `${identifiant}@${DOMAINE_TECHNIQUE}`;
  const { data: nouvel, error } = await admin.auth.admin.createUser({ email, email_confirm: true, password: aleatoireHex(24), app_metadata: { espace: 'client' } });
  if (!error && nouvel?.user) return { id: nouvel.user.id, cree: true };
  // Compte technique déjà créé lors d'une tentative précédente : on le retrouve, page après page
  for (let page = 1; page <= 100; page += 1) {
    const { data: liste } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    const comptes = liste?.users ?? [];
    const existant = comptes.find((u) => u.email === email);
    if (existant) return { id: existant.id, cree: false };
    if (comptes.length < 1000) break;
  }
  return null;
}

/** Envoi d'un code par e-mail pour activer l'accès ou réinitialiser le code secret.
 *  Réponse et durée identiques, que l'identifiant existe ou non. */
async function envoyerCodeEmail(c: Corps, but: 'activation' | 'reinitialisation'): Promise<Reponse> {
  const identifiant = String(c.identifiant ?? '');
  if (!/^\d{8}$/.test(identifiant)) return { statut: 'format', message: 'L’identifiant comporte 8 chiffres.' };
  const contact = await contactParIdentifiant(identifiant);
  const eligible = Boolean(contact?.email) && (but === 'activation' ? !contact?.authUserId : Boolean(contact?.authUserId));
  // Réponse identique que l'identifiant existe ou non : un échec d'envoi n'apparaît que dans le journal de la fonction
  if (eligible && contact?.email) await envoyerCode(contact.email);
  const expiration = Date.now() + VALIDITE_CODE_EMAIL_MS;
  return { statut: 'envoye', transaction: await signer({ i: identifiant, b: but, x: expiration }), expire_le: new Date(expiration).toISOString() };
}

/** Vérifie le code e-mail d'une transaction d'activation ou de réinitialisation. */
type Verification = { ok: true; identifiant: string } | { ok: false; reponse: Reponse };
async function verifierCodeEmail(c: Corps, but: 'activation' | 'reinitialisation'): Promise<Verification> {
  const t = await lireJeton(c.transaction);
  if (!t || t.b !== but || typeof t.x !== 'number' || t.x < Date.now()) return { ok: false, reponse: { statut: 'expire', message: 'La demande a expiré. Recommencez pour recevoir un nouveau code.' } };
  const code = String(c.code ?? '');
  if (!/^\d{6}$/.test(code)) return { ok: false, reponse: { statut: 'code_incorrect', message: 'Saisissez les 6 chiffres du code reçu par e-mail.' } };
  const identifiant = String(t.i ?? '');
  const contact = await contactParIdentifiant(identifiant);
  const eligible = Boolean(contact?.email) && (but === 'activation' ? !contact?.authUserId : Boolean(contact?.authUserId));
  if (!contact || !contact.email || !eligible) return { ok: false, reponse: { statut: 'code_incorrect', message: 'Ce code est incorrect ou n’est plus valable.' } };
  const client = anonyme();
  const v = await client.auth.verifyOtp({ email: contact.email, token: code, type: 'email' });
  if (v.error) return { ok: false, reponse: { statut: 'code_incorrect', message: 'Ce code est incorrect ou n’est plus valable.' } };
  await client.auth.signOut({ scope: 'local' });
  return { ok: true, identifiant };
}

/** Règles de solidité du code secret, contrôlées avant d'utiliser le code reçu par e-mail :
 *  un code secret refusé ne fait pas perdre le code e-mail. */
async function codeSecretRefuse(c: Corps, but: 'activation' | 'reinitialisation', code: string): Promise<Reponse | null> {
  const t = await lireJeton(c.transaction);
  if (!t || t.b !== but || typeof t.x !== 'number' || t.x < Date.now()) return null; // la suite répondra « expiré »
  const { data, error } = await admin.rpc('gmb_code_secret_controler', { p_identifiant: String(t.i ?? ''), p_code: code });
  if (error || !data?.probleme) return null;
  return { statut: 'code_refuse', code_email_conserve: true, message: String(data.probleme) };
}

/** Décode le code secret saisi deux fois sur deux claviers à usage unique. */
async function deuxCodes(c: Corps): Promise<string | Reponse> {
  const decoder = async (grille: unknown, positions: unknown) => {
    const { data, error } = await admin.rpc('gmb_clavier_decoder', { p_grille: grille, p_positions: positions });
    return error ? null : (data as string);
  };
  const code1 = await decoder(c.grille1, c.positions1);
  const code2 = await decoder(c.grille2, c.positions2);
  if (!code1 || !code2) return { statut: 'clavier_expire', message: 'Le clavier a expiré. Saisissez de nouveau votre code.' };
  if (code1 !== code2) return { statut: 'codes_differents', message: 'Les deux codes saisis sont différents. Recommencez.' };
  return code1;
}

async function activer(c: Corps, req: Request): Promise<Reponse> {
  // Les deux saisies du code secret sont comparées avant d'utiliser le code e-mail, qui ne sert qu'une fois
  const code = await deuxCodes(c);
  if (typeof code !== 'string') return code;
  const refus = await codeSecretRefuse(c, 'activation', code);
  if (refus) return refus;
  const v = await verifierCodeEmail(c, 'activation');
  if (!v.ok) return v.reponse;
  const compte = await compteTechnique(v.identifiant);
  if (!compte) return { statut: 'erreur', message: 'Activation impossible pour le moment. Contactez votre conseiller.' };
  const { data: r, error } = await admin.rpc('gmb_activer_client', { p_identifiant: v.identifiant, p_nouveau_code: code, p_auth_user: compte.id });
  if (error || r?.statut !== 'ok') {
    if (compte.cree) await admin.auth.admin.deleteUser(compte.id);
    if (error) return { statut: 'code_refuse', message: error.message };
    if (r?.statut === 'deja_active') return { statut: 'deja_active', message: 'Votre accès est déjà activé : connectez-vous.' };
    return { statut: 'erreur', message: 'Activation impossible pour le moment. Contactez votre conseiller.' };
  }
  const appareil = await enregistrerAppareil(r.client_id, nomAppareil(c.appareil_nom, req));
  return { statut: 'ok', session: await ouvrirSession(compte.id), appareil };
}

async function reinitialiser(c: Corps, req: Request): Promise<Reponse> {
  // Les deux saisies du code secret sont comparées avant d'utiliser le code e-mail, qui ne sert qu'une fois
  const code = await deuxCodes(c);
  if (typeof code !== 'string') return code;
  const refus = await codeSecretRefuse(c, 'reinitialisation', code);
  if (refus) return refus;
  const v = await verifierCodeEmail(c, 'reinitialisation');
  if (!v.ok) return v.reponse;
  const { data: r, error } = await admin.rpc('gmb_code_secret_reinitialiser', { p_identifiant: v.identifiant, p_nouveau_code: code });
  if (error) return { statut: 'code_refuse', message: error.message };
  if (r?.statut !== 'ok') return { statut: 'erreur', message: 'Réinitialisation impossible pour le moment. Contactez votre conseiller.' };
  const appareil = await enregistrerAppareil(r.client_id, nomAppareil(c.appareil_nom, req));
  return { statut: 'ok', session: await ouvrirSession(r.auth_user_id), appareil };
}

/** État de la fonction, pour le back-office et le module d'installation : aucune donnée, aucun secret.
 *  Contrôle la base, le rôle serveur de la clé secrète et le service des comptes. */
let etatConnu: { reponse: Reponse; jusqu: number } | null = null;
async function etat(): Promise<Reponse> {
  if (etatConnu && etatConnu.jusqu > Date.now()) return etatConnu.reponse;
  const reponse = await controlerEtat();
  // Un état « en service » est gardé 30 secondes : des appels répétés ne sollicitent pas la base
  etatConnu = reponse.statut === 'ok' ? { reponse, jusqu: Date.now() + 30_000 } : null;
  return reponse;
}
async function controlerEtat(): Promise<Reponse> {
  if (!URL_SUPABASE || !CLES_SERVICE.length || !CLES_ANON.length) return { statut: 'configuration', version: VERSION, message: 'Les clés du projet ne sont pas disponibles dans la fonction.' };
  if (clesRetenues === 'refusées') return { statut: 'configuration', version: VERSION, message: 'Supabase refuse les clés du projet fournies à la fonction.' };
  const base = await admin.rpc('gmb_version');
  if (base.error) {
    return cleRefusee(base.status, base.error.code)
      ? { statut: 'configuration', version: VERSION, message: 'Supabase refuse la clé secrète fournie à la fonction.', detail: base.error.code ?? String(base.status) }
      : { statut: 'base', version: VERSION, message: 'La fonction répond, mais la base ne lui répond pas ou n’est pas à jour.', detail: base.error.code ?? String(base.status) };
  }
  const role = await admin.rpc('gmb_code_secret_controler', { p_identifiant: '00000000', p_code: '' });
  if (role.error) {
    return cleRefusee(role.status, role.error.code)
      ? { statut: 'configuration', version: VERSION, message: 'La clé fournie à la fonction n’a pas les droits du serveur.', detail: role.error.code ?? String(role.status) }
      : { statut: 'base', version: VERSION, base: base.data, message: 'La fonction répond, mais la base n’est pas à jour.', detail: role.error.code ?? String(role.status) };
  }
  const comptes = await admin.auth.admin.listUsers({ page: 1, perPage: 1 });
  if (comptes.error) return { statut: 'configuration', version: VERSION, base: base.data, message: 'La fonction joint la base, mais pas le service des comptes.', detail: String(comptes.error.status ?? '') };
  return { statut: 'ok', version: VERSION, base: base.data, cles: clesRetenues };
}

function traiter(c: Corps, req: Request): Promise<Reponse> {
  switch (c.action) {
    case 'etat': return etat();
    case 'clavier': return clavier(c);
    case 'code': return verifierCode(c);
    case 'validation': return validerAppareil(c, req);
    case 'activation-envoi': return envoyerCodeEmail(c, 'activation');
    case 'activation': return activer(c, req);
    case 'reinitialisation-envoi': return envoyerCodeEmail(c, 'reinitialisation');
    case 'reinitialisation': return reinitialiser(c, req);
    default: return Promise.resolve({ statut: 'erreur', message: 'Action inconnue.' });
  }
}

Deno.serve(async (req: Request) => {
  const origine = req.headers.get('origin');
  if (req.method === 'OPTIONS') return new Response('ok', { headers: entetes(origine, req.headers.get('access-control-request-headers')) });
  if (req.method !== 'POST' && req.method !== 'GET') return new Response(JSON.stringify({ statut: 'erreur' }), { status: 405, headers: entetes(origine) });
  const debut = Date.now();
  let resultat: Reponse;
  try {
    await choisirCles();
    // Ouverte dans un navigateur (GET), la fonction répond par son état : de quoi vérifier son déploiement
    resultat = req.method === 'GET' ? { service: 'gmb-connexion', ...(await etat()) } : await traiter(await req.json(), req);
  } catch (erreur) {
    console.error('gmb-connexion', erreur instanceof Error ? erreur.message : 'erreur');
    resultat = { statut: 'erreur', message: 'Service momentanément indisponible. Réessayez dans un instant.' };
  }
  if (req.method === 'GET') return new Response(JSON.stringify(resultat), { status: 200, headers: entetes(origine, null, true) });
  const attente = DUREE_MIN_MS - (Date.now() - debut);
  if (attente > 0) await new Promise((r) => setTimeout(r, attente + Math.random() * 25));
  return new Response(JSON.stringify(resultat), { status: 200, headers: entetes(origine) });
});
