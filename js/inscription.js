/* =============================================================================
   GerMoonBank (GMB) · js/inscription.js
   Ouverture de compte et demande de prêt — version 4 (2026-10-07)
   -----------------------------------------------------------------------------
   Huit pages (public/inscription/), cinq parcours :
     Particulier, Pro, Business, Jeunes (le parent ouvre son compte et celui de
     son enfant de 10 à 17 ans) et prêt personnel.
   Chaque étape est enregistrée dans la base par ses fonctions contrôlées
   (gmb_dossier_*) : on peut quitter et reprendre à tout moment. Le dossier en
   cours est désigné par le paramètre ?dossier= de l'adresse.
   ========================================================================== */

import { chemin, formaterMontant, formaterDate, formaterIban, echapperHtml, icone, FORMULES, FORMULES_PRO, CREDIT } from './core.js';
import {
  client, session, appeler, lire, deposerFichier, messageErreur, ErreurGmb, oublierContexte, espaceDe,
  ARRIVEE_PAR_LIEN, limiteEmail, attenteEmail, brancherRenvoi, memoriserAppareilDossier, messageDejaParti,
} from './donnees.js';
import {
  analyserMotDePasse, motDePasseDivulgue, brancherMotDePasse, controlerFichier, justificatifTropAncien, empreinteFichier,
  occupe, afficherMessage, copier, defilerVers, erreurChamp, age, normaliserTelephone, masquerEmail,
} from './forms.js';

const VERSION_TEXTES = 'v1.0-2026-10';
const CLE_ATTENTE = 'gmb-inscription-attente'; // choix faits avant la confirmation de l'adresse (aucune donnée personnelle)
const ETAPES = ['etape-1-identite', 'etape-2-coordonnees', 'etape-3-situation', 'etape-4-documents', 'etape-5-signature', 'etape-6-validation'];
const LIBELLES_PIECES = Object.freeze({
  piece_identite: ['Pièce d’identité', 'Carte d’identité, passeport ou titre de séjour en cours de validité, recto et verso.'],
  selfie: ['Selfie', 'Une photo de votre visage, de face, bien éclairée, sans lunettes de soleil.'],
  justificatif_domicile: ['Justificatif de domicile', 'Facture d’énergie, d’internet ou avis d’imposition de moins de 3 mois, à votre nom.'],
  justificatif_revenus: ['Justificatif de revenus', 'Vos trois derniers bulletins de salaire, ou votre dernier avis d’imposition.'],
  kbis: ['Justificatif d’immatriculation', 'Extrait Kbis, avis de situation au répertoire SIRENE ou extrait du registre national des entreprises, de moins de 3 mois.'],
  statuts: ['Statuts de la société', 'Les statuts à jour, signés.'],
  beneficiaires_effectifs: ['Bénéficiaires effectifs', 'La déclaration des bénéficiaires effectifs déposée au greffe.'],
  lien_filiation: ['Preuve du lien avec l’enfant', 'Livret de famille ou acte de naissance de l’enfant, ou jugement désignant le tuteur.'],
});
const DATEES = new Set(['justificatif_domicile', 'justificatif_revenus', 'kbis']);

/* -----------------------------------------------------------------------------
   Outils communs
   -------------------------------------------------------------------------- */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const valeur = (form, nom) => {
  const el = form.elements[nom];
  if (!el) return '';
  if (el instanceof RadioNodeList) return el.value;
  if (el.type === 'checkbox') return el.checked;
  return String(el.value || '').trim();
};
const nombre = (texte) => { const n = Number(String(texte || '').replace(/\s/g, '').replace(',', '.')); return Number.isFinite(n) ? n : null; };
const page = (nom, dossier, extra = '') => chemin(`public/inscription/${nom}.html${dossier ? `?dossier=${encodeURIComponent(dossier)}${extra}` : extra}`);
const parametre = (nom) => new URLSearchParams(location.search).get(nom);

function message(texte, type = 'erreur') {
  const bloc = $('[data-message]');
  afficherMessage(bloc, texte, type);
  if (texte) defilerVers(bloc);
}

async function executer(bouton, action) {
  message('');
  occupe(bouton, true);
  try {
    await action();
  } catch (erreur) {
    message(messageErreur(erreur));
  } finally {
    occupe(bouton, false);
  }
}

function valider(form, regles) {
  let premier = null;
  for (const [nom, regle] of Object.entries(regles)) {
    const champ = form.elements[nom];
    const texte = regle(valeur(form, nom), form);
    const el = champ instanceof RadioNodeList ? champ[0] : champ;
    if (!erreurChamp(el, texte || '') && !premier) premier = el;
  }
  if (premier) { premier.focus(); throw new ErreurGmb('Certaines informations sont à compléter ou à corriger.'); }
}
const requis = (libelle) => (v) => (v ? '' : `Indiquez ${libelle}.`);

/** Dossier de l'adresse, vérifié (il doit appartenir à la personne connectée). */
async function dossierCourant({ modifiable = true } = {}) {
  const s = await session();
  if (!s || espaceDe(s) !== 'dossier') {
    location.replace(chemin(`auth/mon-dossier.html?raison=session&retour=${encodeURIComponent(location.pathname + location.search)}`));
    throw new ErreurGmb('Session absente');
  }
  const id = parametre('dossier');
  const d = id ? await lire('dossiers', { colonnes: 'id, reference, type, segment, formule_code, etat, personne_id', egal: { id }, unique: true }) : null;
  if (!d) { location.replace(page('index')); throw new ErreurGmb('Dossier introuvable'); }
  if (modifiable && !['brouillon', 'incomplet'].includes(d.etat)) { location.replace(page('confirmation', d.id)); throw new ErreurGmb('Dossier déposé'); }
  return d;
}

/** Libellés de la frise et du titre selon le parcours. */
function adapterFrise(d) {
  const etape3 = d.type === 'credit' ? 'Vos revenus' : { pro: 'Votre activité', business: 'Votre entreprise', jeunes: 'Votre enfant' }[d.segment] || 'Votre situation';
  const etape6 = d.type === 'credit' ? 'Dépôt de la demande' : 'Premier versement';
  $$('[data-frise-etape="3"]').forEach((el) => { el.textContent = etape3; });
  $$('[data-frise-etape="6"]').forEach((el) => { el.textContent = etape6; });
  $$('[data-reference]').forEach((el) => { el.textContent = d.reference; });
  $$('[data-si-segment]').forEach((el) => { el.hidden = !el.dataset.siSegment.split(' ').includes(d.type === 'credit' ? 'credit' : d.segment); });
}

/** Première étape à compléter d'une demande en cours (identité, coordonnées, situation,
 *  documents, signature, puis premier versement). */
async function etapeDeReprise(d) {
  const p = d.personne_id ? await lire('personnes', { egal: { id: d.personne_id }, unique: true }) : null;
  if (!p?.civilite || !p?.nom_naissance || !p?.prenoms || !p?.date_naissance || !p?.lieu_naissance) return ETAPES[0];
  if (!p.telephone || !p.adresse_ligne1 || !p.code_postal || !p.ville || p.personne_us === null || p.ppe_declaree === null) return ETAPES[1];
  if (['pro', 'business'].includes(d.segment)) {
    if (!(await lire('dossier_entreprises', { colonnes: 'dossier_id', egal: { dossier_id: d.id }, unique: true }))) return ETAPES[2];
  } else if (!p.profession) return ETAPES[2];
  if (d.segment === 'jeunes' && !(await lire('dossier_jeunes', { colonnes: 'dossier_id', egal: { dossier_id: d.id }, unique: true }))) return ETAPES[2];
  const projet = await lire('dossier_credit', { colonnes: 'revenus_mensuels', egal: { dossier_id: d.id }, unique: true });
  if (projet && projet.revenus_mensuels === null) return ETAPES[2];
  const pieces = await lire('dossier_pieces', { colonnes: 'statut', egal: { dossier_id: d.id } });
  if (pieces.some((x) => ['attendue', 'refusee'].includes(x.statut))) return ETAPES[3];
  const signature = await lire('consentements', { colonnes: 'type', egal: { type: 'signature_convention', accorde: true }, depuis: { horodatage: d.created_at }, limite: 1 });
  if (!signature.length) return ETAPES[4];
  return ETAPES[5];
}

function suivante(d) {
  const i = ETAPES.indexOf(document.body.dataset.etape);
  location.href = page(ETAPES[i + 1] || 'confirmation', d.id);
}

function remplir(form, objet) {
  if (!objet) return;
  for (const [cle, v] of Object.entries(objet)) {
    const el = form.elements[cle];
    if (!el || v === null || v === undefined) continue;
    if (el instanceof RadioNodeList) { [...el].forEach((r) => { r.checked = String(r.value) === String(v); }); continue; }
    if (el.type === 'checkbox') el.checked = Boolean(v);
    else el.value = v;
  }
}

/* -----------------------------------------------------------------------------
   Page 0 — Commencer : profil, formule, accès à l'Espace Mon Dossier
   -------------------------------------------------------------------------- */
async function pageIndex() {
  const form = $('[data-form="commencer"]');
  const credit = parametre('produit') === 'pret_personnel';
  const blocCredit = $('[data-bloc="credit"]');
  const blocProfil = $('[data-bloc="profil"]');
  blocCredit.hidden = !credit;
  blocProfil.hidden = false;
  // Prêt : le compte est ouvert dans la même demande (particulier, formule au choix)
  form.elements.segment[0].closest('fieldset').hidden = credit;
  if (credit) remplir(form, { segment: 'particulier' });
  if (parametre('raison') === 'enregistre') message('Votre demande est enregistrée. Reconnectez-vous à l’Espace Mon Dossier pour la reprendre.', 'info');

  // Projet de prêt : montant, durée, objet (repris du simulateur)
  if (credit) {
    remplir(form, { montant: parametre('montant') || CREDIT.exemple.montant, duree: parametre('duree') || CREDIT.exemple.duree, objet: parametre('objet') || 'autre' });
    form.elements.objet.innerHTML = CREDIT.objets.map((o) => `<option value="${o.code}">${echapperHtml(o.libelle)}</option>`).join('');
    form.elements.objet.value = parametre('objet') || 'autre';
  }

  // Formules selon le profil
  const remplirFormules = () => {
    const segment = valeur(form, 'segment') || 'particulier';
    const liste = ['pro', 'business'].includes(segment) ? FORMULES_PRO.filter((f) => f.segment === segment) : FORMULES;
    const actuelle = form.elements.formule.value;
    form.elements.formule.innerHTML = liste.map((f) => `<option value="${f.code}">${echapperHtml(f.nom)} · ${f.prixHT !== undefined ? `${formaterMontant(f.prixHT)} HT` : formaterMontant(f.prix)} par mois</option>`).join('');
    if (liste.some((f) => f.code === actuelle)) form.elements.formule.value = actuelle;
    $$('[data-aide-segment]').forEach((el) => { el.hidden = el.dataset.aideSegment !== segment; });
  };
  const segmentDemande = parametre('segment');
  if (['particulier', 'pro', 'business', 'jeunes'].includes(segmentDemande)) remplir(form, { segment: segmentDemande });
  remplirFormules();
  if (parametre('formule')) form.elements.formule.value = parametre('formule');
  form.addEventListener('change', (e) => { if (e.target.name === 'segment') remplirFormules(); });

  // Lien de confirmation reçu par e-mail : invalide, expiré ou déjà utilisé
  if (ARRIVEE_PAR_LIEN?.erreur) {
    message('Ce lien n’est plus valable : il a expiré ou il a déjà servi. Saisissez votre adresse e-mail et votre mot de passe ci-dessous pour recevoir un nouveau code.', 'info');
  }

  // Accès : déjà connecté, ou création de l'accès
  const s = await session();
  const connecte = Boolean(s && espaceDe(s) === 'dossier');
  // L'adresse vient d'être confirmée depuis cet appareil (lien reçu par e-mail) : il est de confiance
  if (connecte && ARRIVEE_PAR_LIEN && !ARRIVEE_PAR_LIEN.erreur) memoriserAppareilDossier(s.user.id);

  // Reprise d'une demande, à sa première étape incomplète
  const aReprendre = parametre('reprendre');
  if (aReprendre) {
    if (!connecte) { location.replace(chemin(`auth/mon-dossier.html?retour=${encodeURIComponent(location.href)}`)); return; }
    const d = await lire('dossiers', { colonnes: 'id, reference, type, segment, etat, personne_id, created_at', egal: { id: aReprendre }, unique: true });
    if (d && ['brouillon', 'incomplet'].includes(d.etat)) { location.replace(page(await etapeDeReprise(d), d.id)); return; }
    if (d) { location.replace(page('confirmation', d.id)); return; }
  }

  $('[data-bloc="acces"]').hidden = connecte;
  $('[data-bloc="connecte"]').hidden = !connecte;
  if (connecte) {
    $('[data-email-connecte]').textContent = masquerEmail(s.user.email);
    const enCours = await lire('dossiers', { colonnes: 'id, reference, type, segment, etat', dans: { etat: ['brouillon', 'incomplet'] }, ordre: 'created_at', limite: 1 });
    if (enCours.length) {
      const zone = $('[data-bloc="reprendre"]');
      zone.hidden = false;
      zone.querySelector('[data-lien-reprendre]').href = chemin(`public/inscription/index.html?reprendre=${enCours[0].id}`);
      zone.querySelector('[data-reference-reprendre]').textContent = enCours[0].reference;
    }
  } else {
    brancherMotDePasse({ champ: form.elements.mdp, champEmail: form.elements.email, jauge: $('[data-jauge]'), controles: $('[data-regles]'), bouton: $('[data-afficher-mdp]') });
  }

  /** Choix de la page (profil, formule, projet de prêt, accords). Ils sont gardés sur l'appareil
   *  pendant la confirmation de l'adresse : si elle se fait par un lien, la demande est créée au retour. */
  const lireChoix = () => ({
    segment: credit ? 'particulier' : (valeur(form, 'segment') || 'particulier'),
    formule: form.elements.formule.value,
    projet: credit ? { montant: nombre(valeur(form, 'montant')), duree: Math.round(nombre(valeur(form, 'duree'))), objet: valeur(form, 'objet') } : null,
    accords: { cgu: true, confidentialite: true, marketing: Boolean(valeur(form, 'marketing')) },
    quand: Date.now(),
  });
  const lireAttente = () => {
    try {
      const a = JSON.parse(localStorage.getItem(CLE_ATTENTE) || 'null');
      return a && Date.now() - a.quand < 24 * 3600e3 ? a : null;
    } catch { return null; }
  };

  async function creerDossier(choix = lireChoix()) {
    oublierContexte();
    const r = await appeler('gmb_dossier_creer', { p_type: 'ouverture', p_segment: choix.segment, p_formule: choix.formule });
    const dossier = r.dossier;
    if (choix.projet) {
      await appeler('gmb_dossier_credit_projet', { p_dossier: dossier, p_montant: choix.projet.montant, p_duree: choix.projet.duree, p_objet: choix.projet.objet });
    }
    for (const [type, accorde] of Object.entries(choix.accords || { cgu: true, confidentialite: true, marketing: false })) {
      await appeler('gmb_dossier_consentir', { p_dossier: dossier, p_type: type, p_version: VERSION_TEXTES, p_accorde: Boolean(accorde) });
    }
    try { localStorage.removeItem(CLE_ATTENTE); } catch { /* stockage indisponible */ }
    // Une demande déjà commencée est reprise là où elle en était
    if (r.repris) {
      const d = await lire('dossiers', { colonnes: 'id, reference, type, segment, etat, personne_id, created_at', egal: { id: dossier }, unique: true });
      location.href = page(d ? await etapeDeReprise(d) : ETAPES[0], dossier);
      return;
    }
    location.href = page(ETAPES[0], dossier);
  }

  // Retour du lien de confirmation : la demande préparée avant l'envoi de l'e-mail est créée aussitôt
  if (connecte && (ARRIVEE_PAR_LIEN || parametre('confirmation')) && lireAttente()) {
    try { await creerDossier(lireAttente()); return; } catch (erreur) { message(messageErreur(erreur)); }
  }

  /* --- Création de l'accès : un code à 6 chiffres confirme l'adresse e-mail ---
     Trois situations, traitées de la même façon à l'écran (rien n'indique si l'adresse est déjà connue) :
       adresse nouvelle, ou jamais confirmée   → e-mail de confirmation (code) ;
       adresse qui a déjà un accès             → e-mail de connexion (code) : Supabase n'envoie
                                                  aucune confirmation dans ce cas, d'où ce second envoi ;
       confirmation désactivée dans Supabase   → session ouverte immédiatement. */
  const formCode = $('[data-form="code"]');
  const acces = { email: '', mdp: '', mode: 'signup' };
  let essais = 0;

  async function envoyerCode({ premierEnvoi = false } = {}) {
    const c = await client();
    const { data, error } = await c.auth.signUp({ email: acces.email, password: acces.mdp, options: { emailRedirectTo: chemin('public/inscription/index.html?confirmation=1') } });
    const dejaInscrite = error?.code === 'user_already_exists' || /already registered/i.test(error?.message || '')
      || (!error && data?.user && Array.isArray(data.user.identities) && data.user.identities.length === 0);
    if (data?.session) return { mode: 'session' };
    // Un e-mail déjà parti il y a moins d'une minute : au premier envoi, la personne saisit ce code-là
    const dejaParti = (e) => premierEnvoi && limiteEmail(e) && attenteEmail(e) !== null;
    if (!dejaInscrite) {
      if (error && !dejaParti(error)) throw error;
      return { mode: 'signup', attente: error ? attenteEmail(error) : null };
    }
    const connexion = await c.auth.signInWithOtp({ email: acces.email, options: { shouldCreateUser: false, emailRedirectTo: chemin('public/inscription/index.html?confirmation=1') } });
    if (connexion.error && !dejaParti(connexion.error)) throw connexion.error;
    return { mode: 'email', attente: connexion.error ? attenteEmail(connexion.error) : null };
  }

  /** L'adresse est confirmée : le mot de passe saisi devient celui de l'accès, l'appareil est de confiance. */
  async function accesConfirme() {
    const c = await client();
    const { data } = await c.auth.getSession();
    if (!data?.session || espaceDe(data.session) !== 'dossier') {
      await c.auth.signOut({ scope: 'local' }).catch(() => {});
      throw new ErreurGmb('Cette adresse e-mail sert déjà à un autre espace de GerMoonBank. Utilisez une autre adresse pour votre demande.');
    }
    if (acces.mdp && acces.mode !== 'session') {
      const { error } = await c.auth.updateUser({ password: acces.mdp });
      if (error && error.code !== 'same_password') console.error('[GMB] mot de passe non mis à jour', error);
    }
    acces.mdp = '';
    memoriserAppareilDossier(data.session.user.id);
    await creerDossier(lireAttente() || lireChoix());
  }

  const renvoi = brancherRenvoi($('[data-renvoyer-code]'), async () => {
    if (!acces.mdp) throw new ErreurGmb('Par sécurité, votre mot de passe n’est plus en mémoire : rechargez la page et recommencez.');
    const r = await envoyerCode();
    if (r.mode === 'session') { await accesConfirme(); return; }
    acces.mode = r.mode;
    essais = 0;
  }, { message });

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      if (credit) {
        valider(form, {
          montant: (v) => { const n = nombre(v); return n >= CREDIT.montantMin && n <= CREDIT.montantMax ? '' : `Choisissez un montant de ${formaterMontant(CREDIT.montantMin, { decimales: 0 })} à ${formaterMontant(CREDIT.montantMax, { decimales: 0 })}.`; },
          duree: (v) => { const n = nombre(v); return n >= CREDIT.dureeMin && n <= CREDIT.dureeMax ? '' : `Choisissez une durée de ${CREDIT.dureeMin} à ${CREDIT.dureeMax} mois.`; },
        });
      }
      valider(form, {
        residence: (v) => (v ? '' : 'L’ouverture en ligne est réservée aux personnes qui résident en France.'),
        majeur: (v) => (v ? '' : 'Confirmez que vous avez 18 ans ou plus.'),
      });
      if (connecte) { await creerDossier(); return; }
      const email = valeur(form, 'email').toLowerCase();
      const mdp = form.elements.mdp.value;
      valider(form, {
        email: (v) => (/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v) ? '' : 'Saisissez une adresse e-mail valide, par exemple prenom.nom@exemple.fr.'),
        cgu: (v) => (v ? '' : 'Acceptez les conditions générales pour continuer.'),
        confidentialite: (v) => (v ? '' : 'Prenez connaissance de la politique de confidentialité pour continuer.'),
      });
      const a = analyserMotDePasse(mdp, email);
      let probleme = !a.longueur ? 'Votre mot de passe doit contenir au moins 12 caractères.' : !a.sansEmail ? 'Votre mot de passe ne doit pas contenir votre adresse e-mail.' : '';
      if (!probleme && (a.connu || (await motDePasseDivulgue(mdp)) === true)) probleme = 'Ce mot de passe figure dans des fuites de données connues : choisissez-en un autre.';
      if (!erreurChamp(form.elements.mdp, probleme)) { form.elements.mdp.focus(); throw new ErreurGmb(probleme); }
      try { localStorage.setItem(CLE_ATTENTE, JSON.stringify(lireChoix())); } catch { /* stockage indisponible : les choix restent sur cette page */ }
      acces.email = email; acces.mdp = mdp;
      const envoi = await envoyerCode({ premierEnvoi: true });
      form.elements.mdp.value = '';
      acces.mode = envoi.mode;
      if (envoi.mode === 'session') { await accesConfirme(); return; }
      formCode.hidden = false;
      form.hidden = true;
      $('[data-email-code]').textContent = masquerEmail(email);
      renvoi.demarrer(envoi.attente || 60);
      if (envoi.attente) message(messageDejaParti(envoi.attente), 'info');
      formCode.elements.code.focus();
    });
  });

  // Code reçu par e-mail
  formCode.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(formCode.querySelector('[type="submit"]'), async () => {
      const code = valeur(formCode, 'code').replace(/\s/g, '');
      if (!/^\d{6}$/.test(code)) throw new ErreurGmb('Saisissez les 6 chiffres du code reçu par e-mail.');
      if (essais >= 5) throw new ErreurGmb('Trop d’essais. Demandez un nouveau code.');
      essais += 1;
      const c = await client();
      const types = acces.mode === 'email' ? ['email', 'signup'] : ['signup', 'email'];
      let r = await c.auth.verifyOtp({ email: acces.email, token: code, type: types[0] });
      if (r.error) r = await c.auth.verifyOtp({ email: acces.email, token: code, type: types[1] });
      if (r.error) throw new ErreurGmb(essais < 5 ? `Ce code est incorrect ou n’est plus valable. Seul le dernier code reçu fonctionne. Il vous reste ${5 - essais} essai${5 - essais > 1 ? 's' : ''}.` : 'Trop d’essais. Demandez un nouveau code.');
      await accesConfirme();
    });
  });
}

/* -----------------------------------------------------------------------------
   Page 1 — Identité (du titulaire, du dirigeant ou du parent)
   -------------------------------------------------------------------------- */
async function lirePersonne(d) {
  return d.personne_id ? lire('personnes', { egal: { id: d.personne_id }, unique: true }) : null;
}

async function pageIdentite() {
  const d = await dossierCourant(); adapterFrise(d);
  const form = $('[data-form="identite"]');
  remplir(form, await lirePersonne(d));
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      valider(form, {
        civilite: requis('votre civilité'), nom_naissance: requis('votre nom de naissance'), prenoms: requis('vos prénoms'),
        date_naissance: (v) => (!v ? 'Indiquez votre date de naissance.' : age(v) < 18 ? 'Vous devez avoir 18 ans ou plus.' : age(v) > 120 ? 'Vérifiez votre date de naissance.' : ''),
        lieu_naissance: requis('votre lieu de naissance'), pays_naissance: requis('votre pays de naissance'), nationalite: requis('votre nationalité'),
      });
      const donnees = Object.fromEntries(['civilite', 'nom_naissance', 'nom_usage', 'prenoms', 'date_naissance', 'lieu_naissance', 'pays_naissance', 'nationalite'].map((n) => [n, valeur(form, n)]));
      donnees.nom_naissance = donnees.nom_naissance.toUpperCase();
      await appeler('gmb_dossier_maj_personne', { p_dossier: d.id, p_donnees: { ...donnees, etape: 5 } });
      suivante(d);
    });
  });
}

/* -----------------------------------------------------------------------------
   Page 2 — Coordonnées et situation fiscale
   -------------------------------------------------------------------------- */
async function pageCoordonnees() {
  const d = await dossierCourant(); adapterFrise(d);
  const form = $('[data-form="coordonnees"]');
  const p = await lirePersonne(d);
  remplir(form, p ? { ...p, personne_us: p.personne_us === null ? '' : String(p.personne_us), ppe_declaree: p.ppe_declaree === null ? '' : String(p.ppe_declaree) } : null);
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      valider(form, {
        telephone: (v) => (normaliserTelephone(v) ? '' : 'Saisissez un numéro de téléphone valide, par exemple 06 12 34 56 78.'),
        adresse_ligne1: requis('votre adresse'),
        code_postal: (v) => (/^\d{5}$/.test(v) ? '' : 'Saisissez un code postal à 5 chiffres.'),
        ville: requis('votre ville'),
        residence_fiscale: requis('votre pays de résidence fiscale'),
        nif: (v, f) => (valeur(f, 'residence_fiscale') === 'FR' && !/^[0-3]\d{12}$/.test(v.replace(/\s/g, '')) ? 'Saisissez votre numéro fiscal à 13 chiffres (il figure sur votre avis d’imposition).' : ''),
        personne_us: (v) => (v ? '' : 'Indiquez si vous êtes une personne américaine au sens fiscal.'),
        ppe_declaree: (v) => (v ? '' : 'Indiquez si vous exercez ou avez exercé une fonction politique ou publique importante.'),
      });
      await appeler('gmb_dossier_maj_personne', { p_dossier: d.id, p_donnees: {
        telephone: normaliserTelephone(valeur(form, 'telephone')), adresse_ligne1: valeur(form, 'adresse_ligne1'), adresse_ligne2: valeur(form, 'adresse_ligne2'),
        code_postal: valeur(form, 'code_postal'), ville: valeur(form, 'ville'), pays: 'FR', residence_fiscale: valeur(form, 'residence_fiscale'),
        nif: valeur(form, 'nif').replace(/\s/g, ''), personne_us: valeur(form, 'personne_us') === 'true', ppe_declaree: valeur(form, 'ppe_declaree') === 'true', etape: 6,
      } });
      suivante(d);
    });
  });
}

/* -----------------------------------------------------------------------------
   Page 3 — Situation, revenus, activité, entreprise ou enfant
   -------------------------------------------------------------------------- */
function lireBeneficiaires(zone) {
  return $$('[data-beneficiaire]', zone).map((b) => ({
    nom: valeur({ elements: { v: $('[name="b_nom"]', b) } }, 'v').toUpperCase(), prenoms: $('[name="b_prenoms"]', b).value.trim(),
    date_naissance: $('[name="b_naissance"]', b).value, nationalite: $('[name="b_nationalite"]', b).value || 'FR', pourcentage: nombre($('[name="b_part"]', b).value) || 0,
  })).filter((b) => b.nom || b.prenoms);
}

function brancherBeneficiaires(zone, existants = []) {
  const modele = $('template[data-modele-beneficiaire]');
  const ajouter = (b = {}) => {
    if ($$('[data-beneficiaire]', zone).length >= 4) return;
    const n = $$('[data-beneficiaire]', zone).length + 1;
    const frag = modele.content.cloneNode(true);
    const bloc = frag.querySelector('[data-beneficiaire]');
    bloc.querySelector('[data-numero]').textContent = String(n);
    bloc.querySelectorAll('input, select').forEach((el) => { el.id = `${el.name}-${n}`; });
    bloc.querySelectorAll('label[data-pour]').forEach((l) => { l.htmlFor = `${l.dataset.pour}-${n}`; });
    $('[name="b_nom"]', bloc).value = b.nom || ''; $('[name="b_prenoms"]', bloc).value = b.prenoms || '';
    $('[name="b_naissance"]', bloc).value = b.date_naissance || ''; $('[name="b_nationalite"]', bloc).value = b.nationalite || 'FR';
    $('[name="b_part"]', bloc).value = b.pourcentage ?? '';
    bloc.querySelector('[data-retirer]').addEventListener('click', () => { bloc.remove(); });
    zone.append(frag);
  };
  (existants.length ? existants : [{}]).forEach(ajouter);
  $('[data-ajouter-beneficiaire]').addEventListener('click', () => ajouter());
}

async function pageSituation() {
  const d = await dossierCourant(); adapterFrise(d);
  const parcours = d.type === 'credit' ? 'credit' : d.segment;
  const form = $(`[data-form="situation-${parcours}"]`);
  $$('[data-form^="situation-"]').forEach((f) => { f.hidden = f !== form; });
  const p = await lirePersonne(d);
  remplir(form, p);
  const projet = parcours === 'particulier' ? await lire('dossier_credit', { egal: { dossier_id: d.id }, unique: true }) : null;
  const zoneProjet = form.querySelector('[data-si-projet]');
  if (zoneProjet) zoneProjet.hidden = !projet;
  if (projet) remplir(form, { revenus: projet.revenus_mensuels, charges: projet.charges_mensuelles });
  if (parcours === 'credit') {
    const projet = await lire('dossier_credit', { egal: { dossier_id: d.id }, unique: true });
    remplir(form, { revenus: projet?.revenus_mensuels, charges: projet?.charges_mensuelles });
  }
  if (parcours === 'pro' || parcours === 'business') {
    const e = await lire('dossier_entreprises', { egal: { dossier_id: d.id }, unique: true });
    remplir(form, e);
    if (parcours === 'business') brancherBeneficiaires($('[data-beneficiaires]', form), e?.beneficiaires || []);
  }
  if (parcours === 'jeunes') {
    const j = await lire('dossier_jeunes', { egal: { dossier_id: d.id }, unique: true });
    if (j) remplir(form, { e_civilite: j.civilite, e_nom: j.nom, e_prenoms: j.prenoms, e_naissance: j.date_naissance, e_lieu: j.lieu_naissance, e_pays: j.pays_naissance, e_nationalite: j.nationalite, lien: j.lien, autorite_parentale: j.autorite_parentale });
  }

  form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      if (parcours === 'particulier' || parcours === 'jeunes') {
        valider(form, { profession: requis('votre situation professionnelle'), revenus_tranche: requis('vos revenus'), patrimoine_tranche: requis('votre patrimoine'), origine_fonds: requis('l’origine des fonds') });
        await appeler('gmb_dossier_maj_personne', { p_dossier: d.id, p_donnees: { profession: valeur(form, 'profession'), revenus_tranche: valeur(form, 'revenus_tranche'), patrimoine_tranche: valeur(form, 'patrimoine_tranche'), origine_fonds: valeur(form, 'origine_fonds'), etape: 7 } });
        if (projet) {
          valider(form, {
            revenus: (v) => (nombre(v) > 0 ? '' : 'Indiquez vos revenus nets mensuels.'),
            charges: (v) => (nombre(v) !== null && nombre(v) >= 0 ? '' : 'Indiquez vos charges mensuelles, 0 si vous n’en avez pas.'),
          });
          await appeler('gmb_dossier_credit_projet', { p_dossier: d.id, p_montant: projet.montant, p_duree: projet.duree_mois, p_objet: projet.objet, p_revenus: nombre(valeur(form, 'revenus')), p_charges: nombre(valeur(form, 'charges')) });
        }
      }
      if (parcours === 'jeunes') {
        valider(form, {
          e_civilite: requis('la civilité de votre enfant'), e_nom: requis('le nom de votre enfant'), e_prenoms: requis('les prénoms de votre enfant'),
          e_naissance: (v) => (!v ? 'Indiquez la date de naissance de votre enfant.' : (age(v) < 10 || age(v) > 17) ? 'Le compte Jeunes est réservé aux enfants de 10 à 17 ans.' : ''),
          e_lieu: requis('le lieu de naissance de votre enfant'), lien: requis('votre lien avec l’enfant'),
          autorite_parentale: (v) => (v ? '' : 'Vous devez exercer l’autorité parentale sur l’enfant pour ouvrir son compte.'),
        });
        await appeler('gmb_dossier_maj_jeune', { p_dossier: d.id, p_donnees: {
          civilite: valeur(form, 'e_civilite'), nom: valeur(form, 'e_nom'), prenoms: valeur(form, 'e_prenoms'), date_naissance: valeur(form, 'e_naissance'),
          lieu_naissance: valeur(form, 'e_lieu'), pays_naissance: valeur(form, 'e_pays') || 'FR', nationalite: valeur(form, 'e_nationalite') || 'FR', lien: valeur(form, 'lien'), autorite_parentale: true,
        } });
      }
      if (parcours === 'credit') {
        valider(form, {
          profession: requis('votre situation professionnelle'),
          revenus: (v) => (nombre(v) > 0 ? '' : 'Indiquez vos revenus nets mensuels.'),
          charges: (v) => (nombre(v) !== null && nombre(v) >= 0 ? '' : 'Indiquez vos charges mensuelles, 0 si vous n’en avez pas.'),
        });
        const projet = await lire('dossier_credit', { egal: { dossier_id: d.id }, unique: true });
        const revenus = nombre(valeur(form, 'revenus'));
        const tranche = revenus < 1500 ? 'moins_1500' : revenus < 3000 ? '1500_3000' : revenus < 5000 ? '3000_5000' : 'plus_5000';
        await appeler('gmb_dossier_maj_personne', { p_dossier: d.id, p_donnees: { profession: valeur(form, 'profession'), revenus_tranche: tranche, etape: 7 } });
        await appeler('gmb_dossier_credit_projet', { p_dossier: d.id, p_montant: projet.montant, p_duree: projet.duree_mois, p_objet: projet.objet, p_revenus: revenus, p_charges: nombre(valeur(form, 'charges')) });
      }
      if (parcours === 'pro' || parcours === 'business') {
        valider(form, {
          raison_sociale: requis(parcours === 'pro' ? 'le nom de votre activité' : 'la dénomination de la société'),
          siren: (v) => (/^\d{9}$/.test(v.replace(/\s/g, '')) ? '' : 'Saisissez les 9 chiffres du numéro SIREN.'),
          forme_juridique: requis('la forme juridique'), adresse_siege: requis('l’adresse du siège'),
          code_postal: (v) => (/^\d{5}$/.test(v) ? '' : 'Saisissez un code postal à 5 chiffres.'), ville: requis('la ville du siège'),
        });
        const donnees = Object.fromEntries(['raison_sociale', 'siren', 'forme_juridique', 'date_creation', 'code_naf', 'activite', 'adresse_siege', 'code_postal', 'ville', 'effectif', 'chiffre_affaires', 'role_demandeur'].map((n) => [n, valeur(form, n)]));
        donnees.siren = donnees.siren.replace(/\s/g, '');
        if (parcours === 'business') donnees.beneficiaires = lireBeneficiaires($('[data-beneficiaires]', form));
        await appeler('gmb_dossier_maj_entreprise', { p_dossier: d.id, p_donnees: donnees });
      }
      suivante(d);
    });
  });
}

/* -----------------------------------------------------------------------------
   Page 4 — Pièces justificatives
   -------------------------------------------------------------------------- */
async function pageDocuments() {
  const d = await dossierCourant(); adapterFrise(d);
  const zone = $('[data-pieces]');
  const consentementSelfie = $('[data-consentement-selfie]');
  const rendre = async () => {
    const pieces = await lire('dossier_pieces', { colonnes: 'id, type, statut, motif_refus_client', egal: { dossier_id: d.id }, ordre: 'type', croissant: true });
    zone.innerHTML = pieces.map((p) => {
      const [titre, aide] = LIBELLES_PIECES[p.type] || [p.type, ''];
      const recue = ['deposee', 'validee', 'en_controle'].includes(p.statut);
      return `<div class="gmb-depot gmb-carte" data-type="${p.type}" data-etat="${recue ? 'envoye' : ''}">
        <h3 class="gmb-depot__titre">${icone(recue ? 'check' : 'dossier')} ${echapperHtml(titre)}</h3>
        <p class="gmb-champ__aide">${echapperHtml(aide)}</p>
        ${p.statut === 'refusee' ? `<p class="gmb-champ__erreur">À remplacer${p.motif_refus_client ? ` : ${echapperHtml(p.motif_refus_client)}` : ''}.</p>` : ''}
        ${recue ? '<p class="gmb-depot__statut">Document reçu.</p>' : `
        <div class="gmb-champ"><label class="gmb-champ__libelle" for="f-${p.type}">${p.type === 'selfie' ? 'Prendre ou choisir la photo' : 'Choisir le fichier'}</label>
          <input class="gmb-saisie" id="f-${p.type}" type="file" accept="application/pdf,image/jpeg,image/png,image/heic"${p.type === 'selfie' ? ' capture="user"' : ''}></div>
        ${DATEES.has(p.type) ? `<div class="gmb-champ"><label class="gmb-champ__libelle" for="date-${p.type}">Date du document</label><input class="gmb-saisie" id="date-${p.type}" type="date"></div>` : ''}
        <p class="gmb-depot__statut" aria-live="polite"></p>
        <button type="button" class="gmb-bouton gmb-bouton--secondaire" data-envoyer="${p.type}">Envoyer</button>`}
      </div>`;
    }).join('');
    const manquantes = pieces.filter((p) => !['deposee', 'validee', 'en_controle', 'facultative'].includes(p.statut));
    $('[data-continuer]').disabled = manquantes.length > 0;
    $('[data-reste]').textContent = manquantes.length ? `Il reste ${manquantes.length} document${manquantes.length > 1 ? 's' : ''} à envoyer.` : 'Tous vos documents sont envoyés.';
    consentementSelfie.hidden = !pieces.some((p) => p.type === 'selfie' && !['deposee', 'validee', 'en_controle'].includes(p.statut));
  };
  zone.addEventListener('click', (e) => {
    const bouton = e.target.closest('[data-envoyer]');
    if (!bouton) return;
    const type = bouton.dataset.envoyer;
    const bloc = bouton.closest('[data-type]');
    executer(bouton, async () => {
      const fichier = $('input[type="file"]', bloc).files?.[0];
      const probleme = controlerFichier(fichier);
      if (probleme) throw new ErreurGmb(probleme);
      let dateDocument = null;
      if (DATEES.has(type)) {
        dateDocument = $(`#date-${type}`, bloc).value;
        if (!dateDocument || justificatifTropAncien(dateDocument, 3)) throw new ErreurGmb('Ce document doit dater de moins de 3 mois : indiquez sa date, ou déposez un document plus récent.');
      }
      if (type === 'selfie') {
        if (!$('[name="consentement_photo"]').checked) throw new ErreurGmb('Acceptez que votre photo soit comparée à votre pièce d’identité pour envoyer votre selfie.');
        await appeler('gmb_dossier_consentir', { p_dossier: d.id, p_type: 'biometrie', p_version: VERSION_TEXTES, p_accorde: true });
      }
      $('.gmb-depot__statut', bloc).textContent = 'Envoi en cours…';
      const cheminFichier = await deposerFichier('gmb-pieces', fichier);
      await appeler('gmb_dossier_piece_deposer', { p_dossier: d.id, p_type: type, p_chemin: cheminFichier, p_empreinte: await empreinteFichier(fichier), p_date_document: dateDocument });
      await rendre();
      message('Document reçu.', 'succes');
    });
  });
  $('[data-continuer]').addEventListener('click', () => suivante(d));
  await rendre();
}

/* -----------------------------------------------------------------------------
   Page 5 — Récapitulatif et signature
   -------------------------------------------------------------------------- */
async function pageSignature() {
  const d = await dossierCourant(); adapterFrise(d);
  const p = await lirePersonne(d);
  const lignes = [['Référence', d.reference], ['Nom', `${p?.prenoms || ''} ${p?.nom_naissance || ''}`.trim()], ['Né(e) le', p?.date_naissance ? formaterDate(`${p.date_naissance}T12:00:00`, 'long') : '—'],
    ['Adresse', [p?.adresse_ligne1, p?.code_postal, p?.ville].filter(Boolean).join(' ')], ['Téléphone', p?.telephone || '—']];
  if (d.type === 'credit') {
    const c = await lire('dossier_credit', { egal: { dossier_id: d.id }, unique: true });
    lignes.push(['Prêt demandé', `${formaterMontant(c?.montant || 0)} sur ${c?.duree_mois || '—'} mois`]);
  } else if (['pro', 'business'].includes(d.segment)) {
    const e = await lire('dossier_entreprises', { egal: { dossier_id: d.id }, unique: true });
    lignes.push(['Entreprise', `${e?.raison_sociale || '—'} · SIREN ${e?.siren || '—'}`]);
  } else if (d.segment === 'jeunes') {
    const j = await lire('dossier_jeunes', { egal: { dossier_id: d.id }, unique: true });
    lignes.push(['Enfant', `${j?.prenoms || ''} ${j?.nom || ''}, né(e) le ${j?.date_naissance ? formaterDate(`${j.date_naissance}T12:00:00`, 'long') : '—'}`]);
  }
  if (d.type !== 'credit') {
    const f = [...FORMULES, ...FORMULES_PRO].find((x) => x.code === d.formule_code);
    if (f) lignes.push(['Formule', f.nom]);
  }
  const projet = d.type === 'ouverture' ? await lire('dossier_credit', { egal: { dossier_id: d.id }, unique: true }) : null;
  if (projet) lignes.push(['Prêt demandé', `${formaterMontant(projet.montant)} sur ${projet.duree_mois} mois, mensualité estimée ${formaterMontant(projet.mensualite || 0)}`]);
  $('[data-recapitulatif]').innerHTML = `<dl class="gmb-pile gmb-pile--serree">${lignes.map(([t, v]) => `<div><dt><strong>${echapperHtml(t)}</strong></dt><dd>${echapperHtml(v)}</dd></div>`).join('')}</dl>`;
  const form = $('[data-form="signature"]');
  const avecPret = d.type === 'credit' || Boolean(projet);
  $('[data-si-ficp]').hidden = !avecPret;
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      valider(form, { accepte: (v) => (v ? '' : 'Cochez la case pour signer votre demande.'), ...(avecPret ? { ficp: (v) => (v ? '' : 'La consultation du FICP est obligatoire pour étudier une demande de prêt.') } : {}) });
      if (avecPret) await appeler('gmb_dossier_consentir', { p_dossier: d.id, p_type: 'ficp', p_version: VERSION_TEXTES, p_accorde: true });
      await appeler('gmb_dossier_consentir', { p_dossier: d.id, p_type: 'signature_convention', p_version: VERSION_TEXTES, p_accorde: true });
      suivante(d);
    });
  });
}

/* -----------------------------------------------------------------------------
   Page 6 — Premier versement par virement, puis dépôt du dossier
   -------------------------------------------------------------------------- */
async function pageValidation() {
  const d = await dossierCourant(); adapterFrise(d);
  const formVersement = $('[data-form="versement"]');
  const coordonnees = $('[data-coordonnees]');
  const formDepot = $('[data-form="depot"]');
  formVersement.hidden = d.type === 'credit';
  const afficher = (r) => {
    coordonnees.hidden = false;
    $$('[data-champ-virement]', coordonnees).forEach((el) => {
      const v = r[el.dataset.champVirement];
      // L'IBAN se lit par groupes de quatre ; le bouton « Copier » le donne sans espaces
      el.textContent = (el.dataset.champVirement === 'iban' && v ? formaterIban(v) : v) || '—';
      el.dataset.valeur = v || '';
      // Une ligne sans valeur (BIC non communiqué, par exemple) n'est pas affichée
      const ligne = el.closest('dl > div');
      if (ligne) ligne.hidden = !v;
    });
    $('[data-montant-virement]', coordonnees).textContent = formaterMontant(Number(r.montant));
    formDepot.hidden = false;
  };
  if (d.type === 'credit') { formDepot.hidden = false; $('[data-si-virement]').hidden = true; }
  else {
    const p = await lirePersonne(d);
    let titulaire = `${p?.prenoms || ''} ${p?.nom_usage || p?.nom_naissance || ''}`.trim();
    if (d.segment === 'business') titulaire = (await lire('dossier_entreprises', { colonnes: 'raison_sociale', egal: { dossier_id: d.id }, unique: true }))?.raison_sociale || titulaire;
    formVersement.elements.titulaire.value = titulaire;
    // Compte de réception de GerMoonBank : lu dans la base à chaque affichage
    const collecte = Object.fromEntries((await lire('parametres_banque', { colonnes: 'cle, valeur' })).map((x) => [x.cle.replace('collecte_', ''), x.valeur]));
    if (!collecte.iban) {
      formVersement.querySelector('[type="submit"]').disabled = true;
      message('Le compte qui reçoit les versements n’est pas encore renseigné par GerMoonBank. Votre demande est enregistrée : revenez un peu plus tard pour faire cette dernière étape.', 'info');
    }
    const declare = await lire('premiers_versements', { colonnes: 'montant, nom_titulaire, statut', egal: { dossier_id: d.id }, unique: true });
    if (declare) {
      formVersement.elements.montant.value = String(declare.montant).replace('.', ',');
      if (declare.nom_titulaire) formVersement.elements.titulaire.value = declare.nom_titulaire;
      if (collecte.iban) afficher({ ...collecte, montant: declare.montant, reference: d.reference });
    }
    formVersement.addEventListener('submit', (e) => {
      e.preventDefault();
      executer(formVersement.querySelector('[type="submit"]'), async () => {
        valider(formVersement, {
          montant: (v) => { const n = nombre(v); return n >= 10 && n <= 1000 ? '' : 'Choisissez un montant de 10 € à 1 000 €.'; },
          titulaire: requis(d.segment === 'business' ? 'le nom de la société titulaire du compte' : 'le nom du titulaire du compte'),
        });
        const r = await appeler('gmb_dossier_premier_versement', { p_dossier: d.id, p_montant: nombre(valeur(formVersement, 'montant')), p_moyen: 'virement', p_nom_titulaire: valeur(formVersement, 'titulaire') });
        afficher(r);
        defilerVers(coordonnees);
      });
    });
    $$('[data-copier]', coordonnees).forEach((b) => b.addEventListener('click', () => {
      const champ = $(`[data-champ-virement="${b.dataset.copier}"]`, coordonnees);
      copier(champ.dataset.valeur || champ.textContent, b);
    }));
  }
  formDepot.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(formDepot.querySelector('[type="submit"]'), async () => {
      if (d.type !== 'credit') valider(formDepot, { virement_fait: (v) => (v ? '' : 'Confirmez que vous effectuez ce virement.') });
      await appeler('gmb_dossier_deposer', { p_dossier: d.id });
      location.href = page('confirmation', d.id);
    });
  });
}

/* -----------------------------------------------------------------------------
   Page 7 — Confirmation
   -------------------------------------------------------------------------- */
async function pageConfirmation() {
  const d = await dossierCourant({ modifiable: false }); adapterFrise(d);
  $('[data-etat-dossier]').textContent = ['brouillon', 'incomplet'].includes(d.etat) ? 'Votre demande n’est pas encore déposée.' : 'Votre demande est déposée.';
  $$('[data-si-type]').forEach((el) => { el.hidden = el.dataset.siType !== d.type; });
  const projet = d.type === 'ouverture' ? await lire('dossier_credit', { colonnes: 'dossier_id', egal: { dossier_id: d.id }, unique: true }) : null;
  $$('[data-si-projet]').forEach((el) => { el.hidden = !projet; });
}

/* -----------------------------------------------------------------------------
   Démarrage selon la page
   -------------------------------------------------------------------------- */
const CONTROLEURS = {
  index: pageIndex, 'etape-1-identite': pageIdentite, 'etape-2-coordonnees': pageCoordonnees, 'etape-3-situation': pageSituation,
  'etape-4-documents': pageDocuments, 'etape-5-signature': pageSignature, 'etape-6-validation': pageValidation, confirmation: pageConfirmation,
};
// Un formulaire du tunnel n'est jamais envoyé par le navigateur : aucune donnée personnelle dans l'adresse
document.addEventListener('submit', (e) => e.preventDefault());

async function demarrer() {
  const controleur = CONTROLEURS[document.body.dataset.etape];
  if (!controleur) return;
  try { await controleur(); } catch (erreur) { if (!/Session absente|Dossier introuvable|Dossier déposé/.test(erreur?.message)) message(messageErreur(erreur)); }
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrer, { once: true });
else demarrer();
