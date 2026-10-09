/* =============================================================================
   GerMoonBank (GMB) · js/bo/bo.js
   Back-office — version 4 (2026-10-07)
   -----------------------------------------------------------------------------
   Connexion des collaborateurs : e-mail, mot de passe, puis code par e-mail à
   chaque connexion. Navigation construite à partir des droits réels (rôles et
   habilitations : L lecture, E écriture, V validation, A administration).
   Chaque action passe par une fonction gmb_bo_* de la base, qui vérifie
   elle-même le droit du collaborateur : l'interface ne fait que refléter ces droits.
   ========================================================================== */

import { chemin, formaterMontant, formaterDate, formaterIban, echapperHtml, icone, logoSVG } from '../core.js';
import {
  client, session, espaceDe, contexte, lire, appeler, etatFonction, lienTemporaire, messageErreur, ErreurGmb, oublierContexte,
  ARRIVEE_PAR_LIEN, VERSION_BASE, limiteEmail, attenteEmail, brancherRenvoi, messageDejaParti,
} from '../donnees.js';
import { occupe, afficherMessage, erreurChamp, masquerEmail } from '../forms.js';

/* -----------------------------------------------------------------------------
   Modules (codes de la base) et pages
   -------------------------------------------------------------------------- */
const MODULES = [
  { code: 'ADM-01', page: 'index', libelle: 'Tableau de bord', icone: 'graphique' },
  { code: 'ADM-04', page: 'dossiers', libelle: 'Dossiers', icone: 'dossier' },
  { code: 'ADM-04', page: 'kyc', libelle: 'Contrôle des pièces', icone: 'bouclier' },
  { code: 'ADM-08', page: 'credit', libelle: 'Crédits', icone: 'croissance' },
  { code: 'ADM-16', page: 'tresorerie', libelle: 'Trésorerie', icone: 'banque' },
  { code: 'ADM-05', page: 'lcb-ft', libelle: 'LCB-FT', icone: 'alerte' },
  { code: 'ADM-06', page: 'fraude', libelle: 'Fraude et contestations', icone: 'alerte' },
  { code: 'ADM-07', page: 'clients', libelle: 'Clients', icone: 'utilisateur' },
  { code: 'ADM-09', page: 'reclamations', libelle: 'Support et réclamations', icone: 'support' },
  { code: 'ADM-15', page: 'operations', libelle: 'Opérations et pilotage', icone: 'graphique' },
  { code: 'ADM-02', page: 'cms', libelle: 'Contenus', icone: 'dossier' },
  { code: 'ADM-03', page: 'parametres', libelle: 'Paramètres et services', icone: 'plus' },
  { code: 'ADM-12', page: 'securite', libelle: 'Sécurité', icone: 'cadenas' },
  { code: 'ADM-13', page: 'collaborateurs', libelle: 'Collaborateurs', icone: 'famille' },
  { code: 'ADM-14', page: 'audit', libelle: 'Journal d’audit', icone: 'dossier' },
];
/** Pages livrées : la navigation ne propose jamais une page qui n'existe pas encore. */
const PAGES_LIVREES = new Set(['index', 'dossiers', 'kyc', 'credit', 'tresorerie', 'lcb-ft', 'fraude', 'clients', 'reclamations', 'operations', 'cms', 'parametres', 'securite', 'collaborateurs', 'audit']);
const RANG = { L: 1, E: 2, V: 3, A: 4 };
const ETATS = {
  brouillon: 'Non déposé', depose: 'Déposé', en_verification: 'En vérification', incomplet: 'Complément demandé', analyse_conformite: 'En conformité',
  valide: 'Validé', compte_ouvert: 'Compte ouvert', refuse: 'Refusé', abandonne: 'Abandonné', archive: 'Archivé',
  demande_deposee: 'Déposée', analyse: 'En analyse', offre_emise: 'Offre émise', delai_legal: 'Offre acceptée, délai légal', acceptee: 'Offre acceptée',
  fonds_debloques: 'Fonds versés', refusee: 'Refusée', renonciation: 'Rétractation', validee: 'Validée', realisee: 'Réalisée', annulee: 'Annulée',
};
/** Familles d'états, pour les files et les filtres. */
const ETATS_A_TRAITER = ['depose', 'en_verification', 'analyse_conformite', 'demande_deposee', 'analyse'];
const ETATS_TERMINES = ['valide', 'compte_ouvert', 'offre_emise', 'delai_legal', 'acceptee', 'fonds_debloques'];
const ETATS_SANS_SUITE = ['refuse', 'refusee', 'abandonne', 'renonciation', 'archive'];
const couleurEtat = (etat) => (['compte_ouvert', 'valide', 'fonds_debloques', 'acceptee'].includes(etat) ? 'succes' : ETATS_SANS_SUITE.includes(etat) ? 'danger'
  : ETATS_A_TRAITER.includes(etat) ? 'info' : etat === 'incomplet' ? 'alerte' : 'neutre');
const badgeEtat = (etat) => badge(ETATS[etat] || etat, couleurEtat(etat));
const PROFILS = { particulier: 'Particulier', pro: 'Pro', business: 'Business', jeunes: 'Jeunes' };
/** Libellés des déclarations du demandeur (mêmes choix que dans l'ouverture de compte). */
const LIBELLES = {
  civilite: { madame: 'Madame', monsieur: 'Monsieur', non_precise: '' },
  profession: { salarie_prive: 'Salarié du secteur privé', fonctionnaire: 'Fonctionnaire ou agent public', independant: 'Indépendant ou profession libérale', chef_entreprise: 'Chef d’entreprise', etudiant: 'Étudiant', retraite: 'Retraité', sans_activite: 'Sans activité professionnelle' },
  revenus: { moins_1500: 'moins de 1 500 € par mois', '1500_3000': 'de 1 500 € à 3 000 € par mois', '3000_5000': 'de 3 000 € à 5 000 € par mois', plus_5000: 'plus de 5 000 € par mois' },
  patrimoine: { moins_10000: 'moins de 10 000 €', '10000_50000': 'de 10 000 € à 50 000 €', '50000_150000': 'de 50 000 € à 150 000 €', plus_150000: 'plus de 150 000 €' },
  fonds: { revenus_activite: 'salaires et revenus d’activité', epargne: 'épargne personnelle', heritage_donation: 'héritage ou donation', vente_bien: 'vente d’un bien', pensions: 'pensions et allocations' },
  forme: { ei: 'Entreprise individuelle', micro: 'Micro-entreprise', eurl: 'EURL', sasu: 'SASU' },
  ca: { moins_100k: 'moins de 100 000 €', '100k_1m': 'de 100 000 € à 1 million €', '1m_10m': 'de 1 à 10 millions €', plus_10m: 'plus de 10 millions €' },
  effectif: { 0: 'aucun salarié', '1_9': '1 à 9 salariés', '10_49': '10 à 49 salariés', '50_249': '50 à 249 salariés', '250_plus': '250 salariés ou plus' },
  lien: { mere: 'Mère', pere: 'Père', tuteur: 'Tuteur légal' },
  objet: { auto_moto: 'Auto ou moto', travaux: 'Travaux', etudes: 'Études', autre: 'Autre projet' },
};
const lib = (famille, code) => (code === null || code === undefined || code === '' ? '—' : (LIBELLES[famille]?.[code] ?? String(code)));
const PIECES = { piece_identite: 'Pièce d’identité', selfie: 'Selfie', justificatif_domicile: 'Justificatif de domicile', justificatif_revenus: 'Justificatif de revenus', kbis: 'Justificatif d’immatriculation', statuts: 'Statuts', beneficiaires_effectifs: 'Bénéficiaires effectifs', lien_filiation: 'Lien de filiation', autre: 'Autre' };
const STATUTS_PIECE = { attendue: 'Attendue', deposee: 'Déposée', en_controle: 'En contrôle', validee: 'Validée', refusee: 'Refusée', facultative: 'Facultative' };

/* -----------------------------------------------------------------------------
   Outils
   -------------------------------------------------------------------------- */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const e = (t) => echapperHtml(String(t ?? ''));
const date = (d, f = 'court') => (d ? formaterDate(String(d).length === 10 ? `${d}T12:00:00` : d, f) : '—');
const parametre = (nom) => new URLSearchParams(location.search).get(nom);
const page = (nom, extra = '') => chemin(`bo/${nom}.html${extra}`);

function message(texte, type = 'erreur') {
  afficherMessage($('[data-message]'), texte, type);
  if (texte) $('[data-message]')?.scrollIntoView({ block: 'nearest' });
}
async function executer(bouton, action, succes) {
  message('');
  occupe(bouton, true);
  try { await action(); if (succes) message(succes, 'succes'); } catch (x) { message(messageErreur(x)); } finally { occupe(bouton, false); }
}
function tableau(legende, entetes, lignes, vide = 'Aucun élément.') {
  if (!lignes.length) return `<p class="bo-vide">${e(vide)}</p>`;
  return `<div class="gmb-tableau-zone" tabindex="0" role="region" aria-label="${e(legende)}"><table class="gmb-tableau"><caption>${e(legende)}</caption>
    <thead><tr>${entetes.map((h) => `<th scope="col">${e(h)}</th>`).join('')}</tr></thead>
    <tbody>${lignes.map((l) => `<tr>${l.map((c, i) => (i === 0 ? `<th scope="row">${c}</th>` : `<td>${c}</td>`)).join('')}</tr>`).join('')}</tbody></table></div>`;
}
const badge = (texte, type = 'neutre') => `<span class="gmb-badge gmb-badge--${type}">${e(texte)}</span>`;
/** Remplit une zone ; si son chargement échoue, l'explication s'affiche dans la zone et le reste de la page continue. */
async function section(zone, remplir) {
  if (!zone) return;
  try { await remplir(); } catch (x) { console.error('[GMB] section du back-office', x); zone.innerHTML = `<p class="bo-vide" role="alert">${e(messageErreur(x))}</p>`; }
}

/** Ouvre une pièce : l'onglet est ouvert dès le clic (sinon le navigateur le bloque), puis reçoit le lien temporaire. */
async function ouvrirPiece(cheminFichier) {
  const fenetre = window.open('about:blank', '_blank');
  try {
    const lien = await lienTemporaire('gmb-pieces', cheminFichier, 120);
    if (fenetre) { fenetre.opener = null; fenetre.location.href = lien; } else location.assign(lien);
  } catch (x) {
    fenetre?.close();
    throw x;
  }
}

/** Fenêtre de saisie accessible : renvoie les valeurs, ou null si annulée. */
function demander(titre, champs, { valider = 'Valider', danger = false } = {}) {
  return new Promise((resoudre) => {
    const d = document.createElement('dialog');
    d.className = 'gmb-dialogue bo-dialogue';
    d.setAttribute('aria-labelledby', 'bo-dialogue-titre');
    d.innerHTML = `<form method="dialog" class="gmb-pile gmb-pile--moyenne" novalidate>
      <h2 class="gmb-section__titre gmb-section__titre--moyen" id="bo-dialogue-titre">${e(titre)}</h2>
      ${champs.map((c) => `<div class="gmb-champ"><label class="gmb-champ__libelle" for="bo-${c.nom}">${e(c.libelle)}</label>
        ${c.type === 'textarea' ? `<textarea class="gmb-saisie" id="bo-${c.nom}" name="${c.nom}" rows="4">${e(c.valeur || '')}</textarea>`
          : c.options ? `<div class="gmb-liste"><select class="gmb-saisie" id="bo-${c.nom}" name="${c.nom}">${c.options.map(([v, t]) => `<option value="${e(v)}">${e(t)}</option>`).join('')}</select></div>`
          : c.type === 'number' ? `<input class="gmb-saisie" id="bo-${c.nom}" name="${c.nom}" type="text" inputmode="decimal" autocomplete="off" value="${e(c.valeur === undefined || c.valeur === null ? '' : String(c.valeur).replace('.', ','))}">`
          : `<input class="gmb-saisie" id="bo-${c.nom}" name="${c.nom}" type="${c.type || 'text'}" value="${e(c.valeur || '')}">`}
        <p class="gmb-champ__erreur" id="bo-${c.nom}-erreur" hidden></p></div>`).join('')}
      <div class="gmb-rangee"><button type="submit" class="gmb-bouton gmb-bouton--${danger ? 'danger' : 'principal'}" value="ok">${e(valider)}</button>
        <button type="button" class="gmb-bouton gmb-bouton--secondaire" data-annuler>Annuler</button></div></form>`;
    document.body.append(d);
    const form = $('form', d);
    const fermer = (v) => { d.close(); d.remove(); resoudre(v); };
    $('[data-annuler]', d).addEventListener('click', () => fermer(null));
    d.addEventListener('cancel', (x) => { x.preventDefault(); fermer(null); });
    form.addEventListener('submit', (x) => {
      x.preventDefault();
      const valeurs = {};
      let ok = true;
      for (const c of champs) {
        const el = form.elements[c.nom];
        const v = String(el.value || '').trim();
        const nombre = c.type === 'number' && v ? Number(v.replace(/\s/g, '').replace(',', '.')) : null;
        const err = c.requis && !v ? `Indiquez ${c.libelle.toLowerCase()}.` : (c.type === 'number' && v && !Number.isFinite(nombre) ? 'Saisissez un nombre, par exemple 6,4.' : '');
        if (!erreurChamp(el, err)) ok = false;
        valeurs[c.nom] = c.type === 'number' ? nombre : v;
      }
      if (ok) fermer(valeurs);
    });
    d.showModal();
    $('input, textarea, select', d)?.focus();
  });
}

/* -----------------------------------------------------------------------------
   Session, droits et cadre des pages
   -------------------------------------------------------------------------- */
let DROITS = {};
let COLLABORATEUR = null;
const peut = (module, minimum = 'L') => (RANG[DROITS[module]] || 0) >= RANG[minimum];

async function chargerDroits(uid) {
  const roles = (await lire('collaborateur_roles', { colonnes: 'role_code', egal: { collaborateur_id: uid } })).map((r) => r.role_code);
  const habilitations = roles.length ? await lire('habilitations', { colonnes: 'module_code, role_code, droit', dans: { role_code: roles } }) : [];
  const droits = {};
  for (const h of habilitations) if ((RANG[h.droit] || 0) > (RANG[droits[h.module_code]] || 0)) droits[h.module_code] = h.droit;
  return droits;
}

function cadre(nomPage) {
  const nav = $('[data-bo-nav]');
  nav.innerHTML = `<ul class="bo-nav__liste">${MODULES.filter((m) => peut(m.code) && PAGES_LIVREES.has(m.page)).map((m) => `<li><a class="bo-nav__lien" href="${page(m.page)}"${m.page === nomPage ? ' aria-current="page"' : ''}>${icone(m.icone)}<span>${e(m.libelle)}</span></a></li>`).join('')}</ul>`;
  $('[data-bo-nom]').textContent = COLLABORATEUR?.nom || '';
  $('[data-bo-deconnexion]')?.addEventListener('click', deconnecter);
}

async function deconnecter() {
  try { await (await client()).auth.signOut({ scope: 'local' }); } catch { /* déconnexion locale malgré tout */ }
  oublierContexte();
  location.replace(page('connexion'));
}

function surveillerInactivite(minutes = 15) {
  let minuteur;
  const relancer = () => { clearTimeout(minuteur); minuteur = setTimeout(deconnecter, minutes * 60_000); };
  ['pointerdown', 'keydown', 'scroll'].forEach((t) => addEventListener(t, relancer, { passive: true }));
  relancer();
}

/** La base est-elle à la version attendue par le site ? Vérifié une fois par session de navigation. */
async function verifierVersion() {
  try {
    let v = Number(sessionStorage.getItem('gmb-bo-version-base')) || 0;
    if (v < VERSION_BASE) {
      try { v = Number(await appeler('gmb_version')) || 0; } catch { v = 0; }
      sessionStorage.setItem('gmb-bo-version-base', String(v));
    }
    if (v >= VERSION_BASE) return;
    const bandeau = document.createElement('div');
    bandeau.className = 'gmb-encadre gmb-encadre--alerte bo-bandeau';
    bandeau.setAttribute('role', 'alert');
    bandeau.innerHTML = `${icone('alerte')}<p><strong>La base de données n’est pas à jour.</strong> Certaines pages affichent des erreurs tant que la mise à niveau n’est pas exécutée :
      ouvrez le <a href="${chemin('supabase/installation/installation-base-gmb.html')}">module d’installation</a>, rubrique « Base déjà installée », copiez la mise à niveau, collez-la dans Supabase › SQL Editor, puis touchez Run.</p>`;
    $('[data-bo-contenu]')?.before(bandeau);
  } catch { /* le contrôle de version ne bloque jamais une page */ }
}

async function ouvrir(nomPage, module) {
  const marque = document.querySelector('.bo-entete__marque'); if (marque && !marque.querySelector('svg')) marque.innerHTML = `${logoSVG({ titre: 'GerMoonBank' })} <span>Back-office</span>`;

  const s = await session();
  if (!s || espaceDe(s) !== 'backoffice') { location.replace(page('connexion', '?raison=session')); throw new ErreurGmb('Session absente'); }
  const ctx = await contexte();
  COLLABORATEUR = ctx.collaborateur;
  DROITS = await chargerDroits(ctx.uid);
  cadre(nomPage);
  surveillerInactivite();
  verifierVersion();
  if (!peut(module)) { $('[data-bo-contenu]').innerHTML = '<p class="bo-vide">Vous n’avez pas accès à ce module. Demandez l’habilitation à un administrateur.</p>'; throw new ErreurGmb('Accès refusé'); }
  return ctx;
}

/* -----------------------------------------------------------------------------
   Connexion des collaborateurs
   -------------------------------------------------------------------------- */
/** Ce que contenait l'e-mail de connexion : un code à 6 chiffres (attendu) ou seulement un lien.
 *  Le tableau de bord s'en sert pour signaler un modèle d'e-mail mal réglé dans Supabase. */
function noterModeleEmail(forme) {
  try { localStorage.setItem('gmb-bo-modele-email', forme); } catch { /* stockage indisponible : le constat est simplement omis */ }
}

async function pageConnexion() {
  if (parametre('raison') === 'session') message('Votre session a expiré. Reconnectez-vous.', 'info');
  if (ARRIVEE_PAR_LIEN?.erreur) message('Ce lien n’est plus valable : il a expiré ou il a déjà servi. Connectez-vous avec votre adresse e-mail et votre mot de passe.', 'info');
  // Arrivée par un lien de connexion reçu par e-mail : il vaut code
  if (ARRIVEE_PAR_LIEN && !ARRIVEE_PAR_LIEN.erreur) {
    const s = await session();
    if (s && espaceDe(s) === 'backoffice') { noterModeleEmail('lien'); oublierContexte(); location.replace(page('index')); return; }
  }
  const form = $('[data-form="connexion"]');
  const formCode = $('[data-form="code"]');
  const etat = { email: '' };
  async function envoyerCode() {
    const c = await client();
    const { error } = await c.auth.signInWithOtp({ email: etat.email, options: { shouldCreateUser: false, emailRedirectTo: page('connexion') } });
    if (error) throw error;
  }
  const renvoi = brancherRenvoi($('[data-renvoyer-code]'), envoyerCode, { message });
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const email = form.elements.email.value.trim().toLowerCase();
      if (!email || !form.elements.mdp.value) throw new ErreurGmb('Saisissez votre adresse e-mail et votre mot de passe.');
      const c = await client();
      const { data, error } = await c.auth.signInWithPassword({ email, password: form.elements.mdp.value });
      form.elements.mdp.value = '';
      if (error) throw error;
      const collaborateur = espaceDe(data.session) === 'backoffice';
      await c.auth.signOut({ scope: 'local' });
      if (!collaborateur) throw new ErreurGmb('Cet accès n’est pas celui d’un collaborateur GerMoonBank.');
      etat.email = email;
      // Un seul e-mail par minute vers une même adresse : s'il vient de partir, son code reste le bon
      let attente = null;
      try { await envoyerCode(); } catch (erreur) { if (!(limiteEmail(erreur) && attenteEmail(erreur) !== null)) throw erreur; attente = attenteEmail(erreur); }
      form.hidden = true; formCode.hidden = false;
      $('[data-email-code]').textContent = masquerEmail(email);
      renvoi.demarrer(attente || 60);
      if (attente) message(messageDejaParti(attente), 'info');
      formCode.elements.code.focus();
    });
  });
  formCode.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(formCode.querySelector('[type=submit]'), async () => {
      const code = formCode.elements.code.value.replace(/\s/g, '');
      if (!/^\d{6}$/.test(code)) throw new ErreurGmb('Saisissez les 6 chiffres du code reçu par e-mail.');
      const c = await client();
      const { data, error } = await c.auth.verifyOtp({ email: etat.email, token: code, type: 'email' });
      if (error) throw error;
      if (espaceDe(data.session) !== 'backoffice') { await c.auth.signOut({ scope: 'local' }); throw new ErreurGmb('Cet accès n’est pas celui d’un collaborateur GerMoonBank.'); }
      noterModeleEmail('code');
      oublierContexte();
      sessionStorage.removeItem('gmb-bo-version-base');
      location.replace(page('index'));
    });
  });
}

/* -----------------------------------------------------------------------------
   ADM-01 · Tableau de bord
   -------------------------------------------------------------------------- */
const TACHES_ATTENDUES = { 'gmb-interets-livret': 'intérêts du Livret', 'gmb-prelever-cotisations': 'cotisations des formules', 'gmb-executer-programmes': 'virements programmés', 'gmb-prelever-echeances': 'échéances de prêt' };

/** État de l'installation : base, fonction serveur, compte de réception, tâches quotidiennes, règles d'accès. */
async function etatInstallation() {
  const lignes = [];
  const ligne = (ok, titre, detail, action = '') => lignes.push(`<li data-etat="${ok === true ? 'ok' : ok === null ? 'info' : 'alerte'}">${icone(ok === true ? 'check' : ok === null ? 'info' : 'alerte')}<div><strong>${e(titre)}</strong><p>${detail}</p>${action ? `<p>${action}</p>` : ''}</div></li>`);
  const module = `<a href="${chemin('supabase/installation/installation-base-gmb.html')}">module d’installation</a>`;
  // 1. Base de données
  let base = null;
  try { base = await appeler('gmb_bo_etat_installation'); } catch (x) { console.error('[GMB] état de l’installation', x); }
  if (!base) ligne(false, 'Base de données', 'Elle n’a pas reçu la dernière mise à niveau : plusieurs pages du back-office et de l’Espace client affichent des erreurs.', `Ouvrez le ${module}, rubrique « Base déjà installée », et exécutez la mise à niveau.`);
  else if (Number(base.version) < VERSION_BASE) ligne(false, 'Base de données', `Version ${e(base.version)}, alors que le site attend la version ${VERSION_BASE}.`, `Exécutez la mise à niveau du ${module}.`);
  else ligne(true, 'Base de données', `À jour (version ${e(base.version)}, ${e(base.tables)} tables).`);
  // 2. Fonction serveur de l'Espace client
  const f = await etatFonction('gmb-connexion');
  const titreFonction = 'Fonction serveur de l’Espace client';
  const deployer = `${module}, étape « La fonction serveur ».`;
  if (f.etat === 'ok' && f.cles === 'anciennes') ligne(null, titreFonction, `En service (version ${e(f.version)}), avec les anciennes clés du projet, que Supabase retire fin 2026.`,
    'Avant cette date, créez les nouvelles clés : Supabase › Settings › API Keys, onglet « Publishable and secret API keys », bouton « Create new API keys ». La fonction les utilisera d’elle-même.');
  else if (f.etat === 'ok') ligne(true, titreFonction, `En service (version ${e(f.version)}).`);
  else if (f.etat === 'base') ligne(false, titreFonction, e(f.message || 'Elle ne joint pas la base.'), 'Exécutez la mise à niveau de la base, puis rechargez cette page.');
  else if (f.etat === 'configuration') ligne(false, titreFonction, e(f.message || 'Elle ne dispose pas des clés du projet.'),
    `Redéployez-la : ${deployer} Si le message reste, vérifiez que le projet a une clé secrète : Supabase › Settings › API Keys.`);
  else if (f.etat === 'ancienne') ligne(false, titreFonction, 'Une ancienne version est en service sous le nom « gmb-connexion ».', `Remplacez son code et redéployez-la : ${deployer}`);
  else if (f.etat === 'absente' && f.cause === 'jwt') ligne(false, titreFonction, 'Elle est déployée, mais sa vérification du JWT est activée : elle refuse les appels du site.',
    'Supabase › Edge Functions › gmb-connexion › Details : désactivez « Verify JWT with legacy secret », puis enregistrez.');
  else if (f.etat === 'absente') ligne(false, titreFonction, 'Supabase ne la trouve pas : aucun client ne peut activer son accès ni se connecter. Soit elle n’est pas déployée sous le nom exact « gmb-connexion », soit sa vérification du JWT est restée activée.',
    `Déployez-la et désactivez « Verify JWT with legacy secret » : ${deployer}`);
  else ligne(false, titreFonction, 'Supabase ne répond pas depuis cet appareil.', 'Vérifiez votre connexion internet, puis rechargez cette page.');
  // 3. E-mails : constat fait à la dernière connexion sur cet appareil
  let modele = '';
  try { modele = localStorage.getItem('gmb-bo-modele-email') || ''; } catch { /* stockage indisponible */ }
  if (modele === 'code') ligne(true, 'E-mails de code', 'À votre dernière connexion, l’e-mail contenait bien un code à 6 chiffres.');
  else if (modele === 'lien') ligne(false, 'E-mails de code', 'À votre dernière connexion, l’e-mail contenait un lien et non un code : les clients ne peuvent pas activer leur accès à l’Espace client, qui demande ce code.',
    `Remplacez les modèles d’e-mail de Supabase : ${module}, étape « Les e-mails de Supabase », point b.`);
  if (base) {
    // 4. Compte de réception
    const c = base.collecte || {};
    if (c.collecte_iban) ligne(true, 'Compte de réception des virements', `${e(c.collecte_titulaire || '—')} · ${e(formaterIban(c.collecte_iban))}`, peut('ADM-16') ? `<a href="${page('tresorerie')}">Le voir dans Trésorerie</a>` : '');
    else ligne(false, 'Compte de réception des virements', 'Il n’est pas renseigné : aucun demandeur ne peut faire son premier versement ni déposer sa demande.', peut('ADM-16') ? `<a href="${page('tresorerie')}">Le renseigner dans Trésorerie</a>` : 'À renseigner par la trésorerie.');
    // 5. Tâches quotidiennes
    const manquantes = Object.keys(TACHES_ATTENDUES).filter((t) => !(base.taches || []).includes(t));
    if (!manquantes.length) ligne(true, 'Tâches quotidiennes', 'Programmées : intérêts, cotisations, virements programmés, échéances de prêt.');
    else ligne(false, 'Tâches quotidiennes', `Non programmées : ${e(manquantes.map((t) => TACHES_ATTENDUES[t]).join(', '))}.`, `Exécutez le script des tâches quotidiennes du ${module}.`);
    // 6. Règles d'accès
    if (Number(base.regles_acces_actives) >= Number(base.tables)) ligne(true, 'Règles d’accès de la base', 'Actives sur toutes les tables (mode production).');
    else ligne(null, 'Règles d’accès de la base', 'En pause (mode développement) : la base n’est protégée que par le site. À activer avant d’accueillir de vrais clients, avec le script du mode production.');
  }
  const alertes = lignes.filter((l) => l.includes('data-etat="alerte"')).length;
  return { alertes, html: `<details class="gmb-carte bo-bloc bo-service"${alertes ? ' open' : ''}><summary><h2 id="t-installation">État du service</h2>
      ${alertes ? badge(`${alertes} point${alertes > 1 ? 's' : ''} à régler`, 'alerte') : badge('Tout est en service', 'succes')}</summary><ul class="bo-etat">${lignes.join('')}</ul></details>` };
}

async function pageTableau() {
  await ouvrir('index', 'ADM-01');
  const zone = $('[data-bo-contenu]');
  const compter = async (table, options) => (await lire(table, { colonnes: 'id', ...options })).length;
  const cartes = [];
  const ajouter = async (titre, lien, calcul) => { try { cartes.push([titre, await calcul(), lien]); } catch (x) { console.error('[GMB] tableau de bord', titre, x); cartes.push([titre, '—', lien]); } };
  if (peut('ADM-04')) {
    await ajouter('Dossiers à traiter', page('dossiers'), () => compter('dossiers', { dans: { etat: ETATS_A_TRAITER } }));
    await ajouter('Pièces à contrôler', page('kyc'), () => compter('dossier_pieces', { dans: { statut: ['deposee', 'en_controle'] } }));
    await ajouter('Demandes non déposées', page('dossiers', '?etat=brouillon'), () => compter('dossiers', { egal: { etat: 'brouillon' } }));
    await ajouter('En attente du demandeur', page('dossiers', '?etat=incomplet'), () => compter('dossiers', { egal: { etat: 'incomplet' } }));
  }
  if (peut('ADM-16')) {
    await ajouter('Versements attendus', page('tresorerie'), () => compter('premiers_versements', { egal: { statut: 'attendu' } }));
    await ajouter('Virements à exécuter', page('tresorerie'), () => compter('virements', { egal: { statut: 'a_executer' } }));
  }
  if (peut('ADM-08')) await ajouter('Demandes de prêt à étudier', page('credit'), () => compter('demandes', { egal: { type: 'pret_personnel' }, dans: { etat: ['demande_deposee', 'analyse', 'incomplet'] } }));
  if (peut('ADM-05')) await ajouter('Alertes LCB-FT à traiter', page('lcb-ft'), () => compter('alertes_lcbft', { dans: { statut: ['ouverte', 'en_analyse'] } }));
  if (peut('ADM-06')) {
    await ajouter('Alertes de fraude', page('fraude'), () => compter('alertes_fraude', { dans: { statut: ['ouverte', 'en_analyse'] } }));
    await ajouter('Contestations ouvertes', page('fraude'), () => compter('contestations', { egal: { statut: 'ouverte' } }));
  }
  if (peut('ADM-09') && PAGES_LIVREES.has('reclamations')) await ajouter('Réclamations ouvertes', page('reclamations'), () => compter('reclamations', { dans: { statut: ['recue', 'en_cours'] } }));
  zone.innerHTML = `<h1 class="gmb-section__titre" id="titre-page">Tableau de bord</h1>
    <div data-etat-installation><p class="bo-vide">Contrôle du service…</p></div>
    <div class="bo-compteurs">${cartes.map(([t, n, l]) => `<a class="gmb-carte bo-compteur" href="${l}"><span class="bo-compteur__nombre">${e(n)}</span><span class="bo-compteur__libelle">${e(t)}</span></a>`).join('')}</div>`;
  const zoneEtat = $('[data-etat-installation]');
  await section(zoneEtat, async () => {
    const etat = await etatInstallation();
    zoneEtat.innerHTML = etat.html;
    // Tout va bien : l'état du service passe sous les compteurs, replié
    if (!etat.alertes) zone.append(zoneEtat);
  });
}

/* -----------------------------------------------------------------------------
   ADM-04 · Dossiers (liste)
   -------------------------------------------------------------------------- */
async function personnesDe(dossiers) {
  const ids = [...new Set(dossiers.map((d) => d.personne_id).filter(Boolean))];
  const liste = ids.length ? await lire('personnes', { colonnes: 'id, prenoms, nom_naissance, email', dans: { id: ids } }) : [];
  return Object.fromEntries(liste.map((p) => [p.id, p]));
}

/** Ce qu'il reste à faire sur un dossier d'ouverture, dans l'ordre : c'est le parcours de validation. */
function parcoursDossier(d, pieces, versement) {
  const aValider = pieces.filter((x) => ['deposee', 'en_controle'].includes(x.statut)).length;
  const manquantes = pieces.filter((x) => ['attendue', 'refusee'].includes(x.statut)).length;
  const piecesOk = pieces.length > 0 && aValider === 0 && manquantes === 0;
  const versementOk = ['recu', 'credite'].includes(versement?.statut);
  const depose = d.etat !== 'brouillon';
  const prisEnCharge = depose && d.etat !== 'depose';
  const ouvert = ['compte_ouvert', 'archive'].includes(d.etat) && d.type === 'ouverture';
  const pret = ['en_verification', 'analyse_conformite'].includes(d.etat) && piecesOk && versementOk;
  let action = 'Aucune action attendue';
  if (d.type !== 'ouverture') action = ETATS_A_TRAITER.includes(d.etat) ? 'À étudier dans Crédits' : (ETATS[d.etat] || d.etat);
  else if (ETATS_SANS_SUITE.includes(d.etat)) action = 'Dossier clos';
  else if (ouvert) action = 'Compte ouvert';
  else if (!depose) action = 'Le demandeur n’a pas encore déposé sa demande';
  else if (d.etat === 'incomplet') action = 'En attente du demandeur (complément demandé)';
  else if (!prisEnCharge) action = 'À prendre en charge';
  else if (aValider) action = `${aValider} pièce${aValider > 1 ? 's' : ''} à contrôler`;
  else if (manquantes) action = `${manquantes} pièce${manquantes > 1 ? 's' : ''} à redemander ou attendue${manquantes > 1 ? 's' : ''}`;
  else if (!versementOk) action = versement ? 'Premier versement à constater' : 'Aucun premier versement déclaré';
  else if (pret) action = 'Prêt à valider';
  return { aValider, manquantes, piecesOk, versementOk, depose, prisEnCharge, ouvert, pret, action };
}

async function pageDossiers() {
  await ouvrir('dossiers', 'ADM-04');
  const form = $('[data-form="filtres"]');
  const zone = $('[data-liste]');
  const info = $('[data-info-dossiers]');
  const demande = parametre('etat');
  if (demande && [...form.elements.etat.options].some((o) => o.value === demande)) form.elements.etat.value = demande;
  const rendre = async () => {
    const egal = {};
    if (form.elements.type.value) egal.type = form.elements.type.value;
    if (form.elements.segment.value) egal.segment = form.elements.segment.value;
    const options = { colonnes: 'id, reference, type, segment, etat, personne_id, depose_le, sla_echeance, analyste_id, derniere_activite, created_at', egal, ordre: 'derniere_activite', croissant: false, limite: 300 };
    const choix = form.elements.etat.value;
    if (choix) options.dans = { etat: choix.split(',') };
    const dossiers = await lire('dossiers', options);
    const ids = dossiers.map((d) => d.id);
    const [personnes, pieces, versements] = await Promise.all([personnesDe(dossiers),
      ids.length ? lire('dossier_pieces', { colonnes: 'dossier_id, statut', dans: { dossier_id: ids } }) : [],
      ids.length ? lire('premiers_versements', { colonnes: 'dossier_id, statut', dans: { dossier_id: ids } }) : []]);
    // Les dossiers déposés d'abord, du plus ancien au plus récent ; les demandes non déposées ensuite
    dossiers.sort((a, b) => (a.depose_le && b.depose_le ? String(a.depose_le).localeCompare(String(b.depose_le)) : a.depose_le ? -1 : b.depose_le ? 1 : String(b.derniere_activite).localeCompare(String(a.derniere_activite))));
    zone.innerHTML = tableau('Dossiers', ['Référence', 'Demandeur', 'Profil', 'État', 'Prochaine action', 'Déposé le', 'Échéance'], dossiers.map((d) => {
      const p = parcoursDossier(d, pieces.filter((x) => x.dossier_id === d.id), versements.find((x) => x.dossier_id === d.id));
      const enRetard = d.sla_echeance && new Date(d.sla_echeance) < new Date() && ETATS_A_TRAITER.includes(d.etat);
      return [`<a href="${page('dossier', `?id=${d.id}`)}">${e(d.reference)}</a>`,
        e(`${personnes[d.personne_id]?.prenoms || ''} ${personnes[d.personne_id]?.nom_naissance || ''}`.trim() || personnes[d.personne_id]?.email || '—'),
        e(d.type === 'credit' ? 'Prêt personnel' : (PROFILS[d.segment] || d.segment)), badgeEtat(d.etat), e(p.action),
        d.depose_le ? date(d.depose_le) : `<small>créé le ${date(d.created_at)}</small>`, d.sla_echeance ? `${date(d.sla_echeance)}${enRetard ? ` ${badge('Dépassée', 'danger')}` : ''}` : '—'];
    }), 'Aucun dossier ne correspond à ces filtres.');
    // Rien à traiter : les demandes en cours de saisie existent peut-être, sans être encore déposées
    if (!info) return; // page d'une version précédente, sans cet encadré
    info.hidden = true;
    if (!dossiers.length && choix === form.elements.etat.options[0].value) {
      const brouillons = (await lire('dossiers', { colonnes: 'id', egal: { etat: 'brouillon' } })).length;
      if (brouillons) {
        info.hidden = false;
        info.innerHTML = `${icone('info')}<p>Aucun dossier n’attend de traitement. ${brouillons} demande${brouillons > 1 ? 's sont' : ' est'} en cours de saisie par ${brouillons > 1 ? 'leurs demandeurs' : 'son demandeur'}, sans être encore déposée${brouillons > 1 ? 's' : ''} :
          un dossier n’arrive ici qu’après le dépôt (dernière étape de l’ouverture de compte). <a href="${page('dossiers', '?etat=brouillon')}">Voir les demandes non déposées</a></p>`;
      }
    }
  };
  form.addEventListener('change', () => rendre().catch((x) => message(messageErreur(x))));
  form.addEventListener('submit', (x) => x.preventDefault());
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-04 / ADM-08 · Fiche dossier
   -------------------------------------------------------------------------- */
async function pageDossier() {
  await ouvrir('dossiers', 'ADM-04');
  const id = parametre('id');
  const zone = $('[data-bo-contenu]');
  const charger = async () => {
    const d = await lire('dossiers', { egal: { id }, unique: true });
    if (!d) { zone.innerHTML = '<p class="bo-vide">Dossier introuvable.</p>'; return; }
    const module = d.type === 'credit' ? 'ADM-08' : 'ADM-04';
    const decide = peut(module, 'E');
    const tresorerie = peut('ADM-16', 'E');
    const [p, pieces, versement, entreprise, enfant, credit, messages, evenements, client] = await Promise.all([
      d.personne_id ? lire('personnes', { egal: { id: d.personne_id }, unique: true }) : null,
      lire('dossier_pieces', { egal: { dossier_id: id }, ordre: 'type', croissant: true }),
      lire('premiers_versements', { egal: { dossier_id: id }, unique: true }),
      lire('dossier_entreprises', { egal: { dossier_id: id }, unique: true }),
      lire('dossier_jeunes', { egal: { dossier_id: id }, unique: true }),
      lire('dossier_credit', { egal: { dossier_id: id }, unique: true }),
      lire('dossier_messages', { egal: { dossier_id: id }, ordre: 'created_at', croissant: true }),
      lire('dossier_evenements', { egal: { dossier_id: id }, ordre: 'created_at', croissant: true }),
      lire('clients', { colonnes: 'id, identifiant, statut, auth_user_id', egal: { dossier_origine_id: id }, unique: true }),
    ]);
    const ligne = (t, v) => `<div><dt>${e(t)}</dt><dd>${v}</dd></div>`;
    const etape = (fait, titre, detail, action = '') => `<li data-etat="${fait === true ? 'ok' : fait === null ? 'attente' : 'a-faire'}">${icone(fait === true ? 'check' : fait === null ? 'info' : 'alerte')}<div><strong>${e(titre)}</strong><p>${detail}</p>${action}</div></li>`;
    const pc = parcoursDossier(d, pieces, versement);
    const enCours = !ETATS_SANS_SUITE.includes(d.etat) && !pc.ouvert;
    // Parcours de validation d'une ouverture de compte : ce qui est fait, ce qui reste à faire, par qui
    const parcours = d.type !== 'ouverture' ? '' : `<section class="gmb-carte bo-bloc" aria-labelledby="t-parcours"><h2 id="t-parcours">Parcours de validation</h2>
      <p>${e(pc.action)}.</p>
      <ol class="bo-etat bo-etat--parcours">
        ${etape(pc.depose ? true : null, '1. Demande déposée par le demandeur', pc.depose ? `Déposée le ${date(d.depose_le, 'long')}.` : 'Le demandeur n’a pas terminé sa demande : elle n’est pas encore déposée. Vous pouvez contrôler ses pièces et lui écrire, mais la décision n’est possible qu’après le dépôt.')}
        ${etape(pc.prisEnCharge ? true : pc.depose && enCours ? false : null, '2. Prise en charge par un analyste', pc.prisEnCharge ? 'Le dossier est en vérification.' : 'Le dossier attend un analyste.',
          decide && d.etat === 'depose' ? '<p><button type="button" class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" data-action="prendre">Prendre en charge</button></p>' : '')}
        ${etape(pc.piecesOk ? true : (pc.aValider && enCours) ? false : null, '3. Pièces contrôlées', pc.piecesOk ? 'Toutes les pièces sont validées.' : `${pc.aValider} à contrôler, ${pc.manquantes} attendue${pc.manquantes > 1 ? 's' : ''} ou à remplacer, sur ${pieces.length}.`,
          !pc.piecesOk && pc.aValider && decide ? '<p><a href="#t-pieces">Contrôler les pièces ci-dessous</a></p>' : '')}
        ${etape(pc.versementOk ? true : (versement && pc.depose && enCours) ? false : null, '4. Premier versement reçu', pc.versementOk ? `${formaterMontant(versement.montant_recu ?? versement.montant)} reçu${versement.recu_le ? ` le ${date(versement.recu_le)}` : ''}.`
          : versement ? `${formaterMontant(versement.montant)} annoncé par « ${e(versement.nom_titulaire || '—')} », référence ${e(d.reference)} : à rechercher sur le relevé du compte de réception.` : 'Le demandeur n’a pas encore déclaré son versement.',
          versement?.statut === 'attendu' && pc.depose && enCours ? (tresorerie ? '<p><button type="button" class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" data-action="versement">Enregistrer la réception</button></p>' : '<p>À enregistrer par la trésorerie.</p>') : '')}
        ${etape(pc.ouvert ? true : pc.pret ? false : null, '5. Décision et ouverture du compte', pc.ouvert ? `Compte ouvert le ${date(d.ouvert_le, 'long')}.` : pc.pret ? 'Tout est réuni : vous pouvez valider. Le compte est ouvert aussitôt et l’identifiant du client créé.' : 'Possible quand les étapes 1 à 4 sont faites.',
          pc.pret && decide ? '<p><button type="button" class="gmb-bouton gmb-bouton--principal" data-decision="valider">Valider et ouvrir le compte</button></p>' : '')}
        ${etape(client?.auth_user_id ? true : null, '6. Accès du client à son Espace client', client ? `Identifiant ${e(String(client.identifiant).replace(/(\d{4})(\d{4})/, '$1 $2'))} : le client l’affiche dans son Espace Mon Dossier, rubrique Identifiant, puis active son accès avec un code reçu par e-mail. ${client.auth_user_id ? 'Accès activé.' : 'Accès pas encore activé.'}`
          : 'L’identifiant est créé à l’ouverture du compte. Le client le trouve dans son Espace Mon Dossier.', client && peut('ADM-07') ? `<p><a href="${page('clients', `?id=${client.id}`)}">Voir la fiche du client</a></p>` : '')}
      </ol></section>`;
    const decisions = decide && d.type === 'ouverture' && ['en_verification', 'analyse_conformite', 'incomplet'].includes(d.etat);
    zone.innerHTML = `
      <header class="bo-fiche__entete"><div><h1 class="gmb-section__titre" id="titre-page">${e(d.reference)}</h1><p>${badgeEtat(d.etat)} ${e(d.type === 'credit' ? 'Prêt personnel' : `Ouverture de compte · ${PROFILS[d.segment] || d.segment}`)}${d.formule_code ? ` · formule ${e(d.formule_code.replace(/_/g, ' ').replace(/^./, (x) => x.toUpperCase()))}` : ''}</p></div>
        <p><a href="${page('dossiers')}">Retour aux dossiers</a></p></header>
      ${parcours}
      ${d.type === 'credit' && decide && d.etat === 'demande_deposee' ? '<p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-action="prendre">Prendre en charge</button></p>' : ''}
      <section class="gmb-carte bo-bloc" aria-labelledby="t-personne"><h2 id="t-personne">Demandeur</h2><dl class="bo-dl">
        ${ligne('Nom', e(`${LIBELLES.civilite[p?.civilite] || ''} ${p?.prenoms || ''} ${p?.nom_naissance || ''}${p?.nom_usage ? ` (nom d’usage : ${p.nom_usage})` : ''}`.trim() || '—'))}
        ${ligne('Naissance', e(`${date(p?.date_naissance, 'long')} à ${p?.lieu_naissance || '—'} (${p?.pays_naissance || '—'}), nationalité ${p?.nationalite || '—'}`))}
        ${ligne('Adresse', e([p?.adresse_ligne1, p?.adresse_ligne2, p?.code_postal, p?.ville, p?.pays].filter(Boolean).join(' ') || '—'))}
        ${ligne('Contact', e(`${p?.email || '—'} · ${p?.telephone || '—'}`))}
        ${ligne('Fiscalité', e(`résidence ${p?.residence_fiscale || '—'}, NIF ${p?.nif || '—'}, personne américaine : ${p?.personne_us ? 'oui' : 'non'}, PPE : ${p?.ppe_declaree ? 'oui' : 'non'}`))}
        ${ligne('Situation', e(lib('profession', p?.profession)))}
        ${ligne('Revenus', e(lib('revenus', p?.revenus_tranche)))}
        ${ligne('Patrimoine', e(lib('patrimoine', p?.patrimoine_tranche)))}
        ${ligne('Origine des fonds', e(lib('fonds', p?.origine_fonds)))}</dl></section>
      ${entreprise ? `<section class="gmb-carte bo-bloc" aria-labelledby="t-entreprise"><h2 id="t-entreprise">Entreprise</h2><dl class="bo-dl">
        ${ligne('Dénomination', e(`${entreprise.raison_sociale} · ${lib('forme', entreprise.forme_juridique)} · SIREN ${entreprise.siren}`))}
        ${ligne('Siège', e(`${entreprise.adresse_siege}, ${entreprise.code_postal} ${entreprise.ville}`))}
        ${ligne('Activité', e([entreprise.code_naf, entreprise.activite].filter(Boolean).join(' ') || '—'))}
        ${ligne('Chiffre d’affaires et effectif', e(`${lib('ca', entreprise.chiffre_affaires)} · ${lib('effectif', entreprise.effectif)}`))}
        ${ligne('Bénéficiaires effectifs', e((entreprise.beneficiaires || []).map((b) => `${b.prenoms} ${b.nom} (${b.pourcentage} %)`).join(', ') || '—'))}</dl></section>` : ''}
      ${enfant ? `<section class="gmb-carte bo-bloc" aria-labelledby="t-enfant"><h2 id="t-enfant">Enfant</h2><dl class="bo-dl">
        ${ligne('Identité', e(`${enfant.prenoms} ${enfant.nom}, né(e) le ${date(enfant.date_naissance, 'long')} à ${enfant.lieu_naissance}`))}
        ${ligne('Lien avec le demandeur', e(`${lib('lien', enfant.lien)} · autorité parentale attestée`))}</dl></section>` : ''}
      ${credit ? `<section class="gmb-carte bo-bloc" aria-labelledby="t-credit"><h2 id="t-credit">Projet de prêt</h2><dl class="bo-dl">
        ${ligne('Demande', e(`${formaterMontant(credit.montant)} sur ${credit.duree_mois} mois · ${lib('objet', credit.objet)}`))}
        ${ligne('Revenus et charges', e(`${formaterMontant(credit.revenus_mensuels || 0)} / ${formaterMontant(credit.charges_mensuelles || 0)} par mois`))}
        ${ligne('FICP', e(credit.consentement_ficp ? `consentement donné${credit.ficp_consulte_le ? `, consulté le ${date(credit.ficp_consulte_le)}` : ''}` : 'non'))}</dl>
        ${d.type === 'ouverture' ? `<p class="bo-vide">La demande de prêt est créée à l’ouverture du compte : elle se traite ensuite dans <a href="${page('credit')}">Crédits</a>.</p>` : ''}</section>` : ''}
      <section class="gmb-carte bo-bloc" aria-labelledby="t-pieces"><h2 id="t-pieces">Pièces</h2>
        ${tableau('Pièces du dossier', ['Pièce', 'Statut', 'Date du document', 'Actions'], pieces.map((x) => [e(PIECES[x.type] || x.type),
          badge(STATUTS_PIECE[x.statut] || x.statut, x.statut === 'validee' ? 'succes' : x.statut === 'refusee' ? 'danger' : ['deposee', 'en_controle'].includes(x.statut) ? 'info' : 'neutre') + (x.motif_refus_client ? `<br><small>${e(x.motif_refus_client)}</small>` : ''), date(x.date_document),
          `${x.fichier_chemin ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-voir="${e(x.fichier_chemin)}">Voir</button>` : ''}
           ${decide && ['deposee', 'en_controle'].includes(x.statut) ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-piece="${x.id}" data-statut="validee">Valider</button>
           <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-piece="${x.id}" data-statut="refusee">Refuser</button>` : ''}`]), 'Aucune pièce.')}</section>
      ${d.type === 'ouverture' ? `<section class="gmb-carte bo-bloc" aria-labelledby="t-versement"><h2 id="t-versement">Premier versement</h2>
        ${versement ? `<p>${badge({ attendu: 'Attendu', recu: 'Reçu', credite: 'Crédité sur le compte', en_revue: 'En vérification', rembourse: 'Remboursé' }[versement.statut] || versement.statut, ['recu', 'credite'].includes(versement.statut) ? 'succes' : 'neutre')} ${formaterMontant(versement.montant)} déclaré par « ${e(versement.nom_titulaire || '—')} » le ${date(versement.declare_le)}${versement.montant_recu ? ` · ${formaterMontant(versement.montant_recu)} reçu le ${date(versement.recu_le)}` : ''}</p>
          ${tresorerie && versement.statut === 'attendu' && pc.depose ? '<p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-action="versement">Enregistrer la réception</button></p>' : ''}` : '<p>Aucun versement déclaré.</p>'}</section>` : ''}
      ${decisions ? `<section class="gmb-carte bo-bloc" aria-labelledby="t-decision"><h2 id="t-decision">Décision</h2>
        ${d.etat === 'incomplet' ? '<p>Un complément est demandé au demandeur : le dossier revient en vérification dès qu’il a déposé ses pièces.</p>' : ''}
        <div class="gmb-rangee">
        ${d.etat !== 'incomplet' ? `<button type="button" class="gmb-bouton gmb-bouton--principal" data-decision="valider"${pc.pret ? '' : ' disabled aria-describedby="t-decision-aide"'}>Valider et ouvrir le compte</button>
        <button type="button" class="gmb-bouton gmb-bouton--secondaire" data-decision="complement">Demander un complément</button>
        ${d.etat === 'en_verification' ? '<button type="button" class="gmb-bouton gmb-bouton--secondaire" data-decision="conformite">Transmettre à la conformité</button>' : ''}` : ''}
        <button type="button" class="gmb-bouton gmb-bouton--danger" data-decision="refuser">Refuser</button></div>
        ${d.etat !== 'incomplet' && !pc.pret ? `<p class="bo-vide" id="t-decision-aide">La validation devient possible quand toutes les pièces sont validées et le premier versement enregistré comme reçu.</p>` : ''}</section>` : ''}
      <section class="gmb-carte bo-bloc" aria-labelledby="t-messages"><h2 id="t-messages">Messages avec le demandeur</h2>
        <ol class="bo-fil">${messages.map((m) => `<li class="bo-fil__message bo-fil__message--${e(m.auteur)}"><p>${e(m.contenu)}</p><small>${e(m.auteur === 'client' ? 'Demandeur' : m.auteur === 'conseiller' ? 'Conseiller' : 'GerMoonBank')} · ${date(m.created_at, 'long')}</small></li>`).join('') || '<li>Aucun message.</li>'}</ol>
        ${decide ? '<p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-action="message">Écrire au demandeur</button></p>' : ''}</section>
      <section class="gmb-carte bo-bloc" aria-labelledby="t-historique"><h2 id="t-historique">Historique</h2>
        <ol class="bo-fil">${evenements.map((x) => `<li><strong>${e(ETATS[x.etat_apres] || x.etat_apres || '')}</strong> — ${e(x.libelle_client || '')} <small>${e(x.acteur)} · ${date(x.created_at, 'long')}</small></li>`).join('') || '<li>Aucun événement.</li>'}</ol></section>`;
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.voir) { executer(b, () => ouvrirPiece(b.dataset.voir)); return; }
    if (b.dataset.piece) {
      executer(b, async () => {
        let motif = null;
        if (b.dataset.statut === 'refusee') {
          const r = await demander('Refuser la pièce', [{ nom: 'motif', libelle: 'Motif expliqué au demandeur', type: 'textarea', requis: true }], { valider: 'Refuser la pièce', danger: true });
          if (!r) return;
          motif = r.motif;
        }
        await appeler('gmb_bo_piece_statuer', { p_piece: b.dataset.piece, p_statut: b.dataset.statut, p_motif_client: motif });
        await charger();
        message(b.dataset.statut === 'validee' ? 'Pièce validée.' : 'Pièce refusée : le demandeur en est informé.', 'succes');
      });
      return;
    }
    if (b.dataset.action === 'prendre') { executer(b, async () => { await appeler('gmb_bo_dossier_prendre', { p_dossier: id }); await charger(); }, 'Dossier pris en charge : il est en vérification.'); return; }
    if (b.dataset.action === 'versement') {
      executer(b, async () => {
        const r = await demander('Réception du premier versement', [{ nom: 'montant', libelle: 'Montant reçu (€)', type: 'number', requis: true }, { nom: 'titulaire', libelle: 'Titulaire du compte émetteur, tel qu’il figure sur le relevé', requis: true }]);
        if (!r) return;
        await appeler('gmb_bo_versement_recu', { p_dossier: id, p_montant_recu: r.montant, p_titulaire_constate: r.titulaire });
        await charger();
        message('Réception enregistrée : le demandeur en est informé.', 'succes');
      });
      return;
    }
    if (b.dataset.action === 'message') {
      executer(b, async () => {
        const r = await demander('Écrire au demandeur', [{ nom: 'contenu', libelle: 'Message', type: 'textarea', requis: true }], { valider: 'Envoyer' });
        if (!r) return;
        await appeler('gmb_bo_dossier_message', { p_dossier: id, p_contenu: r.contenu });
        await charger();
        message('Message envoyé.', 'succes');
      });
      return;
    }
    if (b.dataset.decision) {
      executer(b, async () => {
        const decision = b.dataset.decision;
        const champs = decision === 'valider' ? [{ nom: 'note', libelle: 'Note interne (facultative)', type: 'textarea' }]
          : decision === 'refuser' ? [{ nom: 'motif', libelle: 'Motif', options: [['identite', 'Identité non vérifiée'], ['documents', 'Documents non conformes'], ['risque', 'Profil de risque'], ['capacite', 'Capacité de remboursement insuffisante'], ['autre', 'Autre motif']] }, { nom: 'message', libelle: 'Message au demandeur', type: 'textarea', requis: true }, { nom: 'note', libelle: 'Note interne', type: 'textarea' }]
          : [{ nom: 'message', libelle: decision === 'complement' ? 'Ce qu’il faut fournir ou corriger (message au demandeur)' : 'Motif de la transmission (note interne)', type: 'textarea', requis: true }];
        const titres = { valider: 'Valider le dossier et ouvrir le compte', refuser: 'Refuser le dossier', complement: 'Demander un complément', conformite: 'Transmettre à la conformité' };
        const r = await demander(titres[decision], champs, { valider: titres[decision], danger: decision === 'refuser' });
        if (!r) return;
        const resultat = await appeler('gmb_bo_dossier_decision', { p_dossier: id, p_decision: decision, p_motif_code: r.motif || null, p_message: decision === 'conformite' ? null : (r.message || null), p_note: decision === 'conformite' ? r.message : (r.note || null) });
        await charger();
        if (resultat?.attente === 'second_validateur') message('Votre validation est enregistrée. Ce dossier présente un risque supérieur au niveau faible : un second collaborateur doit le valider à son tour pour ouvrir le compte.', 'info');
        else if (resultat?.etat === 'compte_ouvert') message('Compte ouvert. L’identifiant du client est créé : il l’affiche dans son Espace Mon Dossier, rubrique Identifiant, puis active son accès à l’Espace client.', 'succes');
        else message(`Décision enregistrée : ${ETATS[resultat?.etat] || resultat?.etat || decision}.`, 'succes');
      });
    }
  });
  await charger();
}

/* -----------------------------------------------------------------------------
   ADM-04 · Contrôle des pièces (file d'attente)
   -------------------------------------------------------------------------- */
async function pageKyc() {
  await ouvrir('kyc', 'ADM-04');
  const zone = $('[data-liste]');
  const rendre = async () => {
    const pieces = await lire('dossier_pieces', { colonnes: 'id, dossier_id, type, statut, fichier_chemin, depose_le', dans: { statut: ['deposee', 'en_controle'] }, ordre: 'depose_le', croissant: true, limite: 300 });
    const dossiers = pieces.length ? await lire('dossiers', { colonnes: 'id, reference', dans: { id: [...new Set(pieces.map((x) => x.dossier_id))] } }) : [];
    const ref = Object.fromEntries(dossiers.map((d) => [d.id, d.reference]));
    zone.innerHTML = tableau('Pièces à contrôler', ['Pièce', 'Dossier', 'Déposée le', 'Actions'], pieces.map((x) => [e(PIECES[x.type] || x.type),
      `<a href="${page('dossier', `?id=${x.dossier_id}`)}">${e(ref[x.dossier_id] || '—')}</a>`, date(x.depose_le, 'long'),
      `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-voir="${e(x.fichier_chemin || '')}">Voir</button>
       ${peut('ADM-04', 'E') ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-piece="${x.id}" data-statut="validee">Valider</button>
       <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-piece="${x.id}" data-statut="refusee">Refuser</button>` : ''}`]), 'Aucune pièce à contrôler.');
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.voir) { executer(b, () => ouvrirPiece(b.dataset.voir)); return; }
    if (b.dataset.piece) {
      executer(b, async () => {
        let motif = null;
        if (b.dataset.statut === 'refusee') {
          const r = await demander('Refuser la pièce', [{ nom: 'motif', libelle: 'Motif expliqué au demandeur', type: 'textarea', requis: true }], { valider: 'Refuser la pièce', danger: true });
          if (!r) return;
          motif = r.motif;
        }
        await appeler('gmb_bo_piece_statuer', { p_piece: b.dataset.piece, p_statut: b.dataset.statut, p_motif_client: motif });
        await rendre();
      }, b.dataset.statut === 'validee' ? 'Pièce validée.' : 'Pièce refusée.');
    }
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-08 · Crédits : offre et déblocage
   -------------------------------------------------------------------------- */
async function pageCredit() {
  await ouvrir('credit', 'ADM-08');
  const zone = $('[data-liste]');
  const rendre = async () => {
    const dossiers = await lire('dossiers', { colonnes: 'id, reference, etat, personne_id, depose_le', egal: { type: 'credit' }, ordre: 'depose_le', croissant: false, limite: 200 });
    const projets = dossiers.length ? await lire('dossier_credit', { dans: { dossier_id: dossiers.map((d) => d.id) } }) : [];
    const projet = Object.fromEntries(projets.map((c) => [c.dossier_id, c]));
    const personnes = await personnesDe(dossiers);
    const aujourdhui = new Date().toISOString().slice(0, 10);
    zone.innerHTML = tableau('Dossiers de crédit', ['Référence', 'Demandeur', 'Projet', 'État', 'Offre', 'Actions'], dossiers.map((d) => {
      const c = projet[d.id] || {};
      const actions = [];
      if (peut('ADM-08', 'E') && ['analyse', 'incomplet'].includes(d.etat) && !c.offre_emise_le) actions.push(`<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-offre="${d.id}">Émettre l’offre</button>`);
      if (peut('ADM-08', 'E') && c.acceptee_le && !c.fonds_debloques_le) actions.push(c.deblocage_possible_le && c.deblocage_possible_le <= aujourdhui
        ? `<button type="button" class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" data-debloquer="${d.id}">Débloquer les fonds</button>`
        : `<small>Déblocage possible le ${date(c.deblocage_possible_le)}</small>`);
      return [`<a href="${page('dossier', `?id=${d.id}`)}">${e(d.reference)}</a>`, e(`${personnes[d.personne_id]?.prenoms || ''} ${personnes[d.personne_id]?.nom_naissance || ''}`.trim() || '—'),
        e(c.montant ? `${formaterMontant(c.montant)} sur ${c.duree_mois} mois` : '—'), badgeEtat(d.etat),
        e(c.offre_emise_le ? `émise le ${date(c.offre_emise_le)}${c.taeg ? `, TAEG ${String(c.taeg).replace('.', ',')} %` : ''}${c.acceptee_le ? `, acceptée le ${date(c.acceptee_le)}` : ''}${c.fonds_debloques_le ? `, fonds versés le ${date(c.fonds_debloques_le)}` : ''}` : '—'),
        actions.join(' ') || '—'];
    }), 'Aucun dossier de crédit.');
  };
  // Demandes de prêt des clients (Espace client) et prêts en impayé
  const zoneDemandes = $('[data-demandes]');
  const zoneImpayes = $('[data-impayes]');
  const rendreClients = async () => {
    const aujourdhui = new Date().toISOString().slice(0, 10);
    const demandes = await lire('demandes', { egal: { type: 'pret_personnel' }, dans: { etat: ['demande_deposee', 'analyse', 'incomplet', 'offre_emise', 'delai_legal'] }, ordre: 'created_at', croissant: true });
    const credits = await lire('credits', { egal: { statut: 'impaye' }, ordre: 'created_at', croissant: true });
    const ids = [...new Set([...demandes, ...credits].map((x) => x.client_id))];
    const clients = ids.length ? await lire('clients', { colonnes: 'id, identifiant', dans: { id: ids } }) : [];
    const ident = Object.fromEntries(clients.map((c) => [c.id, c.identifiant]));
    zoneDemandes.innerHTML = tableau('Demandes des clients', ['Référence', 'Client', 'Projet', 'État', 'Actions'], demandes.map((d) => [e(d.reference),
      `<a href="${page('clients', `?id=${d.client_id}`)}">${e(ident[d.client_id] || '—')}</a>`, e(`${formaterMontant(d.montant)} sur ${d.duree_mois} mois`), badgeEtat(d.etat),
      !peut('ADM-08', 'E') ? '—' : ['demande_deposee', 'analyse', 'incomplet'].includes(d.etat) ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-offre-demande="${d.id}">Émettre l’offre</button>`
        : d.etat === 'delai_legal' ? (d.deblocage_possible_le && d.deblocage_possible_le.slice(0, 10) <= aujourdhui ? `<button type="button" class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" data-debloquer-demande="${d.id}">Débloquer les fonds</button>` : `<small>Déblocage possible le ${date(d.deblocage_possible_le)}</small>`) : '—']), 'Aucune demande de prêt en cours.');
    zoneImpayes.innerHTML = tableau('Prêts en impayé', ['Client', 'Prêt', 'Capital restant', 'Mensualité'], credits.map((c) => [`<a href="${page('clients', `?id=${c.client_id}`)}">${e(ident[c.client_id] || '—')}</a>`,
      e(`${formaterMontant(c.montant)} sur ${c.duree_mois} mois`), e(formaterMontant(c.capital_restant)), e(formaterMontant(c.mensualite))]), 'Aucun prêt en impayé.');
  };
  zoneDemandes.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.offreDemande) executer(b, async () => {
      const r = await demander('Émettre l’offre de prêt', [{ nom: 'taux', libelle: 'Taux débiteur (laisser vide pour le taux de la demande)', type: 'number' }], { valider: 'Émettre l’offre' });
      if (!r) return;
      await appeler('gmb_bo_credit_offre', { p_id: b.dataset.offreDemande, p_taux: r.taux || null });
      await rendreClients();
    }, 'Offre émise : le client la retrouve dans son Espace client.');
    if (b.dataset.debloquerDemande) executer(b, async () => { await appeler('gmb_bo_credit_debloquer', { p_id: b.dataset.debloquerDemande }); await rendreClients(); }, 'Fonds versés sur le compte du client ; l’échéancier est créé.');
  });
  await rendreClients();
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.offre) {
      executer(b, async () => {
        const r = await demander('Émettre l’offre de prêt', [{ nom: 'taux', libelle: 'Taux débiteur (laisser vide pour la grille en vigueur)', type: 'number' }], { valider: 'Émettre l’offre' });
        if (!r) return;
        await appeler('gmb_bo_credit_offre', { p_id: b.dataset.offre, p_taux: r.taux || null });
        await rendre();
      }, 'Offre émise : elle apparaît dans l’Espace Mon Dossier du demandeur.');
    }
    if (b.dataset.debloquer) executer(b, async () => { await appeler('gmb_bo_credit_debloquer', { p_id: b.dataset.debloquer }); await rendre(); }, 'Fonds débloqués sur le compte du client.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-16 · Trésorerie
   -------------------------------------------------------------------------- */
async function pageTresorerie() {
  await ouvrir('tresorerie', 'ADM-16');
  const ecrit = peut('ADM-16', 'E');
  const zoneV = $('[data-versements]');
  const zoneX = $('[data-virements]');
  const zoneC = $('[data-collecte]');
  // Compte bancaire réel qui reçoit les premiers versements et les virements destinés aux clients
  const rendreCollecte = () => section(zoneC, async () => {
    const lignes = await lire('parametres_banque', { colonnes: 'cle, valeur, modifie_le' });
    const c = Object.fromEntries(lignes.map((x) => [x.cle.replace('collecte_', ''), x.valeur]));
    const modifie = lignes.find((x) => x.cle === 'collecte_iban')?.modifie_le;
    zoneC.dataset.valeurs = JSON.stringify(c);
    zoneC.innerHTML = c.iban ? `<dl class="bo-dl"><div><dt>Titulaire</dt><dd>${e(c.titulaire || '—')}</dd></div><div><dt>IBAN</dt><dd><code>${e(formaterIban(c.iban))}</code></dd></div>
        <div><dt>BIC</dt><dd>${c.bic ? `<code>${e(c.bic)}</code>` : 'Non renseigné'}</dd></div><div><dt>Banque</dt><dd>${e(c.banque || '—')}</dd></div><div><dt>Enregistré le</dt><dd>${date(modifie, 'long')}</dd></div></dl>
        ${ecrit ? '<p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-collecte-modifier>Modifier le compte de réception</button></p>' : ''}`
      : `<div class="gmb-encadre gmb-encadre--alerte" role="alert">${icone('alerte')}<p><strong>Aucun compte de réception n’est renseigné.</strong> Tant qu’il manque, aucun demandeur ne peut faire son premier versement ni déposer sa demande.</p></div>
        ${ecrit ? '<p><button type="button" class="gmb-bouton gmb-bouton--principal" data-collecte-modifier>Renseigner le compte de réception</button></p>' : '<p class="bo-vide">À renseigner par un collaborateur de la trésorerie.</p>'}`;
  });
  zoneC?.addEventListener('click', (x) => {
    const b = x.target.closest('[data-collecte-modifier]');
    if (!b) return;
    executer(b, async () => {
      const c = JSON.parse(zoneC.dataset.valeurs || '{}');
      const champs = [{ nom: 'titulaire', libelle: 'Titulaire du compte, exactement comme sur le relevé d’identité bancaire', valeur: c.titulaire, requis: true }, { nom: 'iban', libelle: 'IBAN', valeur: c.iban ? formaterIban(c.iban) : '', requis: true },
        { nom: 'bic', libelle: 'BIC (facultatif)', valeur: c.bic }, { nom: 'banque', libelle: 'Nom de la banque', valeur: c.banque }];
      if (c.iban) champs.push({ nom: 'motif', libelle: 'Motif du changement (tracé au journal d’audit)', type: 'textarea', requis: true });
      const r = await demander(c.iban ? 'Modifier le compte de réception' : 'Renseigner le compte de réception', champs, { valider: 'Enregistrer' });
      if (!r) return;
      await appeler('gmb_bo_collecte_configurer', { p_titulaire: r.titulaire, p_iban: r.iban, p_bic: r.bic || null, p_banque: r.banque || null, p_motif: r.motif || null });
      await rendreCollecte();
      message('Compte de réception enregistré. Les demandeurs reçoivent désormais ces coordonnées pour leur premier versement.', 'succes');
    });
  });
  const rendre = async () => {
    const versements = await lire('premiers_versements', { egal: { statut: 'attendu' }, ordre: 'declare_le', croissant: true });
    const dossiers = versements.length ? await lire('dossiers', { colonnes: 'id, reference', dans: { id: versements.map((v) => v.dossier_id) } }) : [];
    const ref = Object.fromEntries(dossiers.map((d) => [d.id, d.reference]));
    zoneV.innerHTML = tableau('Premiers versements attendus', ['Référence à rechercher sur le relevé', 'Montant déclaré', 'Titulaire déclaré', 'Déclaré le', 'Action'], versements.map((v) => [
      `<a href="${page('dossier', `?id=${v.dossier_id}`)}">${e(ref[v.dossier_id] || '—')}</a>`, formaterMontant(v.montant), e(v.nom_titulaire || '—'), date(v.declare_le, 'long'),
      ecrit ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-recu="${v.dossier_id}">Reçu</button>` : '—']), 'Aucun versement attendu.');
    const virements = await lire('virements', { colonnes: 'id, compte_id, montant, devise, motif, beneficiaire_id, created_at', egal: { statut: 'a_executer' }, ordre: 'created_at', croissant: true });
    const comptes = virements.length ? await lire('comptes', { colonnes: 'id, numero', dans: { id: virements.map((v) => v.compte_id) } }) : [];
    const numero = Object.fromEntries(comptes.map((k) => [k.id, k.numero]));
    const benefs = virements.length ? await lire('beneficiaires', { colonnes: 'id, nom, iban', dans: { id: virements.map((v) => v.beneficiaire_id).filter(Boolean) } }) : [];
    const benef = Object.fromEntries(benefs.map((x) => [x.id, x]));
    zoneX.innerHTML = tableau('Virements vers d’autres banques à exécuter', ['Montant', 'Compte débité', 'Bénéficiaire', 'Motif', 'Créé le', 'Actions'], virements.map((v) => [
      formaterMontant(v.montant), e(numero[v.compte_id] || '—'), e(benef[v.beneficiaire_id] ? `${benef[v.beneficiaire_id].nom} · ${benef[v.beneficiaire_id].iban}` : '—'), e(v.motif || '—'), date(v.created_at, 'long'),
      ecrit ? `<button type="button" class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" data-executer="${v.id}">Exécuté</button> <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-rejeter="${v.id}">Rejeter</button>` : '—']), 'Aucun virement à exécuter.');
  };
  document.body.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.recu) executer(b, async () => {
      const r = await demander('Réception du premier versement', [{ nom: 'montant', libelle: 'Montant reçu (€)', type: 'number', requis: true }, { nom: 'titulaire', libelle: 'Titulaire du compte émetteur, tel qu’il figure sur le relevé', requis: true }]);
      if (!r) return;
      await appeler('gmb_bo_versement_recu', { p_dossier: b.dataset.recu, p_montant_recu: r.montant, p_titulaire_constate: r.titulaire });
      await rendre();
    }, 'Réception enregistrée.');
    if (b.dataset.executer) executer(b, async () => {
      const r = await demander('Virement exécuté', [{ nom: 'reference', libelle: 'Référence de l’ordre passé à la banque', requis: true }]);
      if (!r) return;
      await appeler('gmb_bo_virement_executer', { p_virement: b.dataset.executer, p_reference: r.reference });
      await rendre();
    }, 'Virement exécuté.');
    if (b.dataset.rejeter) executer(b, async () => {
      const r = await demander('Rejeter le virement', [{ nom: 'motif', libelle: 'Motif (communiqué au client)', type: 'textarea', requis: true }], { valider: 'Rejeter', danger: true });
      if (!r) return;
      await appeler('gmb_bo_virement_rejeter', { p_virement: b.dataset.rejeter, p_motif: r.motif });
      await rendre();
    }, 'Virement rejeté : le compte du client est recrédité.');
  });
  const form = $('[data-form="fonds"]');
  form.hidden = !ecrit;
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const numeroCompte = form.elements.numero.value.replace(/\s/g, '');
      const montant = Number(String(form.elements.montant.value).replace(',', '.'));
      if (!/^\d{11}$/.test(numeroCompte)) throw new ErreurGmb('Le numéro de compte GerMoonBank comporte 11 chiffres.');
      if (!(montant > 0)) throw new ErreurGmb('Indiquez le montant reçu.');
      if (!form.elements.emetteur.value.trim()) throw new ErreurGmb('Indiquez l’émetteur du virement.');
      const iban = form.elements.iban_emetteur.value.replace(/\s/g, '').toUpperCase();
      if (iban && !/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(iban)) throw new ErreurGmb('L’IBAN de l’émetteur n’est pas valide : recopiez-le depuis le relevé.');
      await appeler('gmb_bo_fonds_recus', { p_numero_compte: numeroCompte, p_montant: montant, p_emetteur: form.elements.emetteur.value.trim(), p_reference: form.elements.reference.value.trim() || null,
        p_iban_emetteur: iban || null, p_motif: form.elements.motif.value.trim() || null });
      form.reset();
    }, 'Fonds crédités sur le compte du client.');
  });
  await rendreCollecte();
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-05 · LCB-FT : alertes et profils de risque
   -------------------------------------------------------------------------- */
const TYPES_LCBFT = { gel_avoirs: 'Gel des avoirs', ppe: 'Personne politiquement exposée', pays_risque: 'Pays à risque', scenario: 'Scénario de surveillance', revue_periodique: 'Revue périodique' };
async function nomsPersonnes(ids) {
  const liste = ids.length ? await lire('personnes', { colonnes: 'id, prenoms, nom_naissance', dans: { id: [...new Set(ids)] } }) : [];
  return Object.fromEntries(liste.map((p) => [p.id, `${p.prenoms || ''} ${p.nom_naissance || ''}`.trim()]));
}
async function pageLcbft() {
  await ouvrir('lcb-ft', 'ADM-05');
  const ecrit = peut('ADM-05', 'E');
  const zone = $('[data-liste]');
  const zoneRisques = $('[data-risques]');
  const rendre = async () => {
    const alertes = await lire('alertes_lcbft', { dans: { statut: ['ouverte', 'en_analyse'] }, ordre: 'created_at', croissant: true });
    const noms = await nomsPersonnes(alertes.map((a) => a.personne_id).filter(Boolean));
    zone.innerHTML = tableau('Alertes à traiter', ['Type', 'Personne', 'Gravité', 'Statut', 'Créée le', 'Actions'], alertes.map((a) => [e(TYPES_LCBFT[a.type] || a.type),
      e(noms[a.personne_id] || '—'), badge(a.gravite, a.gravite === 'elevee' ? 'danger' : 'neutre'), badge(a.statut), date(a.created_at, 'long'),
      ecrit ? `${a.statut === 'ouverte' ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-alerte="${a.id}" data-statut="en_analyse">Analyser</button>` : ''}
        <button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-alerte="${a.id}" data-statut="classee">Classer</button>
        <button type="button" class="gmb-bouton gmb-bouton--danger gmb-bouton--petit" data-alerte="${a.id}" data-statut="declaree">Déclarer</button>` : '—']), 'Aucune alerte à traiter.');
    const risques = await lire('profils_risque', { egal: { niveau: 'eleve' }, ordre: 'revue_avant', croissant: true });
    const nomsR = await nomsPersonnes(risques.map((r) => r.personne_id));
    zoneRisques.innerHTML = tableau('Profils de risque élevé', ['Personne', 'Score', 'Motifs', 'Revue avant le'], risques.map((r) => [e(nomsR[r.personne_id] || '—'), e(r.score ?? '—'),
      e(Array.isArray(r.motifs) ? r.motifs.join(', ') : (r.motifs ? JSON.stringify(r.motifs) : '—')), date(r.revue_avant)]), 'Aucun profil de risque élevé.');
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('[data-alerte]');
    if (!b) return;
    executer(b, async () => {
      const statut = b.dataset.statut;
      const r = await demander({ en_analyse: 'Prendre l’alerte en analyse', classee: 'Classer l’alerte', declaree: 'Déclarer à TRACFIN' }[statut],
        [{ nom: 'note', libelle: statut === 'declaree' ? 'Référence de la déclaration et analyse' : 'Analyse (note interne)', type: 'textarea', requis: statut !== 'en_analyse' }],
        { valider: { en_analyse: 'Analyser', classee: 'Classer', declaree: 'Enregistrer la déclaration' }[statut], danger: statut === 'declaree' });
      if (!r) return;
      await appeler('gmb_bo_alerte_traiter', { p_type: 'lcbft', p_alerte: b.dataset.alerte, p_statut: statut, p_note: r.note || null });
      await rendre();
    }, 'Alerte mise à jour.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-06 · Fraude, litiges et contestations
   -------------------------------------------------------------------------- */
const TYPES_FRAUDE = { connexion_suspecte: 'Connexion suspecte', operation_inhabituelle: 'Opération inhabituelle', contestation: 'Contestation', refus_gmb_pass: 'Validation refusée', escroquerie_virement: 'Escroquerie au virement' };
async function identifiantsClients(ids) {
  const liste = ids.length ? await lire('clients', { colonnes: 'id, identifiant', dans: { id: [...new Set(ids)] } }) : [];
  return Object.fromEntries(liste.map((c) => [c.id, c.identifiant]));
}
async function pageFraude() {
  await ouvrir('fraude', 'ADM-06');
  const ecrit = peut('ADM-06', 'E');
  const zoneA = $('[data-alertes]');
  const zoneC = $('[data-contestations]');
  const rendre = async () => {
    const alertes = await lire('alertes_fraude', { dans: { statut: ['ouverte', 'en_analyse'] }, ordre: 'created_at', croissant: true });
    const contestations = await lire('contestations', { egal: { statut: 'ouverte' }, ordre: 'rembourser_avant', croissant: true });
    const ident = await identifiantsClients([...alertes, ...contestations].map((x) => x.client_id).filter(Boolean));
    zoneA.innerHTML = tableau('Alertes de fraude', ['Type', 'Client', 'Score', 'Statut', 'Créée le', 'Actions'], alertes.map((a) => [e(TYPES_FRAUDE[a.type] || a.type),
      a.client_id ? `<a href="${page('clients', `?id=${a.client_id}`)}">${e(ident[a.client_id] || '—')}</a>` : '—', e(a.score ?? '—'), badge(a.statut), date(a.created_at, 'long'),
      ecrit ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-alerte="${a.id}" data-statut="classee">Classer</button>
        <button type="button" class="gmb-bouton gmb-bouton--danger gmb-bouton--petit" data-alerte="${a.id}" data-statut="confirmee">Confirmer la fraude</button>` : '—']), 'Aucune alerte de fraude.');
    zoneC.innerHTML = tableau('Contestations ouvertes', ['Montant', 'Client', 'Motif', 'À rembourser avant', 'Actions'], contestations.map((k) => [formaterMontant(k.montant),
      k.client_id ? `<a href="${page('clients', `?id=${k.client_id}`)}">${e(ident[k.client_id] || '—')}</a>` : '—', e(k.motif || '—'),
      `${date(k.rembourser_avant, 'long')}${new Date(k.rembourser_avant) < new Date() ? ` ${badge('Délai dépassé', 'danger')}` : ''}`,
      ecrit ? `<button type="button" class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" data-rembourser="${k.id}">Rembourser</button>
        <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-refuser="${k.id}">Refuser</button>` : '—']), 'Aucune contestation ouverte.');
  };
  document.body.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.alerte) executer(b, async () => {
      const r = await demander(b.dataset.statut === 'confirmee' ? 'Confirmer la fraude' : 'Classer l’alerte', [{ nom: 'note', libelle: 'Analyse (note interne)', type: 'textarea', requis: true }], { danger: b.dataset.statut === 'confirmee' });
      if (!r) return;
      await appeler('gmb_bo_alerte_traiter', { p_type: 'fraude', p_alerte: b.dataset.alerte, p_statut: b.dataset.statut, p_note: r.note });
      await rendre();
    }, 'Alerte mise à jour.');
    if (b.dataset.rembourser) executer(b, async () => {
      const r = await appeler('gmb_bo_contestation_rembourser', { p_contestation: b.dataset.rembourser });
      await rendre();
      message(r?.dans_les_delais === false ? 'Remboursement effectué, mais après l’échéance réglementaire.' : 'Remboursement effectué dans les délais.', r?.dans_les_delais === false ? 'info' : 'succes');
    });
    if (b.dataset.refuser) executer(b, async () => {
      const r = await demander('Refuser la contestation', [{ nom: 'motif', libelle: 'Motif du refus (preuve d’authentification, etc.)', type: 'textarea', requis: true }], { valider: 'Refuser', danger: true });
      if (!r) return;
      await appeler('gmb_bo_contestation_refuser', { p_contestation: b.dataset.refuser, p_motif: r.motif });
      await rendre();
    }, 'Contestation refusée : le motif est tracé au journal d’audit.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-07 · Clients 360°
   -------------------------------------------------------------------------- */
const STATUTS_COMMANDE_CARTE = { demandee: 'À traiter', transmise: 'Transmise à l’émetteur', emise: 'Émise', refusee: 'Refusée', annulee: 'Annulée par le client' };
async function pageClients() {
  await ouvrir('clients', 'ADM-07');
  const zone = $('[data-liste]');
  const form = $('[data-form="recherche"]');
  const liste = async (texte = '') => {
    const clients = await lire('clients', { colonnes: 'id, identifiant, segment, formule_code, statut, personne_id, ouvert_le', ordre: 'created_at', croissant: false, limite: 500 });
    const noms = await nomsPersonnes(clients.map((c) => c.personne_id));
    const t = texte.trim().toLowerCase();
    const filtres = t ? clients.filter((c) => c.identifiant.includes(t) || (noms[c.personne_id] || '').toLowerCase().includes(t)) : clients;
    zone.innerHTML = tableau('Clients', ['Identifiant', 'Nom', 'Profil', 'Formule', 'Statut', 'Ouvert le'], filtres.slice(0, 100).map((c) => [
      `<a href="${page('clients', `?id=${c.id}`)}">${e(c.identifiant)}</a>`, e(noms[c.personne_id] || '—'), e(c.segment), e(c.formule_code), badge(c.statut, c.statut === 'bloque' ? 'danger' : 'neutre'), date(c.ouvert_le)]), 'Aucun client ne correspond.');
  };
  const fiche = async (id) => {
    form.hidden = true;
    document.querySelectorAll('[data-section-globale]').forEach((x) => { x.hidden = true; });
    const c = await lire('clients', { egal: { id }, unique: true });
    if (!c) { zone.innerHTML = '<p class="bo-vide">Client introuvable.</p>'; return; }
    const [p, comptes, reclamations, commandes] = await Promise.all([lire('personnes', { egal: { id: c.personne_id }, unique: true }), lire('comptes', { egal: { client_id: id } }), lire('reclamations', { egal: { client_id: id }, ordre: 'created_at', croissant: false }),
      lire('commandes_cartes', { egal: { client_id: id }, ordre: 'created_at', croissant: false }).catch(() => [])]);
    const ids = comptes.map((k) => k.id);
    const [cartes, operations] = ids.length ? await Promise.all([lire('cartes', { dans: { compte_id: ids } }), lire('operations', { dans: { compte_id: ids }, ordre: 'date_operation', croissant: false, limite: 20 })]) : [[], []];
    const ecrit = peut('ADM-07', 'E');
    zone.innerHTML = `<header class="bo-fiche__entete"><h2 class="gmb-section__titre">${e(`${p?.prenoms || ''} ${p?.nom_naissance || ''}`)} · ${e(c.identifiant)}</h2>
        <p>${badge(c.statut, c.statut === 'bloque' ? 'danger' : 'neutre')} ${e(c.segment)} · formule ${e(c.formule_code)} · client depuis le ${date(c.ouvert_le, 'long')}</p>
        ${ecrit && c.statut !== 'cloture' ? `<p>${c.statut === 'bloque' ? '<button type="button" class="gmb-bouton gmb-bouton--secondaire" data-client-statut="actif">Débloquer</button>' : '<button type="button" class="gmb-bouton gmb-bouton--danger" data-client-statut="bloque">Bloquer l’accès</button>'}</p>` : ''}</header>
      <section class="gmb-carte bo-bloc" aria-labelledby="t-coord"><h2 id="t-coord">Coordonnées</h2><dl class="bo-dl">
        <div><dt>Adresse</dt><dd>${e([p?.adresse_ligne1, p?.code_postal, p?.ville].filter(Boolean).join(' ') || '—')}</dd></div>
        <div><dt>Contact</dt><dd>${e(`${p?.email || '—'} · ${p?.telephone || '—'}`)}</dd></div></dl></section>
      <section class="gmb-carte bo-bloc" aria-labelledby="t-comptes"><h2 id="t-comptes">Comptes</h2>${tableau('Comptes', ['Numéro', 'Type', 'Libellé', 'IBAN', 'Solde', 'Statut'], comptes.map((k) => [e(k.numero), e(k.type), e(k.libelle || '—'),
        `${k.iban ? `<code>${e(k.iban.replace(/(.{4})/g, '$1 ').trim())}</code>${k.bic ? `<br><small>BIC ${e(k.bic)}</small>` : ''}` : '—'}${ecrit && k.statut !== 'cloture' && ['courant', 'pro', 'business', 'jeune', 'livret'].includes(k.type) ? ` <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-iban="${k.id}" data-iban-actuel="${e(k.iban || '')}" data-bic-actuel="${e(k.bic || '')}">${k.iban ? 'Modifier' : 'Renseigner l’IBAN'}</button>` : ''}`,
        formaterMontant(k.solde), badge(k.statut)]), 'Aucun compte.')}</section>
      <section class="gmb-carte bo-bloc" aria-labelledby="t-cartes"><h2 id="t-cartes">Cartes</h2>${tableau('Cartes', ['Carte', 'Type', 'Expiration', 'Statut', 'Plafond de paiement (30 j)'], cartes.map((k) => [e(`${k.gamme || ''} •••• ${k.derniers_chiffres || '—'}`), e(k.type), e(k.expiration || '—'), badge(k.statut), k.plafond_paiement_30j ? formaterMontant(k.plafond_paiement_30j) : '—']), 'Aucune carte.')}
        ${commandes.length ? `<h3>Commandes de cartes</h3>${tableau('Commandes de cartes', ['Demandée le', 'Carte', 'Statut', 'Traitée le'], commandes.map((k) => [date(k.created_at, 'long'), e(`${k.type === 'physique' ? 'Physique' : 'Virtuelle'} ${k.gamme}`), badge(STATUTS_COMMANDE_CARTE[k.statut] || k.statut, k.statut === 'refusee' ? 'danger' : 'neutre'), k.traitee_le ? date(k.traitee_le, 'long') : '—']))}` : ''}</section>
      <section class="gmb-carte bo-bloc" aria-labelledby="t-ops"><h2 id="t-ops">20 dernières opérations</h2>${tableau('Opérations', ['Date', 'Libellé', 'Montant', 'Statut'], operations.map((o) => [date(o.date_operation || o.created_at), e(o.libelle), formaterMontant(o.montant), badge(o.statut)]), 'Aucune opération.')}</section>
      <section class="gmb-carte bo-bloc" aria-labelledby="t-rec"><h2 id="t-rec">Réclamations</h2>${tableau('Réclamations', ['Référence', 'Objet', 'Statut', 'Réponse avant le'], reclamations.map((r) => [e(r.reference), e(r.objet), badge(r.statut), date(r.reponse_avant)]), 'Aucune réclamation.')}</section>
      <p><a href="${page('clients')}">Retour à la liste des clients</a></p>`;
    zone.querySelectorAll('[data-iban]').forEach((bouton) => bouton.addEventListener('click', (x) => executer(x.currentTarget, async () => {
      const actuel = bouton.dataset.ibanActuel;
      const r = await demander(actuel ? 'Modifier l’IBAN du compte' : 'Renseigner l’IBAN du compte', [
        { nom: 'iban', libelle: 'IBAN attribué par l’établissement teneur du compte', valeur: actuel, requis: true },
        { nom: 'bic', libelle: 'BIC de l’établissement teneur du compte', valeur: bouton.dataset.bicActuel, requis: true },
        ...(actuel ? [{ nom: 'motif', libelle: 'Motif du changement (tracé au journal d’audit)', type: 'textarea', requis: true }] : [])], { valider: 'Enregistrer' });
      if (!r) return;
      await appeler('gmb_bo_compte_iban', { p_compte: bouton.dataset.iban, p_iban: r.iban, p_bic: r.bic, p_motif: r.motif || null });
      await fiche(id);
    }, 'IBAN enregistré : le client le retrouve dans son RIB.')));
    zone.querySelector('[data-client-statut]')?.addEventListener('click', (x) => executer(x.currentTarget, async () => {
      const statut = x.currentTarget.dataset.clientStatut;
      const r = await demander(statut === 'bloque' ? 'Bloquer l’accès du client' : 'Débloquer l’accès du client', [{ nom: 'motif', libelle: 'Motif (tracé au journal d’audit)', type: 'textarea', requis: true }], { valider: statut === 'bloque' ? 'Bloquer' : 'Débloquer', danger: statut === 'bloque' });
      if (!r) return;
      await appeler('gmb_bo_client_statut', { p_client: id, p_statut: statut, p_motif: r.motif });
      await fiche(id);
    }, 'Statut du client modifié.'));
  };
  form.addEventListener('submit', (x) => { x.preventDefault(); liste(form.elements.texte.value).catch((y) => message(messageErreur(y))); });
  if (parametre('id')) await fiche(parametre('id')); else await liste();
  // Commandes de cartes : transmises à l'émetteur, puis carte émise (4 derniers chiffres et expiration) ou refus motivé
  const zoneK = $('[data-commandes-cartes]');
  if (zoneK) {
    const rendreK = async () => {
      const commandes = await lire('commandes_cartes', { dans: { statut: ['demandee', 'transmise'] }, ordre: 'created_at', croissant: true });
      const identK = await identifiantsClients(commandes.map((k) => k.client_id));
      const ecritK = peut('ADM-07', 'E');
      zoneK.innerHTML = tableau('Commandes de cartes à traiter', ['Client', 'Demandée le', 'Carte', 'Livraison', 'Statut', 'Actions'], commandes.map((k) => [`<a href="${page('clients', `?id=${k.client_id}`)}">${e(identK[k.client_id] || '—')}</a>`,
        date(k.created_at, 'long'), e(`${k.type === 'physique' ? 'Physique' : 'Virtuelle'} ${k.gamme}`),
        k.livraison ? e([k.livraison.nom, k.livraison.ligne1, k.livraison.ligne2, `${k.livraison.code_postal || ''} ${k.livraison.ville || ''}`, k.livraison.pays].filter((x) => x && String(x).trim()).join(', ')) : '—',
        badge(STATUTS_COMMANDE_CARTE[k.statut] || k.statut),
        ecritK ? `${k.statut === 'demandee' ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-commande-carte="${k.id}" data-decision="transmise">Transmise à l’émetteur</button> ` : ''}<button type="button" class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" data-commande-carte="${k.id}" data-decision="emise">Carte émise</button> <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-commande-carte="${k.id}" data-decision="refusee">Refuser</button>` : '—']),
        'Aucune commande de carte à traiter.');
    };
    zoneK.addEventListener('click', (x) => {
      const b = x.target.closest('[data-commande-carte]');
      if (!b) return;
      executer(b, async () => {
        const decision = b.dataset.decision; let v = {};
        if (decision === 'emise') { v = await demander('Carte émise', [{ nom: 'chiffres', libelle: '4 derniers chiffres de la carte', requis: true }, { nom: 'expiration', libelle: 'Date d’expiration (MM/AA)', requis: true }], { valider: 'Enregistrer la carte' }); if (!v) return; }
        if (decision === 'refusee') { v = await demander('Refuser la commande', [{ nom: 'motif', libelle: 'Motif communiqué au client', type: 'textarea', requis: true }], { valider: 'Refuser', danger: true }); if (!v) return; }
        await appeler('gmb_bo_carte_commande_traiter', { p_commande: b.dataset.commandeCarte, p_decision: decision, p_chiffres: v.chiffres || null, p_expiration: v.expiration || null, p_motif: v.motif || null });
        await rendreK();
      }, b.dataset.decision === 'emise' ? 'Carte enregistrée : le client est prévenu.' : b.dataset.decision === 'transmise' ? 'Commande marquée comme transmise à l’émetteur.' : 'Refus envoyé au client.');
    });
    await section(zoneK, rendreK);
  }
  // Demandes de fermeture de compte : clôture une fois le solde restitué, ou refus motivé
  const zoneC = $('[data-clotures]');
  if (zoneC) {
    const MOTIFS_CLOTURE = { ne_convient_plus: 'Le service ne convient plus', frais: 'Les frais', autre_banque: 'Regroupement dans une autre banque', demenagement_etranger: 'Installation à l’étranger', autre: 'Autre raison' };
    const rendreC = async () => {
      const demandes = await lire('demandes_cloture', { egal: { statut: 'demandee' }, ordre: 'created_at', croissant: true });
      const identC = await identifiantsClients(demandes.map((d) => d.client_id));
      const comptesC = demandes.length ? await lire('comptes', { colonnes: 'client_id, solde, statut', dans: { client_id: demandes.map((d) => d.client_id) } }) : [];
      const solde = (id) => comptesC.filter((k) => k.client_id === id && k.statut !== 'cloture').reduce((s, k) => s + Number(k.solde), 0);
      zoneC.innerHTML = tableau('Demandes de fermeture', ['Client', 'Reçue le', 'Motif', 'Solde à restituer', 'Restitution', 'Actions'], demandes.map((d) => [`<a href="${page('clients', `?id=${d.client_id}`)}">${e(identC[d.client_id] || '—')}</a>`,
        date(d.created_at), `${e(MOTIFS_CLOTURE[d.motif] || d.motif)}${d.precision_motif ? `<br><small>${e(d.precision_motif)}</small>` : ''}`, e(formaterMontant(solde(d.client_id))),
        `${e(d.titulaire_restitution)}<br><code>${e(d.iban_restitution.replace(/(.{4})/g, '$1 ').trim())}</code>`,
        peut('ADM-07', 'E') ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-cloture="${d.id}" data-decision="traitee">Clôture effectuée</button> <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-cloture="${d.id}" data-decision="refusee">Refuser</button>` : '—']), 'Aucune demande de fermeture.');
    };
    zoneC.addEventListener('click', (x) => {
      const b = x.target.closest('[data-cloture]');
      if (!b) return;
      executer(b, async () => {
        let motif = null;
        if (b.dataset.decision === 'refusee') { const r = await demander('Refuser la fermeture', [{ nom: 'motif', libelle: 'Motif communiqué au client', type: 'textarea', requis: true }], { valider: 'Refuser' }); if (!r) return; motif = r.motif; }
        await appeler('gmb_bo_cloture_traiter', { p_id: b.dataset.cloture, p_decision: b.dataset.decision, p_motif: motif });
        await rendreC();
      }, b.dataset.decision === 'traitee' ? 'Compte clôturé : le client est prévenu.' : 'Refus envoyé au client.');
    });
    await section(zoneC, rendreC);
  }
}

/* -----------------------------------------------------------------------------
   ADM-09 · Support et réclamations
   -------------------------------------------------------------------------- */
async function pageReclamations() {
  await ouvrir('reclamations', 'ADM-09');
  const ecrit = peut('ADM-09', 'E');
  const zoneR = $('[data-reclamations]');
  const zoneM = $('[data-messagerie]');
  const zoneRdv = $('[data-rdv]');
  const rendre = async () => {
    const reclamations = await lire('reclamations', { dans: { statut: ['recue', 'en_cours', 'repondue'] }, ordre: 'reponse_avant', croissant: true });
    const ident = await identifiantsClients(reclamations.map((r) => r.client_id));
    const maintenant = new Date();
    zoneR.innerHTML = tableau('Réclamations', ['Référence', 'Client', 'Objet', 'Statut', 'Accusé avant', 'Réponse avant', 'Actions'], reclamations.map((r) => [e(r.reference),
      `<a href="${page('clients', `?id=${r.client_id}`)}">${e(ident[r.client_id] || '—')}</a>`, `${e(r.objet)}<br><small>${e(r.description || '')}</small>`, badge(r.statut),
      `${date(r.accuse_avant)}${!r.accuse_le && new Date(r.accuse_avant) < maintenant ? ` ${badge('Dépassé', 'danger')}` : ''}`, `${date(r.reponse_avant)}${!r.repondue_le && new Date(r.reponse_avant) < maintenant ? ` ${badge('Dépassé', 'danger')}` : ''}`,
      ecrit ? `${r.statut === 'recue' ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-accuser="${r.id}">Accuser réception</button>` : ''}
        <button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-repondre="${r.id}">Répondre</button>` : '—']), 'Aucune réclamation en cours.');
    const fils = await lire('fils_messagerie', { dans: { statut: ['ouvert', 'en_attente_client'] }, ordre: 'updated_at', croissant: false });
    const identF = await identifiantsClients(fils.map((f) => f.client_id));
    const messages = fils.length ? await lire('messages', { dans: { fil_id: fils.map((f) => f.id) }, ordre: 'created_at', croissant: true }) : [];
    zoneM.innerHTML = fils.length ? fils.map((f) => `<article class="gmb-carte bo-bloc"><h3>${e(f.sujet)} · <a href="${page('clients', `?id=${f.client_id}`)}">${e(identF[f.client_id] || '—')}</a> ${badge(f.statut === 'ouvert' ? 'À traiter' : 'En attente du client')}</h3>
        <ol class="bo-fil">${messages.filter((m) => m.fil_id === f.id).map((m) => `<li class="bo-fil__message bo-fil__message--${e(m.auteur)}"><p>${e(m.contenu)}</p><small>${e(m.auteur === 'client' ? 'Client' : 'Conseiller')} · ${date(m.created_at, 'long')}</small></li>`).join('')}</ol>
        ${ecrit ? `<p><button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-fil="${f.id}">Répondre</button></p>` : ''}</article>`).join('') : '<p class="bo-vide">Aucune conversation en cours.</p>';
    // Rendez-vous demandés par les clients et pour les dossiers
    const [rc, rd] = await Promise.all([lire('rendez_vous_clients', { dans: { statut: ['demande', 'confirme'] }, ordre: 'debut', croissant: true }),
      lire('dossier_rendez_vous', { dans: { statut: ['demande', 'confirme'] }, ordre: 'debut', croissant: true })]);
    const identR = await identifiantsClients(rc.map((r) => r.client_id));
    const refs = rd.length ? Object.fromEntries((await lire('dossiers', { colonnes: 'id, reference', dans: { id: [...new Set(rd.map((r) => r.dossier_id))] } })).map((d) => [d.id, d.reference])) : {};
    const rdv = [...rc.map((r) => ({ ...r, source: 'client', qui: `<a href="${page('clients', `?id=${r.client_id}`)}">${e(identR[r.client_id] || '—')}</a>` })),
      ...rd.map((r) => ({ ...r, source: 'dossier', motif: 'Finaliser la demande', qui: `<a href="${page('dossier', `?id=${r.dossier_id}`)}">${e(refs[r.dossier_id] || '—')}</a>` }))].sort((a, b) => String(a.debut).localeCompare(String(b.debut)));
    const bouton = (r, statut, libelle, style) => `<button type="button" class="gmb-bouton gmb-bouton--${style} gmb-bouton--petit" data-rdv-id="${r.id}" data-source="${r.source}" data-rdv-statut="${statut}">${libelle}</button>`;
    zoneRdv.innerHTML = tableau('Rendez-vous', ['Date', 'Demandeur', 'Canal', 'Objet', 'Statut', 'Actions'], rdv.map((r) => [`${date(r.debut)} à ${new Date(r.debut).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Paris' })}`,
      r.qui, e(r.canal === 'video' ? 'Vidéo' : 'Téléphone'), e(r.motif || ''), badge(r.statut === 'confirme' ? 'Confirmé' : 'Demandé', r.statut === 'confirme' ? 'succes' : 'neutre'),
      ecrit ? `${r.statut === 'demande' ? bouton(r, 'confirme', 'Confirmer', 'secondaire') : bouton(r, 'termine', 'Terminé', 'secondaire')} ${bouton(r, 'annule', 'Annuler', 'fantome')}` : '—']), 'Aucun rendez-vous à traiter.');
  };
  document.body.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.rdvStatut) executer(b, async () => { await appeler('gmb_bo_rdv_statuer', { p_source: b.dataset.source, p_id: b.dataset.rdvId, p_statut: b.dataset.rdvStatut }); await rendre(); }, 'Rendez-vous mis à jour : le demandeur est prévenu.');
    if (b.dataset.accuser) executer(b, async () => { await appeler('gmb_bo_reclamation_accuser', { p_reclamation: b.dataset.accuser }); await rendre(); }, 'Accusé de réception enregistré.');
    if (b.dataset.repondre) executer(b, async () => {
      const r = await demander('Répondre à la réclamation', [{ nom: 'reponse', libelle: 'Réponse au client', type: 'textarea', requis: true }, { nom: 'clore', libelle: 'Après cette réponse', options: [['non', 'Laisser la réclamation ouverte'], ['oui', 'Clore la réclamation']] }], { valider: 'Envoyer la réponse' });
      if (!r) return;
      const res = await appeler('gmb_bo_reclamation_repondre', { p_reclamation: b.dataset.repondre, p_reponse: r.reponse, p_clore: r.clore === 'oui' });
      await rendre();
      message(res?.dans_les_delais === false ? 'Réponse envoyée, mais après le délai légal.' : 'Réponse envoyée dans les délais.', res?.dans_les_delais === false ? 'info' : 'succes');
    });
    if (b.dataset.fil) executer(b, async () => {
      const r = await demander('Répondre au client', [{ nom: 'contenu', libelle: 'Message', type: 'textarea', requis: true }, { nom: 'clore', libelle: 'Après ce message', options: [['non', 'Attendre la réponse du client'], ['oui', 'Clore la conversation']] }], { valider: 'Envoyer' });
      if (!r) return;
      await appeler('gmb_bo_message', { p_fil: b.dataset.fil, p_contenu: r.contenu, p_clore: r.clore === 'oui' });
      await rendre();
    }, 'Message envoyé.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-15 · Opérations et pilotage
   -------------------------------------------------------------------------- */
async function pageOperations() {
  await ouvrir('operations', 'ADM-15');
  const depuis = new Date(Date.now() - 30 * 864e5).toISOString();
  const [clients, comptes, operations, virements, dossiers] = await Promise.all([
    lire('clients', { colonnes: 'id, statut, segment', limite: 10000 }), lire('comptes', { colonnes: 'id, type, solde, statut', limite: 10000 }),
    lire('operations', { colonnes: 'id, type, montant, statut, created_at', depuis: { created_at: depuis }, limite: 10000 }),
    lire('virements', { colonnes: 'id, statut, montant, created_at', depuis: { created_at: depuis }, limite: 10000 }),
    lire('dossiers', { colonnes: 'id, type, etat, depose_le', depuis: { created_at: depuis }, limite: 10000 }),
  ]);
  const somme = (l) => l.reduce((t, x) => t + Number(x.montant ?? x.solde ?? 0), 0);
  const parType = {};
  for (const o of operations.filter((x) => x.statut === 'comptabilisee')) { parType[o.type] = parType[o.type] || { n: 0, v: 0 }; parType[o.type].n += 1; parType[o.type].v += Number(o.montant); }
  $('[data-bo-contenu]').innerHTML = `<h1 class="gmb-section__titre" id="titre-page">Opérations et pilotage</h1>
    <div class="gmb-grille gmb-grille--3">
      ${[['Clients actifs', clients.filter((c) => c.statut === 'actif').length], ['Comptes ouverts', comptes.filter((k) => k.statut === 'actif').length], ['Dépôts des clients', formaterMontant(somme(comptes.filter((k) => k.statut === 'actif')))],
        ['Opérations sur 30 jours', operations.length], ['Virements sur 30 jours', virements.length], ['Demandes déposées sur 30 jours', dossiers.filter((d) => d.depose_le).length]]
        .map(([t, v]) => `<div class="gmb-carte bo-compteur"><span class="bo-compteur__nombre">${e(v)}</span><span class="bo-compteur__libelle">${e(t)}</span></div>`).join('')}</div>
    <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-types"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-types">Opérations comptabilisées sur 30 jours, par type</h2>
      ${tableau('Opérations par type', ['Type', 'Nombre', 'Montant net'], Object.entries(parType).sort((a, b) => b[1].n - a[1].n).map(([t, x]) => [e(t), e(x.n), formaterMontant(x.v)]), 'Aucune opération sur la période.')}</section>
    <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-vir"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-vir">Virements sur 30 jours, par statut</h2>
      ${tableau('Virements par statut', ['Statut', 'Nombre', 'Montant'], Object.entries(virements.reduce((m, v) => { m[v.statut] = m[v.statut] || []; m[v.statut].push(v); return m; }, {})).map(([s, l]) => [e(s), e(l.length), formaterMontant(somme(l))]), 'Aucun virement sur la période.')}</section>`;
}

/* -----------------------------------------------------------------------------
   ADM-02 · Contenus : du brouillon à la publication
   -------------------------------------------------------------------------- */
const STATUTS_CMS = { brouillon: 'Brouillon', relecture_conformite: 'Relecture conformité', validation_juridique: 'Validation juridique', planifiee: 'Planifiée', publiee: 'Publiée', archivee: 'Archivée' };
async function pageCms() {
  await ouvrir('cms', 'ADM-02');
  const zone = $('[data-liste]');
  const rendre = async () => {
    const pages = await lire('cms_pages', { colonnes: 'id, ecran, slug, langue, titre, description_seo, blocs_brouillon, statut, version, planifiee_le, publiee_le, updated_at', ordre: 'updated_at', croissant: false });
    zone.innerHTML = tableau('Pages de contenu', ['Page', 'Écran', 'Statut', 'Version', 'Mise à jour', 'Actions'], pages.map((p) => {
      const a = [];
      const bouton = (statut, libelle, type = 'secondaire') => `<button type="button" class="gmb-bouton gmb-bouton--${type} gmb-bouton--petit" data-page="${p.id}" data-statut="${statut}">${libelle}</button>`;
      if (p.statut === 'brouillon') { a.push(`<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-modifier="${p.id}">Modifier</button>`); a.push(bouton('relecture_conformite', 'Envoyer en relecture')); }
      if (p.statut === 'relecture_conformite') { a.push(bouton('validation_juridique', 'Transmettre au juridique')); a.push(bouton('publiee', 'Publier', 'principal')); a.push(bouton('brouillon', 'Renvoyer en brouillon', 'fantome')); }
      if (p.statut === 'validation_juridique') { a.push(bouton('publiee', 'Publier', 'principal')); a.push(bouton('planifiee', 'Planifier')); a.push(bouton('brouillon', 'Renvoyer en brouillon', 'fantome')); }
      if (['publiee', 'planifiee'].includes(p.statut)) { a.push(bouton('brouillon', 'Nouvelle version')); a.push(bouton('archivee', 'Archiver', 'fantome')); }
      if (p.statut === 'archivee') a.push(bouton('brouillon', 'Restaurer en brouillon'));
      return [`${e(p.titre)}<br><small>/${e(p.slug)} (${e(p.langue)})</small>`, e(p.ecran || '—'), badge(STATUTS_CMS[p.statut] || p.statut), e(p.version ?? '—'),
        date(p.updated_at, 'long') + (p.planifiee_le ? `<br><small>planifiée le ${date(p.planifiee_le, 'long')}</small>` : ''), a.join(' ') || '—'];
    }), 'Aucune page de contenu.');
    zone.dataset.pages = JSON.stringify(Object.fromEntries(pages.map((p) => [p.id, { titre: p.titre, description_seo: p.description_seo, blocs: p.blocs_brouillon }])));
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.modifier) executer(b, async () => {
      const p = JSON.parse(zone.dataset.pages)[b.dataset.modifier];
      const r = await demander('Modifier le brouillon', [{ nom: 'titre', libelle: 'Titre', valeur: p.titre, requis: true }, { nom: 'description', libelle: 'Description pour les moteurs de recherche (155 caractères au plus)', type: 'textarea', valeur: p.description_seo || '' },
        { nom: 'blocs', libelle: 'Blocs de contenu (liste JSON)', type: 'textarea', valeur: p.blocs ? JSON.stringify(p.blocs, null, 2) : '' }], { valider: 'Enregistrer le brouillon' });
      if (!r) return;
      let blocs = null;
      if (r.blocs) { try { blocs = JSON.parse(r.blocs); } catch { throw new ErreurGmb('Les blocs ne forment pas un JSON valide.'); } }
      await appeler('gmb_bo_cms_modifier', { p_page: b.dataset.modifier, p_titre: r.titre, p_description_seo: r.description || null, p_blocs: blocs });
      await rendre();
    }, 'Brouillon enregistré.');
    if (b.dataset.page) executer(b, async () => {
      let planifiee = null;
      if (b.dataset.statut === 'planifiee') {
        const r = await demander('Planifier la publication', [{ nom: 'quand', libelle: 'Date et heure de publication', type: 'datetime-local', requis: true }], { valider: 'Planifier' });
        if (!r) return;
        planifiee = new Date(r.quand).toISOString();
      }
      await appeler('gmb_bo_cms_statut', { p_page: b.dataset.page, p_statut: b.dataset.statut, p_planifiee_le: planifiee });
      await rendre();
    }, `Page : ${STATUTS_CMS[b.dataset.statut] || b.dataset.statut}.`);
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-03 · Catalogue, tarifs et taux
   -------------------------------------------------------------------------- */
async function pageParametres() {
  await ouvrir('parametres', 'ADM-03');
  const ecrit = peut('ADM-03', 'E');
  const valide = peut('ADM-03', 'V');
  const zone = $('[data-bo-contenu]');
  const pct = (v) => (v === null || v === undefined ? '—' : `${String(v).replace('.', ',')} %`);
  const rendre = async () => {
    const [formules, frais, grilles, usure, banque] = await Promise.all([lire('formules', { ordre: 'ordre', croissant: true }), lire('frais', { ordre: 'code', croissant: true }),
      lire('grilles_credit', { ordre: 'montant_min', croissant: true }), lire('taux_usure', { ordre: 'valable_du', croissant: false }), lire('parametres_banque', { ordre: 'cle', croissant: true })]);
    const auj = new Date().toISOString().slice(0, 10);
    zone.innerHTML = `<h1 class="gmb-section__titre" id="titre-page">Catalogue, tarifs et taux</h1>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-formules"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-formules">Formules</h2>
        <p>Toute hausse de prix doit être annoncée aux clients au moins deux mois avant son entrée en vigueur.</p>
        ${tableau('Formules', ['Formule', 'Profil', 'Prix mensuel', 'Action'], formules.map((f) => [e(f.nom), e(f.segment), `${formaterMontant(f.prix_mensuel)}${f.prix_ht ? ' HT' : ''}`,
          valide ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-formule="${e(f.code)}" data-prix="${e(f.prix_mensuel)}">Modifier le prix</button>` : '—']))}</section>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-frais"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-frais">Frais</h2>
        ${tableau('Frais', ['Frais', 'Montant', 'Pourcentage', 'Action'], frais.map((f) => [`${e(f.libelle)}<br><small>${e(f.code)}</small>`, f.montant !== null ? formaterMontant(f.montant) : '—', pct(f.pourcentage),
          ecrit ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-frais="${e(f.code)}" data-montant="${e(f.montant ?? '')}" data-pourcentage="${e(f.pourcentage ?? '')}">Modifier</button>` : '—']))}</section>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-grilles"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-grilles">Grilles de crédit</h2>
        <p>Un taux modifié n’est appliqué qu’après validation par la conformité, par une autre personne que son auteur.</p>
        ${tableau('Grilles de crédit', ['Produit', 'Montants', 'Durées', 'Taux débiteur', 'Usure', 'Validation', 'Actions'], grilles.map((g) => {
          const u = usure.find((x) => x.categorie === g.categorie_usure && x.valable_du <= auj && x.valable_au >= auj);
          return [`${e(g.produit)}${g.objet ? ` · ${e(g.objet)}` : ''}`, `${formaterMontant(g.montant_min, { decimales: 0 })} à ${formaterMontant(g.montant_max, { decimales: 0 })}`, `${e(g.duree_min)} à ${e(g.duree_max)} mois`, pct(g.taux_debiteur),
            u ? pct(u.taux) : badge('Aucun taux en vigueur', 'danger'), g.valide_conformite ? badge('Validée', 'succes') : badge('À valider', 'danger'),
            `${ecrit ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-grille="${g.id}" data-taux="${e(g.taux_debiteur)}">Modifier le taux</button>` : ''}
             ${!g.valide_conformite && valide ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-valider-grille="${g.id}">Valider</button>` : ''}`];
        }))}</section>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-usure"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-usure">Taux d’usure</h2>
        ${valide ? '<p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-ajouter-usure>Enregistrer un taux publié</button></p>' : ''}
        ${tableau('Taux d’usure', ['Catégorie', 'Taux', 'Période', 'Source'], usure.map((u) => [e(u.categorie), pct(u.taux), `du ${date(u.valable_du)} au ${date(u.valable_au)}`, e(u.source || '—')]), 'Aucun taux d’usure enregistré.')}</section>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-banque"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-banque">Paramètres de la banque</h2>
        ${tableau('Paramètres de la banque', ['Paramètre', 'Valeur', 'Modifié le'], banque.map((x) => [e(x.libelle || x.cle), e(x.valeur), date(x.modifie_le)]), 'Aucun paramètre.')}
        <p class="bo-vide">Le compte de réception des virements se règle dans <a href="${page('tresorerie')}">Trésorerie</a>.</p></section>`;
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    const motif = { nom: 'motif', libelle: 'Motif (tracé au journal d’audit)', type: 'textarea', requis: true };
    if (b.dataset.formule) executer(b, async () => {
      const r = await demander('Modifier le prix de la formule', [{ nom: 'prix', libelle: 'Nouveau prix mensuel (€)', type: 'number', valeur: b.dataset.prix, requis: true }, motif]);
      if (!r) return;
      await appeler('gmb_bo_formule_prix', { p_code: b.dataset.formule, p_prix: r.prix, p_motif: r.motif });
      await rendre();
    }, 'Prix modifié et historisé. Pensez au préavis de deux mois aux clients.');
    if (b.dataset.frais) executer(b, async () => {
      const r = await demander('Modifier le frais', [{ nom: 'montant', libelle: 'Montant (€), vide si sans objet', type: 'number', valeur: b.dataset.montant }, { nom: 'pourcentage', libelle: 'Pourcentage, vide si sans objet', type: 'number', valeur: b.dataset.pourcentage }, motif]);
      if (!r) return;
      await appeler('gmb_bo_frais_modifier', { p_code: b.dataset.frais, p_montant: r.montant, p_pourcentage: r.pourcentage, p_motif: r.motif });
      await rendre();
    }, 'Frais modifié.');
    if (b.dataset.grille) executer(b, async () => {
      const r = await demander('Modifier le taux débiteur', [{ nom: 'taux', libelle: 'Nouveau taux débiteur (%)', type: 'number', valeur: b.dataset.taux, requis: true }, motif]);
      if (!r) return;
      await appeler('gmb_bo_grille_credit_taux', { p_id: b.dataset.grille, p_taux: r.taux, p_motif: r.motif });
      await rendre();
    }, 'Taux modifié : il attend la validation de la conformité.');
    if (b.dataset.validerGrille) executer(b, async () => { await appeler('gmb_bo_grille_credit_valider', { p_id: b.dataset.validerGrille }); await rendre(); }, 'Grille validée : le taux s’applique aux nouvelles offres.');
    if (b.hasAttribute('data-ajouter-usure')) executer(b, async () => {
      const r = await demander('Enregistrer un taux d’usure publié', [{ nom: 'categorie', libelle: 'Catégorie', options: [['conso_moins_3000', 'Prêts de moins de 3 000 €'], ['conso_3000_6000', 'Prêts de 3 000 € à 6 000 €'], ['conso_plus_6000', 'Prêts de plus de 6 000 €']] },
        { nom: 'taux', libelle: 'Taux publié (%)', type: 'number', requis: true }, { nom: 'du', libelle: 'Valable du', type: 'date', requis: true }, { nom: 'au', libelle: 'Valable au', type: 'date', requis: true }, { nom: 'source', libelle: 'Source', valeur: 'Banque de France' }]);
      if (!r) return;
      await appeler('gmb_bo_taux_usure_ajouter', { p_categorie: r.categorie, p_taux: r.taux, p_du: r.du, p_au: r.au, p_source: r.source || null });
      await rendre();
    }, 'Taux d’usure enregistré.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-12 · Sécurité : paramètres, état des services, incidents (DORA)
   -------------------------------------------------------------------------- */
const ETATS_SERVICE = [['operationnel', 'Opérationnel'], ['degrade', 'Dégradé'], ['panne', 'En panne'], ['maintenance', 'En maintenance']];
async function pageSecurite() {
  await ouvrir('securite', 'ADM-12');
  const ecrit = peut('ADM-12', 'E');
  const zone = $('[data-bo-contenu]');
  const rendre = async () => {
    const [params, services, incidents] = await Promise.all([lire('parametres_securite', { ordre: 'cle', croissant: true }), lire('statut_services', { ordre: 'service', croissant: true }), lire('incidents', { ordre: 'detecte_le', croissant: false, limite: 50 })]);
    zone.innerHTML = `<h1 class="gmb-section__titre" id="titre-page">Sécurité</h1>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-services"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-services">État des services</h2><p>Affiché sur la page publique d’état des services.</p>
        ${tableau('État des services', ['Service', 'État', 'Message', 'Mis à jour', 'Action'], services.map((s) => [e(s.libelle || s.service), badge(Object.fromEntries(ETATS_SERVICE)[s.etat] || s.etat, s.etat === 'operationnel' ? 'succes' : 'danger'), e(s.message || '—'), date(s.maj_le, 'long'),
          ecrit ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-service="${e(s.service)}">Changer l’état</button>` : '—']))}</section>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-incidents"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-incidents">Incidents</h2>
        <p>Un incident majeur doit être notifié à l’autorité dans les 4 heures, avec un rapport intermédiaire et un rapport final (règlement DORA).</p>
        ${ecrit ? '<p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-declarer>Déclarer un incident</button></p>' : ''}
        ${tableau('Incidents', ['Incident', 'Classification', 'Statut', 'Échéances', 'Action'], incidents.map((i) => [`${e(i.titre)}<br><small>${e((i.services || []).join(', '))}${i.public ? ' · affiché au public' : ''}</small>`, badge(i.classification, i.classification === 'majeur' ? 'danger' : 'neutre'), badge(i.statut),
          i.notif_initiale_avant ? `notification ${date(i.notif_initiale_avant, 'long')}<br>intermédiaire ${date(i.rapport_intermediaire_avant, 'long')}<br>final ${date(i.rapport_final_avant)}` : '—',
          ecrit && i.statut !== 'clos' ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-incident="${i.id}">Changer le statut</button>` : '—']), 'Aucun incident.')}</section>
      <section class="gmb-pile gmb-pile--moyenne" aria-labelledby="t-params"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-params">Paramètres de sécurité</h2>
        ${tableau('Paramètres de sécurité', ['Paramètre', 'Valeur', 'Bornes', 'Action'], params.map((p) => [e(p.description || p.cle), `${e(p.valeur)} ${e(p.unite || '')}`, `${e(p.valeur_min)} à ${e(p.valeur_max)}`,
          ecrit && p.modifiable ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-parametre="${e(p.cle)}" data-valeur="${e(p.valeur)}" data-min="${e(p.valeur_min)}" data-max="${e(p.valeur_max)}">Modifier</button>` : (p.modifiable ? '—' : 'Réglementaire')]))}</section>`;
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.service) executer(b, async () => {
      const r = await demander('Changer l’état du service', [{ nom: 'etat', libelle: 'État', options: ETATS_SERVICE }, { nom: 'message', libelle: 'Message affiché au public (facultatif)', type: 'textarea' }]);
      if (!r) return;
      await appeler('gmb_bo_service_etat', { p_service: b.dataset.service, p_etat: r.etat, p_message: r.message || null });
      await rendre();
    }, 'État du service mis à jour.');
    if (b.hasAttribute('data-declarer')) executer(b, async () => {
      const r = await demander('Déclarer un incident', [{ nom: 'titre', libelle: 'Titre', requis: true }, { nom: 'description', libelle: 'Description', type: 'textarea' },
        { nom: 'classification', libelle: 'Classification', options: [['mineur', 'Mineur'], ['significatif', 'Significatif'], ['majeur', 'Majeur (notification sous 4 heures)']] },
        { nom: 'services', libelle: 'Services touchés (séparés par des virgules)' }, { nom: 'public', libelle: 'Affichage', options: [['non', 'Interne'], ['oui', 'Affiché sur la page publique']] }], { valider: 'Déclarer' });
      if (!r) return;
      await appeler('gmb_bo_incident_declarer', { p_titre: r.titre, p_description: r.description || null, p_classification: r.classification, p_services: r.services ? r.services.split(',').map((s) => s.trim()).filter(Boolean) : [], p_public: r.public === 'oui' });
      await rendre();
    }, 'Incident déclaré.');
    if (b.dataset.incident) executer(b, async () => {
      const r = await demander('Changer le statut de l’incident', [{ nom: 'statut', libelle: 'Statut', options: [['en_cours', 'En cours de traitement'], ['resolu', 'Résolu'], ['clos', 'Clos'], ['ouvert', 'Ouvert']] }]);
      if (!r) return;
      await appeler('gmb_bo_incident_statut', { p_incident: b.dataset.incident, p_statut: r.statut });
      await rendre();
    }, 'Statut de l’incident mis à jour.');
    if (b.dataset.parametre) executer(b, async () => {
      const r = await demander('Modifier le paramètre', [{ nom: 'valeur', libelle: `Nouvelle valeur (de ${b.dataset.min} à ${b.dataset.max})`, type: 'number', valeur: b.dataset.valeur, requis: true }, { nom: 'motif', libelle: 'Motif (tracé au journal d’audit)', type: 'textarea', requis: true }]);
      if (!r) return;
      if (r.valeur < Number(b.dataset.min) || r.valeur > Number(b.dataset.max)) throw new ErreurGmb(`La valeur doit être comprise entre ${b.dataset.min} et ${b.dataset.max}.`);
      await appeler('gmb_bo_parametre_modifier', { p_cle: b.dataset.parametre, p_valeur: r.valeur, p_motif: r.motif });
      await rendre();
    }, 'Paramètre modifié.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-13 · Collaborateurs : rôles et activation
   -------------------------------------------------------------------------- */
async function pageCollaborateurs() {
  const ctx = await ouvrir('collaborateurs', 'ADM-13');
  const gere = peut('ADM-13', 'V');
  const zone = $('[data-liste]');
  const rendre = async () => {
    const [collaborateurs, roles, attributions] = await Promise.all([lire('collaborateurs', { ordre: 'nom', croissant: true }), lire('roles_bo', { ordre: 'libelle', croissant: true }), lire('collaborateur_roles')]);
    const libelles = Object.fromEntries(roles.map((r) => [r.code, r.libelle]));
    zone.innerHTML = tableau('Collaborateurs', ['Collaborateur', 'Rôles', 'Statut', 'Actions'], collaborateurs.map((c) => {
      const soi = c.id === ctx.uid;
      const siens = attributions.filter((a) => a.collaborateur_id === c.id).map((a) => a.role_code);
      return [`${e(c.nom)}<br><small>${e(c.email)}</small>${soi ? ' ' + badge('Vous') : ''}`,
        siens.map((r) => `${badge(libelles[r] || r)}${gere && !soi ? ` <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-retirer="${c.id}" data-role="${e(r)}" aria-label="Retirer le rôle ${e(libelles[r] || r)} à ${e(c.nom)}">Retirer</button>` : ''}`).join('<br>') || '—',
        badge(c.actif ? 'Actif' : 'Désactivé', c.actif ? 'succes' : 'danger'),
        gere && !soi ? `<button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-ajouter="${c.id}" data-roles="${e(siens.join(','))}">Ajouter un rôle</button>
          <button type="button" class="gmb-bouton gmb-bouton--${c.actif ? 'danger' : 'secondaire'} gmb-bouton--petit" data-actif="${c.id}" data-valeur="${c.actif ? 'false' : 'true'}">${c.actif ? 'Désactiver' : 'Réactiver'}</button>` : '—'];
    }));
    zone.dataset.roles = JSON.stringify(roles.map((r) => [r.code, r.libelle]));
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.ajouter) executer(b, async () => {
      const deja = (b.dataset.roles || '').split(',');
      const options = JSON.parse(zone.dataset.roles).filter(([code]) => !deja.includes(code));
      if (!options.length) throw new ErreurGmb('Ce collaborateur a déjà tous les rôles.');
      const r = await demander('Ajouter un rôle', [{ nom: 'role', libelle: 'Rôle', options }], { valider: 'Ajouter' });
      if (!r) return;
      await appeler('gmb_bo_collaborateur_role', { p_collaborateur: b.dataset.ajouter, p_role: r.role, p_attribuer: true });
      await rendre();
    }, 'Rôle ajouté.');
    if (b.dataset.retirer) executer(b, async () => { await appeler('gmb_bo_collaborateur_role', { p_collaborateur: b.dataset.retirer, p_role: b.dataset.role, p_attribuer: false }); await rendre(); }, 'Rôle retiré.');
    if (b.dataset.actif) executer(b, async () => { await appeler('gmb_bo_collaborateur_actif', { p_collaborateur: b.dataset.actif, p_actif: b.dataset.valeur === 'true' }); await rendre(); }, 'Accès du collaborateur modifié.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   ADM-14 · Journal d'audit
   -------------------------------------------------------------------------- */
async function pageAudit() {
  await ouvrir('audit', 'ADM-14');
  const zone = $('[data-liste]');
  const form = $('[data-form="filtre"]');
  const [journal, collaborateurs] = await Promise.all([lire('journal_audit', { ordre: 'horodatage', croissant: false, limite: 500 }), lire('collaborateurs', { colonnes: 'id, nom' })]);
  const noms = Object.fromEntries(collaborateurs.map((c) => [c.id, c.nom]));
  const rendre = () => {
    const t = form.elements.texte.value.trim().toLowerCase();
    const lignes = journal.filter((j) => !t || [j.action, j.objet_type, j.objet_id, j.motif, noms[j.acteur_id]].some((v) => String(v || '').toLowerCase().includes(t)));
    zone.innerHTML = tableau('Journal d’audit (500 dernières entrées)', ['Horodatage', 'Acteur', 'Action', 'Objet', 'Motif', 'Empreinte'], lignes.map((j) => [date(j.horodatage, 'long'),
      e(noms[j.acteur_id] || j.acteur_type), e(j.action), e(`${j.objet_type || ''} ${j.objet_id || ''}`.trim() || '—'), e(j.motif || '—'), `<code>${e(String(j.empreinte || '').slice(0, 12))}</code>`]), 'Aucune entrée.');
  };
  form.addEventListener('input', rendre);
  form.addEventListener('submit', (x) => x.preventDefault());
  rendre();
}

/* -----------------------------------------------------------------------------
   Démarrage
   -------------------------------------------------------------------------- */
document.addEventListener('submit', (x) => x.preventDefault());
export const CONTROLEURS = {
  connexion: pageConnexion, index: pageTableau, dossiers: pageDossiers, dossier: pageDossier, kyc: pageKyc, credit: pageCredit, tresorerie: pageTresorerie,
  'lcb-ft': pageLcbft, fraude: pageFraude, clients: pageClients, reclamations: pageReclamations, operations: pageOperations, cms: pageCms,
  parametres: pageParametres, securite: pageSecurite, collaborateurs: pageCollaborateurs, audit: pageAudit,
};
export { ouvrir, peut, tableau, badge, demander, executer, message, date, e, page, personnesDe, ETATS };
async function demarrer() {
  const controleur = CONTROLEURS[document.body.dataset.bo];
  if (!controleur) return;
  try { await controleur(); } catch (x) { if (!/Session absente|Accès refusé/.test(x?.message)) message(messageErreur(x)); }
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrer, { once: true });
else demarrer();
