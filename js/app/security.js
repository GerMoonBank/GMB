/* =============================================================================
   GerMoonBank (GMB) · js/app/security.js — Paramètres (lot E2c)
   Profil, coordonnées (code secret), mot de passe, changement du code secret,
   sécurité et connexions, appareils, notifications, apparence, fermeture.
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, e, date, badge, tableau, demander, executer, message, authentifier, refusSca, appliquerApparence } from './app.js';
import { lire, appeler, ErreurGmb } from '../donnees.js';

const CIVILITES = { madame: 'Madame', monsieur: 'Monsieur' };
const MOTIFS = [['ne_convient_plus', 'Le service ne me convient plus'], ['frais', 'Les frais'], ['autre_banque', 'Je regroupe mes comptes dans une autre banque'], ['demenagement_etranger', 'Je m’installe à l’étranger'], ['autre', 'Autre raison']];
const RESULTATS = { succes: ['Réussie', 'succes'], echec_code: ['Code erroné', 'danger'], bloque: ['Accès bloqué', 'danger'], bloque_definitif: ['Accès bloqué', 'danger'], sca_refusee: ['Validation refusée', 'danger'], grille_expiree: ['Clavier expiré', 'neutre'] };
const heure = (d) => new Date(d).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });

const NOMS_FORMULES = { luna: 'Luna', halo: 'Halo', orbit: 'Orbit', eclipse: 'Éclipse', zenith: 'Zénith', pro_solo: 'Pro Solo', pro_plus: 'Pro Plus', business_start: 'Business Start', business_growth: 'Business Growth', business_scale: 'Business Scale' };
async function moi(ctx) { return lire('clients', { colonnes: 'id, identifiant, segment, formule_code, ouvert_le, personne_id, theme, langue, preferences', egal: { id: ctx.client.id }, unique: true }); }
async function personne(c) { return lire('personnes', { egal: { id: c.personne_id }, unique: true }); }

async function profil() {
  const ctx = await ouvrirEspace('parametres');
  const c = await moi(ctx); const p = await personne(c);
  $('[data-profil]').innerHTML = `<dl class="app-recap"><div><dt>Nom</dt><dd>${e([CIVILITES[p?.civilite], p?.prenoms, p?.nom_usage || p?.nom_naissance].filter(Boolean).join(' '))}</dd></div>
    ${p?.nom_usage ? `<div><dt>Nom de naissance</dt><dd>${e(p.nom_naissance)}</dd></div>` : ''}<div><dt>Date de naissance</dt><dd>${date(p?.date_naissance, 'long')}${p?.lieu_naissance ? ` à ${e(p.lieu_naissance)}` : ''}</dd></div>
    <div><dt>Identifiant</dt><dd>${e(c.identifiant)}</dd></div><div><dt>Formule</dt><dd>${e(NOMS_FORMULES[c.formule_code] || c.formule_code || '—')}</dd></div><div><dt>Client depuis le</dt><dd>${date(c.ouvert_le, 'long')}</dd></div></dl>`;
}

async function coordonnees() {
  const ctx = await ouvrirEspace('parametres');
  const c = await moi(ctx); const p = await personne(c);
  $('[data-email]').innerHTML = `<dl class="app-recap"><div><dt>Adresse e-mail</dt><dd>${e(p?.email || '—')}</dd></div></dl>`;
  const form = $('[data-form="coordonnees"]');
  for (const k of ['telephone', 'adresse_ligne1', 'adresse_ligne2', 'code_postal', 'ville']) form.elements[k].value = p?.[k] || '';
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const v = Object.fromEntries(['telephone', 'adresse_ligne1', 'adresse_ligne2', 'code_postal', 'ville'].map((k) => [k, form.elements[k].value.trim()]));
      if (!v.telephone || !v.adresse_ligne1 || !/^\d{5}$/.test(v.code_postal) || !v.ville) throw new ErreurGmb('Renseignez votre téléphone et votre adresse complète (code postal à 5 chiffres).');
      const code = await authentifier('Confirmer vos nouvelles coordonnées', [['Téléphone', e(v.telephone)], ['Adresse', e([v.adresse_ligne1, v.adresse_ligne2, `${v.code_postal} ${v.ville}`].filter(Boolean).join(', '))]], ctx.client.identifiant);
      if (!code) return;
      const r = await appeler('gmb_client_coordonnees', { p_telephone: v.telephone, p_adresse_ligne1: v.adresse_ligne1, p_adresse_ligne2: v.adresse_ligne2, p_code_postal: v.code_postal, p_ville: v.ville, p_grille: code.grille, p_positions: code.positions });
      await refusSca(r);
      message('Vos coordonnées sont mises à jour.', 'succes');
    });
  });
}

async function motDePasse() { await ouvrirEspace('parametres'); }

async function codeSecret() {
  const ctx = await ouvrirEspace('parametres');
  $('[data-changer]').addEventListener('click', (x) => executer(x.currentTarget, async () => {
    const actuel = await authentifier('Changer votre code secret', [['Étape', '1 sur 3']], ctx.client.identifiant, 'Saisissez votre code secret actuel.');
    if (!actuel) return;
    const nouveau = await authentifier('Changer votre code secret', [['Étape', '2 sur 3']], ctx.client.identifiant, 'Saisissez votre nouveau code secret : 8 chiffres, sans suite ni répétition, différent de votre date de naissance.');
    if (!nouveau) return;
    const confirmation = await authentifier('Changer votre code secret', [['Étape', '3 sur 3']], ctx.client.identifiant, 'Saisissez à nouveau votre nouveau code secret.');
    if (!confirmation) return;
    const r = await appeler('gmb_code_secret_changer', { p_grille_actuel: actuel.grille, p_actuel: actuel.positions, p_grille_nouveau: nouveau.grille, p_nouveau: nouveau.positions, p_grille_confirmation: confirmation.grille, p_confirmation: confirmation.positions });
    await refusSca(r);
    message('Votre code secret est modifié. Utilisez-le dès votre prochaine connexion.', 'succes');
  }));
}

async function securite() {
  await ouvrirEspace('parametres');
  const [connexions, appareils] = await Promise.all([lire('connexions', { ordre: 'created_at', croissant: false, limite: 20 }), lire('appareils', { colonnes: 'id, revoque_le' })]);
  $('[data-connexions]').innerHTML = tableau('Vos dernières connexions', ['Date', 'Résultat'], connexions.map((x) => [`${date(x.created_at, 'long')} à ${heure(x.created_at)}`, badge(...(RESULTATS[x.resultat] || [x.resultat, 'neutre']))]), 'Aucune connexion enregistrée.');
  const actifs = appareils.filter((a) => !a.revoque_le).length;
  $('[data-resume-appareils]').textContent = `${actifs} appareil${actifs > 1 ? 's' : ''} de confiance.`;
}

async function appareils() {
  await ouvrirEspace('parametres');
  const zone = $('[data-appareils]');
  const rendre = async () => {
    const liste = await lire('appareils', { ordre: 'ajoute_le', croissant: false });
    zone.innerHTML = tableau('Vos appareils', ['Appareil', 'Ajouté le', 'Dernière utilisation', 'Statut', ''], liste.map((a) => [e(a.nom || a.plateforme), date(a.ajoute_le, 'long'), a.derniere_utilisation ? date(a.derniere_utilisation, 'long') : '—',
      a.revoque_le ? badge('Révoqué', 'neutre') : badge('De confiance', 'succes'), a.revoque_le ? '' : `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-revoquer="${a.id}">Révoquer</button>`]), 'Aucun appareil de confiance.');
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('[data-revoquer]');
    if (b) executer(b, async () => {
      const ok = await demander('Révoquer cet appareil ?', [], { valider: 'Révoquer', danger: true, intro: 'Il ne sera plus reconnu : une validation par e-mail sera demandée à la prochaine connexion depuis cet appareil.' });
      if (!ok) return;
      await appeler('gmb_appareil_revoquer', { p_appareil: b.dataset.revoquer }); await rendre();
    }, 'Appareil révoqué.');
  });
  await rendre();
}

async function notifications() {
  const ctx = await ouvrirEspace('parametres');
  const c = await moi(ctx);
  const rendre = async () => {
    const liste = await lire('notifications', { ordre: 'created_at', croissant: false, limite: 50 });
    $('[data-notifications]').innerHTML = liste.length ? `<ul class="app-lignes">${liste.map((n) => `<li><span><strong>${e(n.titre)}</strong><br>${e(n.contenu)}<br><small>${date(n.created_at, 'long')} à ${heure(n.created_at)}</small></span>${n.lu_le ? '' : badge('Nouveau', 'succes')}</li>`).join('')}</ul>` : '<p class="app-vide">Aucune notification.</p>';
  };
  const case_ = $('#marketing'); case_.checked = Boolean(c?.preferences?.marketing);
  case_.addEventListener('change', () => executer(case_, async () => { await appeler('gmb_preferences', { p_preferences: { marketing: case_.checked } }); }, case_.checked ? 'Accord enregistré.' : 'Refus enregistré : vous ne recevrez aucune communication commerciale.'));
  $('[data-tout-lu]').addEventListener('click', (x) => executer(x.currentTarget, async () => { await appeler('gmb_notification_lue', { p_notification: null }); await rendre(); }, 'Notifications marquées comme lues.'));
  await rendre();
}

async function apparence() {
  const ctx = await ouvrirEspace('parametres');
  const c = await moi(ctx);
  const form = $('[data-form="apparence"]');
  // Sans choix enregistré, l'Espace client s'affiche en « Nuit » (sombre)
  let locale = null; try { locale = localStorage.getItem('gmb-theme'); } catch { /* stockage indisponible */ }
  // « clair » est la valeur par défaut de la base : sans choix enregistré sur cet appareil, l'Espace client est en « Nuit »
  form.elements.theme.value = locale === null ? (['sombre', 'systeme'].includes(c?.theme) ? c.theme : 'sombre') : (locale === '' ? 'systeme' : locale);
  form.addEventListener('change', () => executer(form.querySelector('fieldset'), async () => {
    const theme = form.elements.theme.value;
    try { localStorage.setItem('gmb-theme', theme === 'systeme' ? '' : theme); } catch { /* préférence locale facultative */ }
    appliquerApparence(theme === 'systeme' ? '' : theme);
    await appeler('gmb_preferences', { p_theme: theme });
  }, 'Apparence enregistrée.'));
}

async function fermeture() {
  const ctx = await ouvrirEspace('parametres');
  const form = $('[data-form="fermeture"]');
  form.elements.motif.innerHTML = MOTIFS.map(([v, l]) => `<option value="${v}">${e(l)}</option>`).join('');
  const rendre = async () => {
    const demandes = await lire('demandes_cloture', { ordre: 'created_at', croissant: false });
    const enCours = demandes.find((d) => d.statut === 'demandee');
    form.hidden = Boolean(enCours);
    $('[data-demande]').innerHTML = enCours ? `<div class="gmb-carte gmb-pile gmb-pile--serree"><p>${badge('Demande en cours', 'neutre')} Envoyée le ${date(enCours.created_at, 'long')}. Votre compte sera fermé sous 30 jours au plus, après restitution du solde sur l’IBAN ${e(enCours.iban_restitution.replace(/(.{4})/g, '$1 ').trim())}.</p>
      <p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-annuler="${enCours.id}">Annuler ma demande</button></p></div>`
      : demandes.filter((d) => d.statut === 'refusee').slice(0, 1).map((d) => `<p>${badge('Demande refusée', 'danger')} ${e(d.motif_refus || '')}</p>`).join('');
    $('[data-annuler]')?.addEventListener('click', (x) => executer(x.currentTarget, async () => { await appeler('gmb_cloture_annuler', { p_id: x.currentTarget.dataset.annuler }); await rendre(); }, 'Demande annulée : votre compte reste ouvert.'));
  };
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const iban = form.elements.iban.value.replace(/\s/g, '').toUpperCase(); const titulaire = form.elements.titulaire.value.trim();
      if (!/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(iban)) throw new ErreurGmb('Indiquez un IBAN valide.');
      if (titulaire.length < 3) throw new ErreurGmb('Indiquez le titulaire du compte de restitution.');
      if (!form.elements.compris.checked) throw new ErreurGmb('Confirmez avoir compris que la fermeture est définitive.');
      const code = await authentifier('Confirmer la fermeture', [['Restitution du solde', e(iban.replace(/(.{4})/g, '$1 ').trim())], ['Titulaire', e(titulaire)]], ctx.client.identifiant);
      if (!code) return;
      const r = await appeler('gmb_cloture_demander', { p_motif: form.elements.motif.value, p_precision: form.elements.precision.value.trim(), p_iban: iban, p_titulaire: titulaire, p_grille: code.grille, p_positions: code.positions });
      await refusSca(r);
      form.reset(); await rendre();
      message('Demande de fermeture enregistrée : vous serez prévenu à chaque étape.', 'succes');
    });
  });
  await rendre();
}

demarrerPage({ profil, coordonnees, 'mot-de-passe': motDePasse, 'code-secret': codeSecret, securite, appareils, 'notifications-parametres': notifications, apparence, fermeture });
