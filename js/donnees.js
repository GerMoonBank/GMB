/* =============================================================================
   GerMoonBank (GMB) · js/donnees.js
   Accès unique aux données — version 4 (2026-10-07)
   -----------------------------------------------------------------------------
   Règle du projet pendant le développement : aucune RLS dans la base. Ce module
   est donc le SEUL point d'accès aux tables, et il filtre chaque lecture et
   chaque écriture sur la personne connectée :
     espace « dossier »     demandes déposées par la personne (demandeur_auth)
     espace « client »      son client, ses comptes, ceux des entreprises dont
                            elle est membre active et ceux de ses enfants (Jeunes)
     espace « backoffice »  collaborateur actif : lecture de toutes les tables
                            déclarées ; ses droits sont vérifiés par les
                            fonctions gmb_bo_* de la base
   Une table absente du registre est refusée : rien ne peut être lu par erreur.
   L'argent, les cartes, les décisions et les signatures passent toujours par
   les fonctions contrôlées de la base (appeler), jamais par une écriture directe.
   ========================================================================== */

import { CONFIG, chemin, supabase } from './core.js';

/* -----------------------------------------------------------------------------
   1. CLIENT, DÉLAIS ET ERREURS
   -------------------------------------------------------------------------- */
export class ErreurGmb extends Error {}

const DELAI_MS = 15000;
const AUCUN = '00000000-0000-0000-0000-000000000000';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Version de la base attendue par le site (fonction gmb_version de la base). */
export const VERSION_BASE = 20261009;

/** Arrivée depuis un lien reçu par e-mail (modèle d'e-mail avec lien plutôt qu'avec code) :
 *  { type: 'signup' | 'magiclink' | 'recovery' | …, erreur: texte ou null }, ou null.
 *  Lue une fois, au chargement, avant que la session ne soit ouverte et l'adresse nettoyée. */
export const ARRIVEE_PAR_LIEN = (() => {
  try {
    const p = new URLSearchParams(String(globalThis.location?.hash || '').replace(/^#/, ''));
    const q = new URLSearchParams(globalThis.location?.search || '');
    const erreur = p.get('error_description') || q.get('error_description');
    if (erreur) return { type: p.get('type') || q.get('type') || null, erreur: erreur.replace(/\+/g, ' '), code: p.get('error_code') || q.get('error_code') || '' };
    if (p.get('access_token')) return { type: p.get('type') || 'magiclink', erreur: null, code: '' };
  } catch { /* adresse illisible : arrivée ordinaire */ }
  return null;
})();

export function avecDelai(promesse, ms = DELAI_MS) {
  let minuteur;
  const delai = new Promise((_, rejeter) => {
    minuteur = setTimeout(() => rejeter(new ErreurGmb('Le service met trop de temps à répondre. Réessayez dans un instant.')), ms);
  });
  return Promise.race([promesse, delai]).finally(() => clearTimeout(minuteur));
}

export async function client() {
  try {
    return await avecDelai(supabase());
  } catch {
    throw new ErreurGmb('Connexion impossible au service. Vérifiez votre connexion internet puis réessayez.');
  }
}

/** L'utilisateur est-il dans le back-office ? Les messages y nomment la cause technique. */
const AU_BACK_OFFICE = () => /\/bo\//.test(globalThis.location?.pathname || '');
const FRANCAIS = /[éèàùçêôîû’€«»]/;
const TECHNIQUE = /violates|syntax error|does not exist|permission denied|duplicate key|null value|invalid input|operator does not exist|schema cache|PGRST|JSON object|out of range|deadlock|timeout/i;

/** Délai d'attente annoncé par Supabase avant un nouvel e-mail, en secondes (null si absent). */
export function attenteEmail(erreur) {
  const m = /after (\d+) seconds?/i.exec(String(erreur?.message || ''));
  return m ? Number(m[1]) : null;
}

/** L'erreur vient-elle de la limite d'envoi d'e-mails (un par minute et par adresse, quota horaire) ? */
export function limiteEmail(erreur) {
  return erreur?.code === 'over_email_send_rate_limit' || (Number(erreur?.status) === 429 && /email|security purposes/i.test(String(erreur?.message || '')));
}

function avecReference(texte, reference) {
  return `${texte} (Référence : ${reference})`;
}

/** Objet de la base nommé par une erreur « introuvable » (table, fonction ou colonne). */
function objetManquant(m) {
  const t = /table '?(?:public\.)?([a-z_0-9]+)'?|relation "?(?:public\.)?([a-z_0-9]+)"?|function (?:public\.)?([a-z_0-9]+)|column "?([a-z_0-9.]+)"?|'([a-z_0-9]+)' column/i.exec(m);
  return t ? (t[1] || t[2] || t[3] || t[4] || t[5]) : '';
}

/** Traduit toute erreur (authentification, base, réseau) en message clair.
 *  Un message technique n'est jamais montré tel quel : il est remplacé par une phrase et une
 *  référence courte, et l'erreur complète est écrite dans la console du navigateur. */
export function messageErreur(erreur) {
  const m = String(erreur?.message || erreur || '');
  if (erreur instanceof ErreurGmb) return m;
  const code = String(erreur?.code || '');
  const statut = Number(erreur?.status || 0);

  // --- Authentification (codes d'erreur de Supabase Auth, puis anciens messages)
  if (code === 'invalid_credentials' || /invalid login credentials/i.test(m)) return 'Adresse e-mail ou mot de passe incorrect.';
  if (code === 'email_not_confirmed' || /email not confirmed/i.test(m)) return 'Votre adresse e-mail n’est pas encore confirmée. Recommencez « Ouvrir un compte » avec cette adresse : un nouveau code vous sera envoyé.';
  if (limiteEmail(erreur)) {
    const n = attenteEmail(erreur);
    return n ? `Un e-mail vient déjà de vous être envoyé. Vous pourrez en demander un nouveau dans ${n} seconde${n > 1 ? 's' : ''}.`
      : avecReference('Trop d’e-mails ont été demandés en peu de temps. Réessayez dans quelques minutes.', 'limite-emails');
  }
  if (code === 'over_request_rate_limit' || statut === 429 || /rate limit|too many requests/i.test(m)) return 'Trop de tentatives en peu de temps. Patientez quelques minutes avant de réessayer.';
  if (code === 'otp_expired' || /token has expired|otp.*(expired|invalid)|invalid.*(token|otp)/i.test(m)) return 'Ce code est incorrect ou n’est plus valable. Vérifiez-le, ou demandez un nouveau code.';
  if (code === 'user_already_exists' || code === 'email_exists' || /already registered|already been registered/i.test(m)) return 'Un accès existe déjà avec cette adresse e-mail. Connectez-vous à l’Espace Mon Dossier, ou réinitialisez votre mot de passe.';
  if (code === 'same_password') return 'Choisissez un mot de passe différent de votre mot de passe actuel.';
  if (code === 'weak_password' || (/password|pwned|leaked/i.test(m) && !FRANCAIS.test(m))) return 'Ce mot de passe n’est pas accepté. Choisissez-en un autre, d’au moins 12 caractères.';
  if (code === 'email_address_invalid') return 'Cette adresse e-mail n’est pas acceptée : vérifiez-la.';
  if (code === 'email_address_not_authorized') return avecReference('L’envoi d’e-mails n’est pas encore ouvert à cette adresse.', 'envoi-non-autorise');
  if (code === 'signup_disabled' || code === 'email_provider_disabled' || /signups not allowed for this instance/i.test(m)) return avecReference('La création d’accès est momentanément fermée.', 'inscriptions-fermees');
  if (code === 'otp_disabled' || /signups not allowed for otp/i.test(m)) return 'Aucun code ne peut être envoyé à cette adresse : vérifiez-la.';
  if (code === 'user_banned') return 'Cet accès est suspendu. Contactez le service clients.';
  if (/error sending .*email/i.test(m)) return avecReference('L’e-mail n’a pas pu être envoyé. Réessayez dans un instant.', 'envoi-email');
  if (['session_not_found', 'session_expired', 'refresh_token_not_found', 'refresh_token_already_used', 'bad_jwt', 'no_authorization', 'PGRST301', 'PGRST303'].includes(code)
      || /jwt expired|not authenticated|auth session missing/i.test(m)) return 'Votre session a expiré par sécurité. Reconnectez-vous pour continuer.';

  // --- Réseau
  if (/failed to fetch|networkerror|load failed|network request|fetch failed/i.test(m)) return 'Connexion impossible. Vérifiez votre connexion internet puis réessayez.';

  // --- Base de données
  if (['PGRST202', 'PGRST204', 'PGRST205', '42P01', '42883', '42703'].includes(code) || /schema cache/i.test(m)) {
    console.error('[GMB] base de données', erreur);
    const objet = objetManquant(m);
    return AU_BACK_OFFICE()
      ? `La base de données n’est pas à jour${objet ? ` : « ${objet} » est introuvable` : ''}. Exécutez la mise à niveau de la base (module d’installation), puis rechargez cette page.`
      : avecReference('Ce service est momentanément indisponible. Réessayez un peu plus tard.', `base-${code || 'structure'}`);
  }
  // Refus volontaires de la base (RAISE : 22xxx, 23xxx, 42501, 54xxx, 55xxx, P0xxx) : messages rédigés en français
  if (!TECHNIQUE.test(m) && (FRANCAIS.test(m) || /^(22|23|42501|54|55|P0)/.test(code)) && m) return m;
  console.error('[GMB] erreur', erreur);
  if (code === '23505') return 'Cet élément existe déjà.';
  if (code === '23514' || code === '22P02' || code === '22007' || code === '22008') return avecReference('Une valeur saisie n’est pas acceptée : vérifiez le formulaire.', `valeur-${code}`);
  if (code === '42501') return avecReference('Cette action ne vous est pas autorisée.', 'droits-42501');
  if (code === '57014') return 'Le service met trop de temps à répondre. Réessayez dans un instant.';
  const reference = code || (statut ? `http-${statut}` : '');
  return reference ? avecReference('Une erreur est survenue. Réessayez dans un instant.', reference) : 'Une erreur est survenue. Réessayez dans un instant.';
}

/** Appelle une fonction contrôlée de la base (gmb_*). */
export async function appeler(nom, parametres = {}) {
  const c = await client();
  const { data, error } = await avecDelai(c.rpc(nom, parametres));
  if (error) throw error;
  return data;
}

/** État d'une fonction serveur Supabase (Edge Function), lu par une requête simple (GET) :
 *    { etat, version, base, cles, message, cause }
 *    etat « ok », « base » ou « configuration » : la réponse de la fonction elle-même ;
 *    « ancienne » : une autre version répond sous ce nom ;
 *    « absente »  : Supabase répond, mais pas la fonction — elle n'est pas déployée sous ce nom
 *                   (cause « nom »), ou sa vérification du JWT est restée activée (cause « jwt ») ;
 *                   quand le navigateur ne peut pas lire la réponse, la cause reste vide ;
 *    « reseau »   : Supabase ne répond pas du tout. */
export async function etatFonction(nom) {
  const adresse = `${CONFIG.supabase.url}/functions/v1/${nom}`;
  try {
    const r = await avecDelai(fetch(adresse, { cache: 'no-store' }), 12000);
    if (r.status === 404) return { etat: 'absente', cause: 'nom' };
    if (r.status === 401 || r.status === 403) return { etat: 'absente', cause: 'jwt' };
    const j = await r.json().catch(() => null);
    if (r.ok && j?.service === nom && ['ok', 'base', 'configuration'].includes(j.statut)) return { etat: j.statut, version: j.version, base: j.base, cles: j.cles, message: j.message || '' };
    return { etat: 'ancienne' };
  } catch { /* réponse illisible par le navigateur, ou réseau coupé : la sonde suivante tranche */ }
  try {
    await avecDelai(fetch(adresse, { mode: 'no-cors', cache: 'no-store' }), 12000);
    return { etat: 'absente', cause: '' };
  } catch {
    return { etat: 'reseau' };
  }
}

/** Appelle une fonction serveur Supabase (Edge Function).
 *  Les causes d'échec sont distinguées : fonction absente ou fermée, panne (5xx), réseau coupé.
 *  Quand la fonction n'est pas déployée, le navigateur ne reçoit aucune réponse lisible : une
 *  seconde requête, simple, dit si c'est la fonction ou le réseau qui manque. */
export async function serveur(nom, corps = {}) {
  const c = await client();
  const { data, error } = await avecDelai(c.functions.invoke(nom, { body: corps }), 25000);
  if (!error) return data;
  let statut = Number(error.context?.status || 0);
  let reseau = false;
  if (!statut) {
    const f = await etatFonction(nom);
    if (f.etat === 'reseau') reseau = true;
    else statut = f.etat === 'absente' ? (f.cause === 'jwt' ? 401 : 404) : 503;
  }
  console.error('[GMB] fonction serveur', nom, statut || error.name, error);
  const erreur = new ErreurGmb(
    reseau ? 'Connexion impossible au service. Vérifiez votre connexion internet puis réessayez.'
      : statut === 404 ? 'Ce service n’est pas encore en ligne. Réessayez plus tard. (Référence : fonction-absente)'
        : statut === 401 || statut === 403 ? 'Ce service refuse la connexion pour le moment. Réessayez plus tard. (Référence : fonction-fermée)'
          : `Le service ne répond pas pour le moment. Réessayez dans un instant. (Référence : fonction-${statut})`);
  erreur.statutHttp = statut;
  throw erreur;
}

/* -----------------------------------------------------------------------------
   2. SESSION ET ESPACES
   -------------------------------------------------------------------------- */
export const PAGES_CONNEXION = Object.freeze({
  dossier: 'auth/mon-dossier.html',
  client: 'auth/connexion.html',
  backoffice: 'bo/connexion.html',
});

export async function session() {
  const c = await client();
  const { data } = await c.auth.getSession();
  return data?.session || null;
}

/** Espace d'une session : « dossier » par défaut, comme gmb_prive.espace(). */
export const espaceDe = (s) => s?.user?.app_metadata?.espace || 'dossier';

/** Exige une session dans l'un des espaces donnés, sinon renvoie vers sa connexion. */
export async function exigerEspace(espaces, { raison = 'session' } = {}) {
  const liste = [].concat(espaces);
  const s = await session();
  if (!s || !liste.includes(espaceDe(s))) {
    location.replace(chemin(`${PAGES_CONNEXION[liste[0]]}?raison=${raison}`));
    throw new ErreurGmb('Session absente');
  }
  return s;
}

/* -----------------------------------------------------------------------------
   3. CONTEXTE DE PROPRIÉTÉ (calculé une fois par session)
   -------------------------------------------------------------------------- */
let contexteCourant = null;

export function oublierContexte() {
  contexteCourant = null;
}

async function valeurs(requete, colonne) {
  const { data, error } = await avecDelai(requete);
  if (error) throw error;
  return (data || []).map((ligne) => ligne[colonne]);
}

export async function contexte() {
  const s = await session();
  if (!s) throw new ErreurGmb('Votre session a expiré par sécurité. Reconnectez-vous pour continuer.');
  if (contexteCourant?.uid === s.user.id) return contexteCourant;
  const c = await client();
  const ctx = { uid: s.user.id, email: s.user.email, espace: espaceDe(s), dossiers: [], personnes: [], client: null, clients: [], comptes: [], entreprises: [], fils: [], credits: [], demandes: [], factures: [] };
  if (ctx.espace === 'dossier') {
    const { data, error } = await avecDelai(c.from('dossiers').select('id, personne_id').eq('demandeur_auth', ctx.uid));
    if (error) throw error;
    ctx.dossiers = (data || []).map((d) => d.id);
    ctx.personnes = [...new Set((data || []).map((d) => d.personne_id).filter(Boolean))];
  } else if (ctx.espace === 'client') {
    const { data: moi, error } = await avecDelai(c.from('clients').select('id, identifiant, personne_id, segment, formule_code, statut, theme, preferences').eq('auth_user_id', ctx.uid).maybeSingle());
    if (error) throw error;
    if (!moi) throw new ErreurGmb('Aucun client n’est rattaché à cet accès. Contactez votre conseiller.');
    ctx.client = moi;
    ctx.entreprises = await valeurs(c.from('entreprise_membres').select('entreprise_id').eq('client_id', moi.id).eq('statut', 'actif'), 'entreprise_id');
    const enfants = await valeurs(c.from('comptes_jeunes').select('jeune_client_id').eq('parent_client_id', moi.id), 'jeune_client_id');
    ctx.clients = [moi.id, ...enfants];
    const propres = await valeurs(c.from('comptes').select('id').in('client_id', ctx.clients), 'id');
    const pro = ctx.entreprises.length ? await valeurs(c.from('comptes').select('id').in('entreprise_id', ctx.entreprises), 'id') : [];
    ctx.comptes = [...new Set([...propres, ...pro])];
    ctx.personnes = await valeurs(c.from('clients').select('personne_id').in('id', ctx.clients), 'personne_id');
    ctx.fils = await valeurs(c.from('fils_messagerie').select('id').eq('client_id', moi.id), 'id');
    ctx.credits = await valeurs(c.from('credits').select('id').in('client_id', ctx.clients), 'id');
    ctx.demandes = await valeurs(c.from('demandes').select('id').in('client_id', ctx.clients), 'id');
    ctx.factures = await valeurs(c.from('factures').select('id').eq('client_id', moi.id), 'id');
  } else if (ctx.espace === 'backoffice') {
    const { data, error } = await avecDelai(c.from('collaborateurs').select('id, nom, actif').eq('id', ctx.uid).maybeSingle());
    if (error) throw error;
    if (!data?.actif) throw new ErreurGmb('Votre accès au back-office n’est pas actif.');
    ctx.collaborateur = data;
  }
  contexteCourant = ctx;
  return ctx;
}

/* -----------------------------------------------------------------------------
   4. REGISTRE DES TABLES
   Pour chaque table : lecture publique, ou filtre par espace.
   Un filtre est [colonne, liste du contexte] ; « moi » désigne l'identifiant
   de la session (dossier) ou du client connecté (client).
   -------------------------------------------------------------------------- */
const PUBLIC = 'public';
const REGISTRE = Object.freeze({
  // Lecture publique (vitrine, simulateurs, état des services)
  formules: PUBLIC, formules_historique: PUBLIC, frais: PUBLIC, taux_usure: PUBLIC, categories: PUBLIC, grilles_credit: PUBLIC,
  statut_services: PUBLIC, incidents: PUBLIC, parametres_banque: PUBLIC, parametres_securite: PUBLIC,
  cms_pages: PUBLIC, cms_faq: PUBLIC, cms_textes_legaux: PUBLIC, cms_bandeaux: PUBLIC, cms_redirections: PUBLIC,

  // Mon Dossier et Espace client
  dossiers: { dossier: ['demandeur_auth', 'uid'] },
  dossier_pieces: { dossier: ['dossier_id', 'dossiers'] },
  dossier_messages: { dossier: ['dossier_id', 'dossiers'] },
  dossier_evenements: { dossier: ['dossier_id', 'dossiers'] },
  dossier_rendez_vous: { dossier: ['dossier_id', 'dossiers'], backoffice: true },
  premiers_versements: { dossier: ['dossier_id', 'dossiers'] },
  dossier_entreprises: { dossier: ['dossier_id', 'dossiers'] },
  dossier_jeunes: { dossier: ['dossier_id', 'dossiers'] },
  dossier_credit: { dossier: ['dossier_id', 'dossiers'] },
  personnes: { dossier: ['id', 'personnes'], client: ['id', 'personnes'] },
  consentements: { dossier: ['auth_user_id', 'uid'], client: ['auth_user_id', 'uid'] },

  clients: { client: ['id', 'clients'] },
  comptes: { client: ['id', 'comptes'] },
  operations: { client: ['compte_id', 'comptes'] },
  virements: { client: ['compte_id', 'comptes'] },
  mandats_prelevement: { client: ['compte_id', 'comptes'] },
  interets: { client: ['compte_id', 'comptes'] },
  cartes: { client: ['compte_id', 'comptes'] },
  commandes_cartes: { client: ['client_id', 'moi'] },
  coffres: { client: ['client_id', 'clients'] },
  beneficiaires: { client: ['client_id', 'moi'] },
  epargnes_programmees: { client: ['client_id', 'moi'] },
  credit_remboursements_anticipes: { client: ['credit_id', 'credits'] },
  cotisations: { client: ['client_id', 'moi'] },
  rendez_vous_clients: { client: ['client_id', 'moi'], backoffice: true },
  demandes_cloture: { client: ['client_id', 'moi'], backoffice: true },
  moonpoints: { client: ['client_id', 'moi'] },
  budgets: { client: ['client_id', 'moi'] },
  documents: { client: ['client_id', 'moi'] },
  demandes: { client: ['client_id', 'clients'] },
  demande_evenements: { client: ['demande_id', 'demandes'] },
  credits: { client: ['client_id', 'clients'] },
  credit_echeances: { client: ['credit_id', 'credits'] },
  fils_messagerie: { client: ['client_id', 'moi'] },
  messages: { client: ['fil_id', 'fils'] },
  reclamations: { client: ['client_id', 'moi'] },
  contestations: { client: ['client_id', 'moi'] },
  appareils: { client: ['client_id', 'moi'] },
  connexions: { client: ['client_id', 'moi'] },
  notifications: { client: ['client_id', 'moi'] },
  comptes_jeunes: { client: ['parent_client_id', 'moi'] },

  // Espaces Pro et Business (entreprises dont la personne est membre active)
  entreprises: { client: ['id', 'entreprises'] },
  entreprise_membres: { client: ['entreprise_id', 'entreprises'] },
  factures: { client: ['client_id', 'moi'] },
  facture_lignes: { client: ['facture_id', 'factures'] },
  notes_de_frais: { client: ['entreprise_id', 'entreprises'] },
  regles_approbation: { client: ['entreprise_id', 'entreprises'] },
  demandes_approbation: { client: ['entreprise_id', 'entreprises'] },
  pro_clients: { client: ['client_id', 'moi'] },

  // Back-office uniquement (aucune lecture côté client)
  collaborateurs: { backoffice: true }, collaborateur_roles: { backoffice: true }, roles_bo: { backoffice: true },
  habilitations: { backoffice: true }, modules_bo: { backoffice: true }, dossier_controles: { backoffice: true },
  dossier_notes_internes: { backoffice: true }, dossier_validations: { backoffice: true }, alertes_lcbft: { backoffice: true },
  profils_risque: { backoffice: true }, journal_audit: { backoffice: true }, modeles_notification: { backoffice: true },
  alertes_fraude: { backoffice: true }, cms_versions: { backoffice: true }, cms_medias: { backoffice: true },
});

/** Ajoute à une requête le filtre de propriété de la table, ou refuse l'accès. */
function filtrer(table, requete, ctx) {
  const regle = REGISTRE[table];
  if (!regle) throw new ErreurGmb(`Accès refusé : la table « ${table} » n’est pas déclarée.`);
  if (regle === PUBLIC) return requete;
  if (ctx.espace === 'backoffice') return requete; // tables déclarées, lecture complète
  const filtre = regle[ctx.espace];
  if (!filtre || filtre === true) throw new ErreurGmb('Accès refusé : ces informations ne relèvent pas de votre espace.');
  const [colonne, source] = filtre;
  if (source === 'uid') return requete.eq(colonne, ctx.uid);
  if (source === 'moi') return requete.eq(colonne, ctx.client?.id || AUCUN);
  const liste = ctx[source] || [];
  return requete.in(colonne, liste.length ? liste : [AUCUN]);
}

/* -----------------------------------------------------------------------------
   5. LECTURE
   options : colonnes, egal {colonne: valeur}, dans {colonne: [valeurs]},
             depuis {colonne: valeur} (≥), ordre, croissant, limite, unique
   -------------------------------------------------------------------------- */
export async function lire(table, { colonnes = '*', egal = {}, dans = {}, depuis = {}, ordre = null, croissant = false, limite = null, unique = false } = {}) {
  // Un filtre sans valeur, ou un identifiant mal formé (page ouverte sans son paramètre, adresse tronquée),
  // ne correspond à aucune ligne : la page affiche « introuvable » au lieu d'une erreur technique
  const sansCorrespondance = Object.entries(egal).some(([col, val]) => val === null || val === undefined || val === ''
    || ((col === 'id' || col.endsWith('_id')) && typeof val === 'string' && !UUID.test(val)));
  if (sansCorrespondance) {
    if (!REGISTRE[table]) throw new ErreurGmb(`Accès refusé : la table « ${table} » n’est pas déclarée.`);
    return unique ? null : [];
  }
  const c = await client();
  const ctx = REGISTRE[table] === PUBLIC ? null : await contexte();
  let q = c.from(table).select(colonnes);
  q = ctx ? filtrer(table, q, ctx) : filtrer(table, q, {});
  Object.entries(egal).forEach(([col, val]) => { q = q.eq(col, val); });
  Object.entries(dans).forEach(([col, vals]) => { q = q.in(col, vals.length ? vals : [AUCUN]); });
  Object.entries(depuis).forEach(([col, val]) => { q = q.gte(col, val); });
  if (ordre) q = q.order(ordre, { ascending: croissant });
  if (limite) q = q.limit(limite);
  if (unique) q = q.maybeSingle();
  const { data, error } = await avecDelai(q);
  if (error) throw error;
  return unique ? (data || null) : (data || []);
}

/* -----------------------------------------------------------------------------
   6. ÉCRITURES DIRECTES (limitées)
   Seules ces tables acceptent une écriture directe ; les colonnes de propriété
   sont imposées ici, jamais reprises de l'interface.
   -------------------------------------------------------------------------- */
const INSERTIONS = Object.freeze({
  dossier_messages: (v, ctx) => {
    if (!ctx.dossiers.includes(v.dossier_id)) throw new ErreurGmb('Dossier introuvable.');
    return { dossier_id: v.dossier_id, contenu: v.contenu, auteur: 'client', auteur_id: ctx.uid };
  },
  dossier_rendez_vous: (v, ctx) => {
    if (!ctx.dossiers.includes(v.dossier_id)) throw new ErreurGmb('Dossier introuvable.');
    return { dossier_id: v.dossier_id, debut: v.debut, duree_min: 15, canal: v.canal, statut: 'demande' };
  },
  fils_messagerie: (v, ctx) => ({ client_id: ctx.client.id, sujet: v.sujet, statut: 'ouvert' }),
  messages: (v, ctx) => {
    if (!ctx.fils.includes(v.fil_id)) throw new ErreurGmb('Conversation introuvable.');
    return { fil_id: v.fil_id, contenu: v.contenu, auteur: 'client', auteur_id: ctx.uid };
  },
  budgets: (v, ctx) => ({ client_id: ctx.client.id, mois: v.mois, montant: v.montant, par_categorie: v.par_categorie || {} }),
});

const MODIFICATIONS = Object.freeze({
  budgets: ['montant', 'par_categorie'],
  mandats_prelevement: ['liste', 'statut', 'revoque_le'],
  beneficiaires: ['favori'],
});
const SUPPRESSIONS = Object.freeze(['beneficiaires']);

export async function inserer(table, valeursSaisies, { retour = false } = {}) {
  const preparer = INSERTIONS[table];
  if (!preparer) throw new ErreurGmb(`Écriture refusée sur « ${table} ».`);
  const ctx = await contexte();
  const ligne = preparer(valeursSaisies, ctx);
  const c = await client();
  let q = c.from(table).insert(ligne);
  if (retour) q = q.select('*').single();
  const { data, error } = await avecDelai(q);
  if (error) throw error;
  if (table === 'fils_messagerie' && data?.id) ctx.fils.push(data.id);
  return data;
}

/** Vérifie que la ligne appartient à la personne (lecture filtrée) avant toute modification. */
async function exigerPropriete(table, id) {
  const ligne = await lire(table, { colonnes: 'id', egal: { id }, unique: true });
  if (!ligne) throw new ErreurGmb('Élément introuvable.');
}

export async function modifier(table, id, valeursSaisies) {
  const autorisees = MODIFICATIONS[table];
  if (!autorisees) throw new ErreurGmb(`Modification refusée sur « ${table} ».`);
  const valeursRetenues = Object.fromEntries(Object.entries(valeursSaisies).filter(([k]) => autorisees.includes(k)));
  if (!Object.keys(valeursRetenues).length) throw new ErreurGmb('Aucune modification autorisée.');
  await exigerPropriete(table, id);
  const c = await client();
  const { error } = await avecDelai(c.from(table).update(valeursRetenues).eq('id', id));
  if (error) throw error;
}

export async function supprimer(table, id) {
  if (!SUPPRESSIONS.includes(table)) throw new ErreurGmb(`Suppression refusée sur « ${table} ».`);
  await exigerPropriete(table, id);
  const c = await client();
  const { error } = await avecDelai(c.from(table).delete().eq('id', id));
  if (error) throw error;
}

/* -----------------------------------------------------------------------------
   7. FICHIERS (Supabase Storage)
   Les dépôts se font toujours dans un dossier au nom de la personne.
   -------------------------------------------------------------------------- */
export async function deposerFichier(bucket, fichier) {
  const ctx = await contexte();
  const nom = String(fichier.name || 'document').normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^A-Za-z0-9._-]/g, '_').slice(-80);
  const cheminFichier = `${ctx.uid}/${Date.now()}-${nom}`;
  const c = await client();
  const { error } = await avecDelai(c.storage.from(bucket).upload(cheminFichier, fichier, { contentType: fichier.type || undefined, upsert: false }), 60000);
  if (error) throw error;
  return cheminFichier;
}

export async function lienTemporaire(bucket, cheminFichier, secondes = 60) {
  const ctx = await contexte();
  const dossierAutorise = ctx.espace === 'backoffice' || [ctx.uid, ctx.client?.id].includes(String(cheminFichier).split('/')[0]);
  if (!dossierAutorise) throw new ErreurGmb('Document introuvable.');
  const c = await client();
  const { data, error } = await avecDelai(c.storage.from(bucket).createSignedUrl(cheminFichier, secondes));
  if (error || !data?.signedUrl) throw error || new ErreurGmb('Document indisponible.');
  return data.signedUrl;
}

/* -----------------------------------------------------------------------------
   8. TEMPS RÉEL
   Abonnement limité aux éléments de la personne (dossier ou client).
   -------------------------------------------------------------------------- */
export async function ecouter(table, colonne, valeur, rappel) {
  const ctx = await contexte();
  const autorise = ctx.espace === 'backoffice'
    || (colonne === 'dossier_id' && ctx.dossiers.includes(valeur))
    || (colonne === 'client_id' && ctx.clients.includes(valeur))
    || (colonne === 'compte_id' && ctx.comptes.includes(valeur));
  if (!autorise) throw new ErreurGmb('Abonnement refusé.');
  const c = await client();
  const canal = c.channel(`gmb-${table}-${valeur}`)
    .on('postgres_changes', { event: '*', schema: 'public', table, filter: `${colonne}=eq.${valeur}` }, (charge) => rappel(charge))
    .subscribe();
  return () => c.removeChannel(canal);
}

/* -----------------------------------------------------------------------------
   9. CODES PAR E-MAIL, APPAREILS DE CONFIANCE, VERSION DE LA BASE
   -------------------------------------------------------------------------- */
const CLE_APPAREILS_DOSSIER = 'gmb-appareils-dossier';
const lireLocal = (cle, defaut) => { try { return JSON.parse(localStorage.getItem(cle)) ?? defaut; } catch { return defaut; } };
const ecrireLocal = (cle, valeur) => { try { localStorage.setItem(cle, JSON.stringify(valeur)); } catch { /* stockage indisponible */ } };

/** Cet appareil a-t-il déjà été confirmé par un code reçu par e-mail pour cet accès Mon Dossier ? */
export function appareilDossierConnu(uid) {
  return lireLocal(CLE_APPAREILS_DOSSIER, []).includes(uid);
}
export function memoriserAppareilDossier(uid) {
  const liste = lireLocal(CLE_APPAREILS_DOSSIER, []).filter((x) => x !== uid);
  ecrireLocal(CLE_APPAREILS_DOSSIER, [uid, ...liste].slice(0, 5));
}

/** Message quand un e-mail est déjà parti vers cette adresse il y a moins d'une minute : son code
 *  n'est le bon que s'il n'a pas encore servi. */
export function messageDejaParti(attente) {
  return `Un e-mail vous a été envoyé il y a moins d’une minute. S’il contient un code que vous n’avez pas encore utilisé, saisissez-le. Sinon, vous pourrez en demander un nouveau dans ${attente} seconde${attente > 1 ? 's' : ''}, avec le bouton ci-dessous.`;
}

/** Bouton « Recevoir un nouveau code » : Supabase n'envoie qu'un e-mail par minute à une même
 *  adresse. Le bouton est donc désactivé pendant ce délai, avec un compte à rebours, et un clic
 *  n'annonce un envoi que s'il a réellement eu lieu.
 *  envoyer() envoie le code ; elle peut lever une erreur de limite d'envoi, qui relance le compte à rebours. */
export function brancherRenvoi(bouton, envoyer, { message, delai = 60 } = {}) {
  if (!bouton) return { demarrer() {} };
  const libelle = bouton.textContent.trim();
  let minuteur = null;
  const demarrer = (secondes = delai) => {
    clearInterval(minuteur);
    let reste = Math.max(1, Math.ceil(secondes));
    const afficher = () => { bouton.disabled = true; bouton.textContent = `${libelle} (dans ${reste} s)`; };
    afficher();
    minuteur = setInterval(() => {
      reste -= 1;
      if (reste <= 0) { clearInterval(minuteur); bouton.disabled = false; bouton.textContent = libelle; } else afficher();
    }, 1000);
  };
  bouton.addEventListener('click', async () => {
    bouton.disabled = true;
    try {
      await envoyer();
      demarrer();
      message?.('Un nouveau code vient de vous être envoyé. Seul le dernier code reçu est valable.', 'succes');
    } catch (erreur) {
      if (limiteEmail(erreur)) demarrer(attenteEmail(erreur) || delai); else bouton.disabled = false;
      message?.(messageErreur(erreur), 'erreur');
    }
  });
  return { demarrer };
}

/** Version de la base (null si la fonction gmb_version n'existe pas : base antérieure à la mise à niveau). */
export async function versionBase() {
  try {
    const v = await appeler('gmb_version');
    return Number(v) || null;
  } catch {
    return null;
  }
}

export { CONFIG };
