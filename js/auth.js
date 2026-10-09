/* =============================================================================
   GerMoonBank (GMB) · js/auth.js
   Authentification — version 4 (2026-10-07)
   -----------------------------------------------------------------------------
   Sept pages (auth/) :
     mon-dossier           Espace Mon Dossier : e-mail et mot de passe ; code par
                           e-mail sur tout nouvel appareil
     mot-de-passe-oublie   code de réinitialisation par e-mail, nouveau mot de passe
     connexion             Espace client : identifiant, clavier aléatoire dessiné
                           par le serveur, appareil de confiance
     validation-forte      code par e-mail pour un nouvel appareil
     premiere-connexion    activation : code par e-mail, code secret choisi deux fois
     code-secret           code secret oublié ou bloqué : même principe
     activation-app        appareil de confiance et installation de l'application
   Les deux espaces reposent sur deux comptes techniques distincts : la fonction
   serveur gmb-connexion ouvre seule les sessions de l'Espace client.
   ========================================================================== */

import { chemin, CONFIG, echapperHtml, icone } from './core.js';
import {
  client, session, espaceDe, serveur, messageErreur, ErreurGmb, oublierContexte,
  ARRIVEE_PAR_LIEN, limiteEmail, attenteEmail, brancherRenvoi, appareilDossierConnu, memoriserAppareilDossier, messageDejaParti,
} from './donnees.js';
import { analyserMotDePasse, motDePasseDivulgue, brancherMotDePasse, occupe, afficherMessage, defilerVers, erreurChamp, masquerEmail } from './forms.js';

const DESTINATIONS = Object.freeze({ dossier: 'app/mon-dossier/index.html', client: 'app/index.html' });
const CLE_APPAREILS = 'gmb-appareils-client';
const CLE_IDENTIFIANT = 'gmb-identifiant-memorise';
const CLE_VALIDATION = 'gmb-validation-client';
const LONGUEUR_CODE = 8;

/* -----------------------------------------------------------------------------
   Outils communs
   -------------------------------------------------------------------------- */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
const lireLocal = (cle, defaut) => { try { return JSON.parse(localStorage.getItem(cle)) ?? defaut; } catch { return defaut; } };
const ecrireLocal = (cle, valeur) => { try { localStorage.setItem(cle, JSON.stringify(valeur)); } catch { /* stockage indisponible */ } };
const parametre = (nom) => new URLSearchParams(location.search).get(nom);

function message(texte, type = 'erreur') {
  const bloc = $('[data-message]');
  afficherMessage(bloc, texte, type);
  if (texte) defilerVers(bloc);
}
async function executer(bouton, action) {
  message('');
  occupe(bouton, true);
  try { await action(); } catch (erreur) { message(messageErreur(erreur)); } finally { occupe(bouton, false); }
}
function valider(form, regles) {
  let premier = null;
  for (const [nom, regle] of Object.entries(regles)) {
    const champ = form.elements[nom];
    const v = champ?.type === 'checkbox' ? champ.checked : String(champ?.value || '').trim();
    if (!erreurChamp(champ, regle(v) || '') && !premier) premier = champ;
  }
  if (premier) { premier.focus(); throw new ErreurGmb('Certaines informations sont à compléter ou à corriger.'); }
}
const identifiantValide = (v) => (/^\d{8}$/.test(String(v).replace(/\s/g, '')) ? '' : 'Votre identifiant comporte 8 chiffres.');
const sansEspaces = (v) => String(v || '').replace(/\s/g, '');

/** Adresse de retour : uniquement une page du site (aucune redirection extérieure possible). */
function retour(defaut) {
  const r = parametre('retour');
  const base = chemin('');
  return r && r.startsWith(base) && !r.startsWith('//') && !/[\\\n]/.test(r) ? r : chemin(defaut);
}

async function versEspaceDossier() {
  oublierContexte();
  location.replace(retour(DESTINATIONS.dossier));
}

/** Ouvre la session de l'Espace client remise par la fonction serveur. */
async function ouvrirSessionClient(reponse, identifiant) {
  const c = await client();
  const { error } = await c.auth.setSession({ access_token: reponse.session.access_token, refresh_token: reponse.session.refresh_token });
  if (error) throw error;
  if (reponse.appareil?.id && reponse.appareil?.cle) {
    const appareils = lireLocal(CLE_APPAREILS, {});
    appareils[identifiant] = { id: reponse.appareil.id, cle: reponse.appareil.cle };
    ecrireLocal(CLE_APPAREILS, appareils);
  }
  sessionStorage.removeItem(CLE_VALIDATION);
  oublierContexte();
  location.replace(chemin(DESTINATIONS.client));
}

function nomAppareil() {
  const a = navigator.userAgent;
  const n = /Edg\//.test(a) ? 'Edge' : /Firefox\//.test(a) ? 'Firefox' : /Chrome\//.test(a) ? 'Chrome' : /Safari\//.test(a) ? 'Safari' : 'Navigateur';
  const s = /Android/.test(a) ? 'Android' : /iPhone|iPad/.test(a) ? 'iOS' : /Windows/.test(a) ? 'Windows' : /Mac OS/.test(a) ? 'macOS' : /Linux/.test(a) ? 'Linux' : '';
  return s ? `${n} sur ${s}` : n;
}

/* -----------------------------------------------------------------------------
   Clavier aléatoire : touches dessinées par le serveur, positions de 1 à 12
   -------------------------------------------------------------------------- */
class Clavier {
  constructor(zone, { surComplet } = {}) {
    this.zone = zone;
    this.surComplet = surComplet;
    this.positions = [];
    this.accessible = Boolean(lireLocal('gmb-clavier-accessible', false));
  }

  async charger(identifiant) {
    this.identifiant = identifiant;
    const r = await serveur('gmb-connexion', { action: 'clavier', identifiant, accessible: this.accessible });
    if (r?.statut !== 'ok') throw new ErreurGmb(r?.message || 'Le clavier n’a pas pu être chargé. Réessayez.');
    this.grille = r.grille;
    this.positions = [];
    this.rendre(r.touches);
    clearTimeout(this.minuteur);
    const reste = new Date(r.expire_le).getTime() - Date.now();
    this.minuteur = setTimeout(() => {
      message('Le clavier a expiré : un nouveau clavier vous est proposé.', 'info');
      this.charger(this.identifiant).catch((e) => message(messageErreur(e)));
    }, Math.max(10_000, reste - 2_000));
  }

  rendre(touches) {
    this.zone.innerHTML = `<p class="gmb-mention-clavier" id="${this.zone.id}-aide">Touchez les chiffres de votre code secret. Les touches changent de place à chaque fois.</p>
      <div class="gmb-pastilles" data-pastilles aria-hidden="true">${'<span class="gmb-pastille"></span>'.repeat(LONGUEUR_CODE)}</div>
      <p class="gmb-visuellement-masque" aria-live="polite" data-annonce></p>
      <div class="gmb-clavier" role="group" aria-label="Clavier du code secret" aria-describedby="${this.zone.id}-aide">${touches.map((t, i) => {
        if (t.type === 'vide') return '<span class="gmb-touche gmb-touche--vide" aria-hidden="true"></span>';
        if (t.type === 'effacer') return `<button type="button" class="gmb-touche gmb-touche--action" data-effacer aria-label="Effacer le dernier chiffre">${icone('effacer')}</button>`;
        return `<button type="button" class="gmb-touche" data-position="${i + 1}" aria-label="${t.libelle ? `Chiffre ${echapperHtml(t.libelle)}` : 'Chiffre'}"><svg viewBox="0 0 40 40" width="40" height="40" aria-hidden="true" focusable="false"><path d="${echapperHtml(t.trace)}" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/></svg></button>`;
      }).join('')}</div>
      <label class="gmb-case"><input type="checkbox" data-accessible${this.accessible ? ' checked' : ''}><span>Lire les chiffres avec un lecteur d’écran</span></label>`;
    $('.gmb-clavier', this.zone).addEventListener('click', (e) => {
      const touche = e.target.closest('button');
      if (!touche) return;
      if (touche.hasAttribute('data-effacer')) this.positions.pop();
      else if (this.positions.length < LONGUEUR_CODE) this.positions.push(Number(touche.dataset.position));
      this.majPastilles();
      if (this.positions.length === LONGUEUR_CODE) this.surComplet?.();
    });
    $('[data-accessible]', this.zone).addEventListener('change', (e) => {
      this.accessible = e.target.checked;
      ecrireLocal('gmb-clavier-accessible', this.accessible);
      this.charger(this.identifiant).catch((x) => message(messageErreur(x)));
    });
  }

  majPastilles() {
    $$('.gmb-pastille', this.zone).forEach((p, i) => { p.dataset.pleine = String(i < this.positions.length); });
    $('[data-annonce]', this.zone).textContent = `${this.positions.length} chiffre${this.positions.length > 1 ? 's' : ''} saisi${this.positions.length > 1 ? 's' : ''} sur ${LONGUEUR_CODE}.`;
  }

  complet() { return this.positions.length === LONGUEUR_CODE; }
  saisie() { return { grille: this.grille, positions: [...this.positions] }; }
}

/* -----------------------------------------------------------------------------
   Espace Mon Dossier : connexion, nouvel appareil
   -------------------------------------------------------------------------- */
/** Un e-mail est déjà parti à cette adresse il y a moins d'une minute : son code reste le bon. */
const dejaParti = (erreur) => Boolean(erreur) && limiteEmail(erreur) && attenteEmail(erreur) !== null;

async function pageMonDossier() {
  if (parametre('raison') === 'session') message('Votre session a expiré par sécurité. Reconnectez-vous pour continuer.', 'info');
  if (ARRIVEE_PAR_LIEN?.erreur) message('Ce lien n’est plus valable : il a expiré ou il a déjà servi. Connectez-vous avec votre adresse e-mail et votre mot de passe.', 'info');
  const s = await session();
  // Un collaborateur arrivé ici par son lien de connexion est conduit au back-office
  if (s && espaceDe(s) === 'backoffice' && ARRIVEE_PAR_LIEN && !ARRIVEE_PAR_LIEN.erreur) { location.replace(chemin('bo/index.html')); return; }
  if (s && espaceDe(s) === 'dossier') {
    // Arrivée par un lien reçu par e-mail : il vaut confirmation de cet appareil
    if (ARRIVEE_PAR_LIEN && !ARRIVEE_PAR_LIEN.erreur) memoriserAppareilDossier(s.user.id);
    if (appareilDossierConnu(s.user.id)) { await versEspaceDossier(); return; }
  }
  const form = $('[data-form="connexion-dossier"]');
  const formCode = $('[data-form="code-appareil"]');
  const etat = { email: '', confirmation: false };

  /** Envoie le code : confirmation de l'adresse (accès jamais confirmé) ou confirmation de l'appareil. */
  async function envoyerCode() {
    const c = await client();
    const options = { emailRedirectTo: chemin('auth/mon-dossier.html') };
    const { error } = etat.confirmation
      ? await c.auth.resend({ type: 'signup', email: etat.email, options })
      : await c.auth.signInWithOtp({ email: etat.email, options: { ...options, shouldCreateUser: false } });
    if (error) throw error;
  }
  const renvoi = brancherRenvoi($('[data-renvoyer-code]'), envoyerCode, { message });
  async function demanderCode(texte) {
    let attente = null;
    try { await envoyerCode(); } catch (erreur) { if (!dejaParti(erreur)) throw erreur; attente = attenteEmail(erreur); }
    form.hidden = true;
    formCode.hidden = false;
    $('[data-email-code]').textContent = masquerEmail(etat.email);
    renvoi.demarrer(attente || 60);
    message(attente ? messageDejaParti(attente) : texte, 'info');
    formCode.elements.code.focus();
  }

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      valider(form, { email: (v) => (/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v) ? '' : 'Saisissez votre adresse e-mail.'), mdp: (v) => (v ? '' : 'Saisissez votre mot de passe.') });
      const email = form.elements.email.value.trim().toLowerCase();
      const c = await client();
      const { data, error } = await c.auth.signInWithPassword({ email, password: form.elements.mdp.value });
      form.elements.mdp.value = '';
      etat.email = email;
      if (error?.code === 'email_not_confirmed' || /email not confirmed/i.test(error?.message || '')) {
        // Accès créé, adresse jamais confirmée : le code de confirmation repart, puis ouvre l'espace
        etat.confirmation = true;
        await demanderCode('Votre adresse e-mail n’est pas encore confirmée : saisissez le code que nous venons de vous envoyer.');
        return;
      }
      if (error) throw error;
      if (espaceDe(data.session) !== 'dossier') {
        await c.auth.signOut({ scope: 'local' });
        throw new ErreurGmb('Cet accès n’est pas celui de l’Espace Mon Dossier. Pour vos comptes, utilisez la connexion à l’Espace client.');
      }
      if (appareilDossierConnu(data.user.id)) { await versEspaceDossier(); return; }
      // Nouvel appareil : code par e-mail
      await c.auth.signOut({ scope: 'local' });
      etat.confirmation = false;
      await demanderCode('');
    });
  });
  formCode.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(formCode.querySelector('[type="submit"]'), async () => {
      valider(formCode, { code: (v) => (/^\d{6}$/.test(sansEspaces(v)) ? '' : 'Saisissez les 6 chiffres du code reçu par e-mail.') });
      const c = await client();
      const { data, error } = await c.auth.verifyOtp({ email: etat.email, token: sansEspaces(formCode.elements.code.value), type: 'email' });
      if (error) throw error;
      if (formCode.elements.memoriser.checked) memoriserAppareilDossier(data.user.id);
      await versEspaceDossier();
    });
  });
}

/* -----------------------------------------------------------------------------
   Mot de passe oublié (Espace Mon Dossier)
   -------------------------------------------------------------------------- */
async function pageMotDePasse() {
  const form = $('[data-form="demande"]');
  const formNouveau = $('[data-form="nouveau-mdp"]');
  const etat = { email: '', parLien: false };
  const montrerNouveau = () => {
    form.hidden = true;
    formNouveau.hidden = false;
    $('[data-email-code]').textContent = masquerEmail(etat.email);
    brancherMotDePasse({ champ: formNouveau.elements.mdp, champEmail: { value: etat.email, addEventListener() {} }, jauge: $('[data-jauge]'), controles: $('[data-regles]'), bouton: $('[data-afficher-mdp]') });
  };
  async function envoyerCode() {
    const c = await client();
    const { error } = await c.auth.resetPasswordForEmail(etat.email, { redirectTo: chemin('auth/mot-de-passe-oublie.html') });
    if (error) throw error;
  }
  const renvoi = brancherRenvoi($('[data-renvoyer-code]'), envoyerCode, { message });

  // Arrivée par le lien de réinitialisation reçu par e-mail : il vaut code
  if (ARRIVEE_PAR_LIEN?.erreur) message('Ce lien n’est plus valable : il a expiré ou il a déjà servi. Demandez un nouveau code ci-dessous.', 'info');
  const s = ARRIVEE_PAR_LIEN && !ARRIVEE_PAR_LIEN.erreur ? await session() : null;
  if (s && ARRIVEE_PAR_LIEN.type === 'recovery') {
    etat.email = s.user.email; etat.parLien = true;
    montrerNouveau();
    formNouveau.elements.code.closest('.gmb-champ').hidden = true;
    $('[data-renvoyer-code]')?.closest('p')?.setAttribute('hidden', '');
    message('Votre adresse est confirmée : choisissez votre nouveau mot de passe.', 'info');
  }

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      valider(form, { email: (v) => (/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v) ? '' : 'Saisissez votre adresse e-mail.') });
      etat.email = form.elements.email.value.trim().toLowerCase();
      let attente = null;
      try { await envoyerCode(); } catch (erreur) { if (!dejaParti(erreur)) throw erreur; attente = attenteEmail(erreur); }
      montrerNouveau();
      renvoi.demarrer(attente || 60);
      message(attente ? messageDejaParti(attente)
        : 'Si un Espace Mon Dossier existe avec cette adresse, un code vient d’y être envoyé.', 'info');
    });
  });
  formNouveau.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(formNouveau.querySelector('[type="submit"]'), async () => {
      if (!etat.parLien) valider(formNouveau, { code: (v) => (/^\d{6}$/.test(sansEspaces(v)) ? '' : 'Saisissez les 6 chiffres du code reçu par e-mail.') });
      const mdp = formNouveau.elements.mdp.value;
      const a = analyserMotDePasse(mdp, etat.email);
      let probleme = !a.longueur ? 'Votre mot de passe doit contenir au moins 12 caractères.' : !a.sansEmail ? 'Votre mot de passe ne doit pas contenir votre adresse e-mail.' : '';
      if (!probleme && (a.connu || (await motDePasseDivulgue(mdp)) === true)) probleme = 'Ce mot de passe figure dans des fuites de données connues : choisissez-en un autre.';
      if (!erreurChamp(formNouveau.elements.mdp, probleme)) throw new ErreurGmb(probleme);
      const c = await client();
      let uid = (await session())?.user?.id || null;
      if (!etat.parLien) {
        const jeton = sansEspaces(formNouveau.elements.code.value);
        let v = await c.auth.verifyOtp({ email: etat.email, token: jeton, type: 'recovery' });
        if (v.error) v = await c.auth.verifyOtp({ email: etat.email, token: jeton, type: 'email' });
        if (v.error) throw v.error;
        uid = v.data.user.id;
        etat.parLien = true; // le code a servi : seule reste la saisie du mot de passe
        formNouveau.elements.code.closest('.gmb-champ').hidden = true;
      }
      const { error } = await c.auth.updateUser({ password: mdp });
      if (error && error.code !== 'same_password') throw error;
      formNouveau.elements.mdp.value = '';
      await c.auth.signOut({ scope: 'others' }).catch(() => {});
      if (uid) memoriserAppareilDossier(uid);
      message('Votre mot de passe est modifié.', 'succes');
      await versEspaceDossier();
    });
  });
}

/* -----------------------------------------------------------------------------
   Espace client : identifiant et code secret
   -------------------------------------------------------------------------- */
async function pageConnexion() {
  if (parametre('raison') === 'session') message('Votre session a expiré par sécurité. Reconnectez-vous.', 'info');
  const form = $('[data-form="connexion-client"]');
  const zoneClavier = $('[data-clavier]');
  const memorise = lireLocal(CLE_IDENTIFIANT, null);
  if (memorise) { form.elements.identifiant.value = memorise; form.elements.memoriser.checked = true; }
  let identifiant = null;
  const clavier = new Clavier(zoneClavier, { surComplet: () => form.requestSubmit() });
  async function afficherClavier() {
    valider(form, { identifiant: identifiantValide });
    identifiant = sansEspaces(form.elements.identifiant.value);
    if (form.elements.memoriser.checked) ecrireLocal(CLE_IDENTIFIANT, identifiant); else localStorage.removeItem(CLE_IDENTIFIANT);
    await clavier.charger(identifiant);
    $('[data-etape-code]').hidden = false;
    $('[data-continuer-identifiant]').hidden = true;
  }
  $('[data-continuer-identifiant]').addEventListener('click', (e) => executer(e.currentTarget, afficherClavier));
  form.elements.identifiant.addEventListener('input', () => { $('[data-etape-code]').hidden = true; $('[data-continuer-identifiant]').hidden = false; });
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      if (!identifiant || $('[data-etape-code]').hidden) { await afficherClavier(); return; }
      if (!clavier.complet()) throw new ErreurGmb('Saisissez les 8 chiffres de votre code secret.');
      const appareil = lireLocal(CLE_APPAREILS, {})[identifiant] || null;
      const r = await serveur('gmb-connexion', { action: 'code', ...clavier.saisie(), appareil, appareil_nom: nomAppareil() });
      switch (r?.statut) {
        case 'connecte': await ouvrirSessionClient(r, identifiant); return;
        case 'validation':
          sessionStorage.setItem(CLE_VALIDATION, JSON.stringify({ transaction: r.transaction, destination: r.destination, expire_le: r.expire_le, identifiant }));
          location.href = chemin('auth/validation-forte.html');
          return;
        case 'echec':
          await clavier.charger(identifiant);
          throw new ErreurGmb(r.essais_restants ? `Code incorrect. Il vous reste ${r.essais_restants} essai${r.essais_restants > 1 ? 's' : ''} avant le blocage.` : 'Code incorrect.');
        case 'bloque':
          throw new ErreurGmb(`Votre accès est bloqué par sécurité jusqu’à ${new Date(r.bloque_jusqu).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' })}. Vous pouvez aussi réinitialiser votre code secret.`);
        case 'bloque_definitif':
          location.href = chemin('auth/code-secret.html?raison=bloque');
          return;
        case 'non_active':
          location.href = `${chemin('auth/premiere-connexion.html')}#identifiant=${identifiant}`;
          return;
        case 'grille_expiree': case 'format':
          await clavier.charger(identifiant);
          throw new ErreurGmb('Le clavier a expiré. Saisissez de nouveau votre code.');
        case 'patienter':
          // Votre code secret est bon ; un seul e-mail peut partir par minute vers une même adresse
          await clavier.charger(identifiant);
          throw new ErreurGmb(r.message || 'Un code vient déjà de vous être envoyé. Patientez une minute, puis saisissez de nouveau votre code secret.');
        default:
          throw new ErreurGmb(r?.message || 'Connexion impossible pour le moment. Réessayez dans un instant.');
      }
    });
  });
  if (memorise) afficherClavier().catch((e) => message(messageErreur(e)));
}

/* -----------------------------------------------------------------------------
   Validation forte : code par e-mail pour un nouvel appareil
   -------------------------------------------------------------------------- */
async function pageValidation() {
  const etat = JSON.parse(sessionStorage.getItem(CLE_VALIDATION) || 'null');
  if (!etat || new Date(etat.expire_le).getTime() < Date.now()) { location.replace(chemin('auth/connexion.html?raison=expire')); return; }
  $('[data-destination]').textContent = etat.destination;
  const form = $('[data-form="validation"]');
  form.elements.appareil_nom.value = nomAppareil();
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(form.querySelector('[type="submit"]'), async () => {
      valider(form, { code: (v) => (/^\d{6}$/.test(sansEspaces(v)) ? '' : 'Saisissez les 6 chiffres du code reçu par e-mail.') });
      const r = await serveur('gmb-connexion', { action: 'validation', transaction: etat.transaction, code: sansEspaces(form.elements.code.value), appareil_nom: form.elements.appareil_nom.value.trim() || nomAppareil() });
      if (r?.statut === 'connecte') { await ouvrirSessionClient(r, etat.identifiant); return; }
      if (r?.statut === 'expire') { sessionStorage.removeItem(CLE_VALIDATION); location.replace(chemin('auth/connexion.html?raison=expire')); return; }
      throw new ErreurGmb(r?.message || 'Ce code est incorrect ou n’est plus valable.');
    });
  });
}

/* -----------------------------------------------------------------------------
   Première connexion et code secret oublié : code e-mail, code secret deux fois
   -------------------------------------------------------------------------- */
async function parcoursCodeSecret(but) {
  const envoi = but === 'activation' ? 'activation-envoi' : 'reinitialisation-envoi';
  if (parametre('raison') === 'bloque') message('Votre accès est bloqué par sécurité. Choisissez un nouveau code secret pour le débloquer.', 'info');
  const form = $('[data-form="identifiant"]');
  const formCode = $('[data-form="nouveau-code"]');
  const transmis = new URLSearchParams(location.hash.replace(/^#/, '')).get('identifiant') || parametre('identifiant');
  if (transmis && /^\d{8}$/.test(transmis)) {
    form.elements.identifiant.value = transmis;
    history.replaceState(null, '', location.pathname); // l'identifiant ne reste pas dans l'adresse
  }
  let transaction = null;
  let identifiant = null;
  const clavier1 = new Clavier($('[data-clavier="1"]'), { surComplet: () => $('[data-etape-confirmation]').scrollIntoView({ block: 'nearest' }) });
  const clavier2 = new Clavier($('[data-clavier="2"]'));
  async function chargerClaviers() { await clavier1.charger(identifiant); await clavier2.charger(identifiant); }
  /** Demande l'envoi du code. La réponse est la même que l'identifiant existe ou non. */
  async function envoyerCode() {
    const r = await serveur('gmb-connexion', { action: envoi, identifiant });
    if (r?.statut !== 'envoye') throw new ErreurGmb(r?.message || 'Le code n’a pas pu être envoyé. Réessayez dans un instant.');
    transaction = r.transaction;
  }
  const annonce = `Si cet identifiant correspond à un accès à ${but === 'activation' ? 'activer' : 'réinitialiser'}, un code vient d’être envoyé à l’adresse e-mail de votre dossier. S’il n’arrive pas dans la minute, c’est qu’un autre e-mail venait de vous être envoyé (un seul peut partir par minute) : demandez alors un nouveau code avec le bouton en bas de cette page, dès qu’il est disponible.`;
  const renvoi = brancherRenvoi($('[data-renvoyer-code]'), envoyerCode, { message: (texte, type) => message(type === 'succes' ? annonce : texte, type === 'succes' ? 'info' : type) });
  async function demanderCode() {
    valider(form, { identifiant: identifiantValide });
    identifiant = sansEspaces(form.elements.identifiant.value);
    await envoyerCode();
    form.hidden = true;
    formCode.hidden = false;
    renvoi.demarrer(60);
    await chargerClaviers();
    message(annonce, 'info');
    formCode.elements.code.focus();
  }
  form.addEventListener('submit', (e) => { e.preventDefault(); executer(form.querySelector('[type="submit"]'), demanderCode); });
  formCode.addEventListener('submit', (e) => {
    e.preventDefault();
    executer(formCode.querySelector('[type="submit"]'), async () => {
      valider(formCode, { code: (v) => (/^\d{6}$/.test(sansEspaces(v)) ? '' : 'Saisissez les 6 chiffres du code reçu par e-mail.') });
      if (!clavier1.complet() || !clavier2.complet()) throw new ErreurGmb('Saisissez votre nouveau code secret de 8 chiffres sur les deux claviers.');
      const s1 = clavier1.saisie(); const s2 = clavier2.saisie();
      const r = await serveur('gmb-connexion', { action: but, transaction, code: sansEspaces(formCode.elements.code.value), grille1: s1.grille, positions1: s1.positions, grille2: s2.grille, positions2: s2.positions, appareil_nom: nomAppareil() });
      if (r?.statut === 'ok') { await ouvrirSessionClient(r, identifiant); return; }
      if (r?.statut === 'deja_active') { location.replace(chemin('auth/connexion.html')); return; }
      if (r?.statut === 'expire') { form.hidden = false; formCode.hidden = true; throw new ErreurGmb(r.message); }
      // Les deux claviers ne servent qu'une fois : ils sont redessinés après tout refus
      await chargerClaviers();
      const suite = r?.statut === 'code_refuse'
        ? (r.code_email_conserve ? ' Choisissez un autre code secret : le code reçu par e-mail reste valable.' : ' Choisissez un autre code secret, puis demandez un nouveau code par e-mail.')
        : r?.statut === 'code_incorrect' ? ' Vérifiez le code reçu par e-mail, puis saisissez de nouveau votre code secret.' : '';
      throw new ErreurGmb((r?.message || 'L’opération n’a pas abouti.') + suite);
    });
  });
}

/* -----------------------------------------------------------------------------
   Activer l'application : appareil de confiance et installation
   -------------------------------------------------------------------------- */
async function pageActivationApp() {
  const appareils = lireLocal(CLE_APPAREILS, {});
  const nombre = Object.keys(appareils).length;
  $('[data-etat-appareil]').textContent = nombre
    ? 'Cet appareil est un appareil de confiance pour votre Espace client : la connexion ne demande que votre code secret.'
    : 'Cet appareil n’est pas encore de confiance : à la première connexion, un code vous sera envoyé par e-mail pour le confirmer.';
  const autonome = window.matchMedia?.('(display-mode: standalone)').matches || navigator.standalone === true;
  $('[data-etat-installation]').textContent = autonome ? 'L’application est installée et ouverte depuis l’écran d’accueil.' : 'L’application n’est pas encore installée sur cet appareil.';
  const bouton = $('[data-installer]');
  let invite = null;
  window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); invite = e; bouton.hidden = false; });
  bouton.addEventListener('click', async () => {
    if (!invite) return;
    invite.prompt();
    const choix = await invite.userChoice;
    message(choix.outcome === 'accepted' ? 'L’application est installée.' : 'Installation annulée.', choix.outcome === 'accepted' ? 'succes' : 'info');
    invite = null;
    bouton.hidden = true;
  });
  $('[data-ios]').hidden = !/iPhone|iPad/.test(navigator.userAgent) || autonome;
  $('[data-oublier-appareil]').addEventListener('click', () => {
    localStorage.removeItem(CLE_APPAREILS);
    localStorage.removeItem(CLE_IDENTIFIANT);
    message('Cet appareil n’est plus de confiance. Pour le retirer aussi de votre liste d’appareils, rendez-vous dans votre Espace client.', 'succes');
    $('[data-etat-appareil]').textContent = 'Cet appareil n’est plus de confiance.';
  });
}

/* -----------------------------------------------------------------------------
   Démarrage
   -------------------------------------------------------------------------- */
document.addEventListener('submit', (e) => e.preventDefault());
const CONTROLEURS = {
  'mon-dossier': pageMonDossier, 'mot-de-passe-oublie': pageMotDePasse, connexion: pageConnexion, 'validation-forte': pageValidation,
  'premiere-connexion': () => parcoursCodeSecret('activation'), 'code-secret': () => parcoursCodeSecret('reinitialisation'), 'activation-app': pageActivationApp,
};
async function demarrer() {
  const controleur = CONTROLEURS[document.body.dataset.page];
  if (!controleur) return;
  try { await controleur(); } catch (erreur) { message(messageErreur(erreur)); }
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrer, { once: true });
else demarrer();
export { CONFIG, Clavier, nomAppareil };
