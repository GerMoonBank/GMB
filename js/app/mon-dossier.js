/* =============================================================================
   GerMoonBank (GMB) · js/app/mon-dossier.js — Espace Mon Dossier (version 2026-10-07)
   Suivi de la demande, pièces, échanges avec le conseiller (messages et
   rendez-vous), signatures, identifiant bancaire. Espace « dossier » : il ne
   donne jamais accès à un compte bancaire.
   ========================================================================== */
import { $, $$, e, date, parametre, message, executer, tableau, badge, demander } from './app.js';
import { chemin, formaterMontant, icone, logoSVG } from '../core.js';
import { client, session, espaceDe, lire, appeler, inserer, deposerFichier, messageErreur, ErreurGmb, oublierContexte } from '../donnees.js';
import { controlerFichier, justificatifTropAncien, empreinteFichier, erreurChamp, copier } from '../forms.js';

const ETATS = { brouillon: 'À terminer', depose: 'Déposée', en_verification: 'En vérification', incomplet: 'À compléter', analyse_conformite: 'En vérification complémentaire', valide: 'Validée', compte_ouvert: 'Compte ouvert',
  refuse: 'Refusée', abandonne: 'Abandonnée', archive: 'Archivée', demande_deposee: 'Déposée', analyse: 'En analyse', offre_emise: 'Offre à accepter', delai_legal: 'Offre acceptée', acceptee: 'Acceptée', fonds_debloques: 'Fonds versés', renonciation: 'Rétractation' };
const PIECES = { piece_identite: 'Pièce d’identité', selfie: 'Selfie', justificatif_domicile: 'Justificatif de domicile', justificatif_revenus: 'Justificatif de revenus', kbis: 'Justificatif d’immatriculation', statuts: 'Statuts', beneficiaires_effectifs: 'Bénéficiaires effectifs', lien_filiation: 'Lien avec l’enfant', autre: 'Autre document' };
const STATUTS_PIECE = { attendue: ['À fournir', 'neutre'], deposee: ['Reçue', 'neutre'], en_controle: ['En contrôle', 'neutre'], validee: ['Validée', 'succes'], refusee: ['À remplacer', 'danger'], facultative: ['Facultative', 'neutre'] };
const DATEES = new Set(['justificatif_domicile', 'justificatif_revenus', 'kbis']);
const CONSENTEMENTS = { cgu: 'Conditions générales d’utilisation', confidentialite: 'Politique de confidentialité', biometrie: 'Comparaison de votre photo à votre pièce d’identité', marketing: 'Actualités par e-mail', cookies: 'Cookies', ficp: 'Consultation du FICP', signature_convention: 'Signature de votre demande et de la convention' };
const RUBRIQUES = [['suivi', 'Suivi', 'index.html', 'dossier'], ['documents', 'Documents', 'documents.html', 'dossier'], ['echanges', 'Échanges', 'kyc.html', 'support'], ['signatures', 'Signatures', 'signature.html', 'cadenas'], ['identifiant', 'Identifiant', 'validation.html', 'utilisateur']];
const lien = (adresse, d) => chemin(`app/mon-dossier/${adresse}${d ? `?dossier=${d.id}` : ''}`);

async function deconnecter() {
  try { await (await client()).auth.signOut({ scope: 'local' }); } catch { /* déconnexion locale malgré tout */ }
  oublierContexte();
  location.replace(chemin('auth/mon-dossier.html'));
}

/** Ouvre une page de l'Espace Mon Dossier : session « dossier », dossier choisi, cadre, inactivité. */
async function ouvrirDossier(rubrique) {
  const marque = document.querySelector('.app-entete__marque'); if (marque && !marque.querySelector('svg')) marque.innerHTML = `${logoSVG({ titre: 'GerMoonBank' })} <span class="app-entete__espace">Espace Mon Dossier</span>`;

  const s = await session();
  if (!s || espaceDe(s) !== 'dossier') { location.replace(chemin(`auth/mon-dossier.html?raison=session&retour=${encodeURIComponent(location.pathname + location.search)}`)); throw new ErreurGmb('Session absente'); }
  const dossiers = await lire('dossiers', { colonnes: 'id, reference, type, segment, formule_code, etat, personne_id, depose_le, ouvert_le, created_at', ordre: 'created_at', croissant: false });
  const d = dossiers.find((x) => x.id === parametre('dossier')) || dossiers.find((x) => !['abandonne', 'archive'].includes(x.etat)) || dossiers[0] || null;
  $('[data-app-nav]').innerHTML = `<ul class="app-nav__liste">${RUBRIQUES.map(([cle, libelle, adresse, ic]) => `<li><a class="app-nav__lien" href="${lien(adresse, d)}"${cle === rubrique ? ' aria-current="page"' : ''}>${icone(ic)}<span>${e(libelle)}</span></a></li>`).join('')}</ul>`;
  $('[data-app-nav] [aria-current="page"]')?.scrollIntoView({ block: 'nearest', inline: 'center' });
  $('[data-app-identite]').textContent = s.user.email || '';
  $('[data-deconnexion]').addEventListener('click', deconnecter);
  const choix = $('[data-choix-dossier]');
  if (choix && dossiers.length > 1) {
    choix.hidden = false;
    choix.innerHTML = `<label class="gmb-champ__libelle" for="dossier-choisi">Demande</label><div class="gmb-liste"><select class="gmb-saisie" id="dossier-choisi">${dossiers.map((x) => `<option value="${x.id}"${x.id === d?.id ? ' selected' : ''}>${e(x.reference)} · ${e(ETATS[x.etat] || x.etat)}</option>`).join('')}</select></div>`;
    $('#dossier-choisi').addEventListener('change', (x) => { location.href = `${location.pathname}?dossier=${x.target.value}`; });
  }
  let limite = 15;
  try { limite = Number((await lire('parametres_securite', { colonnes: 'cle, valeur', egal: { cle: 'mon_dossier_inactivite_minutes' }, unique: true }))?.valeur) || 15; } catch { /* 15 minutes par défaut */ }
  let minuteur; const relancer = () => { clearTimeout(minuteur); minuteur = setTimeout(() => deconnecter(), limite * 60_000); };
  ['pointerdown', 'keydown', 'scroll', 'touchstart'].forEach((t) => addEventListener(t, relancer, { passive: true }));
  relancer();
  return { s, dossiers, d };
}
const AUCUN = `<p class="app-vide">Aucune demande pour le moment.</p><p><a class="gmb-bouton gmb-bouton--principal" href="${chemin('public/inscription/index.html')}">Ouvrir un compte</a></p>`;

/* Suivi ------------------------------------------------------------------- */
async function suivi() {
  const { d } = await ouvrirDossier('suivi');
  const zone = $('[data-suivi]');
  if (!d) { zone.innerHTML = AUCUN; return; }
  const [pieces, versement, evenements, banque] = await Promise.all([lire('dossier_pieces', { colonnes: 'type, statut', egal: { dossier_id: d.id } }), lire('premiers_versements', { egal: { dossier_id: d.id }, unique: true }), lire('dossier_evenements', { egal: { dossier_id: d.id }, ordre: 'created_at', croissant: false }),
    lire('parametres_banque', { colonnes: 'cle, valeur' })]);
  const collecte = Object.fromEntries(banque.map((x) => [x.cle.replace('collecte_', ''), x.valeur]));
  const etapes = ['Demande envoyée', 'Vérification', 'Décision', d.type === 'credit' ? 'Offre' : 'Compte ouvert'];
  const rang = { brouillon: -1, depose: 0, demande_deposee: 0, en_verification: 1, incomplet: 1, analyse_conformite: 1, analyse: 1, valide: 2, refuse: 2, offre_emise: 3, delai_legal: 3, acceptee: 3, fonds_debloques: 3, compte_ouvert: 3, archive: 3 }[d.etat] ?? 0;
  const refusees = pieces.filter((p) => ['refusee', 'attendue'].includes(p.statut));
  // La demande est déposée et en cours d'étude (ni brouillon, ni complément attendu, ni close)
  const enEtude = ['depose', 'en_verification', 'analyse_conformite', 'demande_deposee', 'analyse'].includes(d.etat);
  let action = '';
  if (d.etat === 'brouillon') action = `Votre demande n’est pas encore déposée : <a href="${chemin(`public/inscription/index.html?reprendre=${d.id}`)}">reprenez-la là où vous en étiez</a>.`;
  else if (['refuse', 'refusee'].includes(d.etat)) action = `Votre demande n’a pas été acceptée. Le message de GerMoonBank est dans vos <a href="${lien('kyc.html', d)}">échanges</a>. ${versement ? 'N’effectuez pas le premier versement ; s’il est déjà parti, il vous est remboursé sur le compte d’origine.' : ''}`;
  else if (['abandonne', 'archive'].includes(d.etat) && d.type === 'ouverture' && !d.ouvert_le) action = 'Cette demande est close. Vous pouvez en déposer une nouvelle à tout moment.';
  else if (refusees.length && ['incomplet', 'brouillon'].includes(d.etat)) action = `${refusees.length} document${refusees.length > 1 ? 's' : ''} à fournir ou à remplacer : <a href="${lien('documents.html', d)}">déposer</a>.`;
  else if (d.etat === 'incomplet') action = `Votre conseiller attend une information : <a href="${lien('kyc.html', d)}">lire ses messages</a>.`;
  else if (versement?.statut === 'attendu' && enEtude) action = `Nous attendons votre premier versement de ${e(formaterMontant(versement.montant))}, avec la référence ${e(d.reference)}. Les coordonnées du virement sont rappelées ci-dessous.`;
  else if (enEtude) action = 'Votre demande est à l’étude : vous serez informé ici de chaque étape. Aucune action n’est attendue de votre part pour le moment.';
  else if (d.etat === 'offre_emise') action = `Votre offre de prêt vous attend : <a href="${lien('signature.html', d)}">la consulter</a>.`;
  else if (['compte_ouvert', 'archive'].includes(d.etat)) action = `Votre compte est ouvert : <a href="${lien('validation.html', d)}">affichez votre identifiant</a> pour activer votre accès.`;
  zone.innerHTML = `<header class="gmb-pile gmb-pile--serree"><h2 class="gmb-section__titre gmb-section__titre--moyen">${e(d.reference)}</h2><p>${badge(ETATS[d.etat] || d.etat, ['compte_ouvert', 'valide', 'fonds_debloques'].includes(d.etat) ? 'succes' : d.etat === 'refuse' ? 'danger' : 'neutre')} · ${e(d.type === 'credit' ? 'Prêt personnel' : `Ouverture de compte ${d.segment}`)}</p></header>
    <ol class="gmb-frise-etapes" aria-label="Avancement">${etapes.map((t, i) => `<li data-fait="${i < rang || (i === rang && ['compte_ouvert', 'fonds_debloques'].includes(d.etat))}"${i === rang ? ' aria-current="step"' : ''}><span class="gmb-frise-etapes__numero">${i + 1}</span><span>${e(t)}</span></li>`).join('')}</ol>
    ${action ? `<div class="gmb-encadre gmb-encadre--neutre" role="status">${icone('info')}<p>${action}</p></div>` : ''}
    ${versement && !(versement.statut === 'attendu' && !enEtude && d.etat !== 'incomplet' && d.etat !== 'brouillon') ? `<p>Premier versement : ${e(formaterMontant(versement.montant))} · ${badge({ attendu: 'Attendu', recu: 'Reçu', credite: 'Crédité sur votre compte', en_revue: 'En vérification', rembourse: 'Remboursé' }[versement.statut] || versement.statut, ['recu', 'credite'].includes(versement.statut) ? 'succes' : 'neutre')}</p>` : ''}
    ${versement?.statut === 'attendu' && collecte.iban && (enEtude || d.etat === 'incomplet') ? `<section class="gmb-carte gmb-pile gmb-pile--serree" aria-labelledby="t-virement"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-virement">Votre virement</h2>
      <p>À faire depuis un compte à votre nom${d.segment === 'business' ? ' de société' : ''}. Votre compte est ouvert dès sa réception et la vérification de vos documents.</p>
      <dl class="app-recap"><div><dt>Bénéficiaire</dt><dd>${e(collecte.titulaire || '—')}</dd></div>
        <div><dt>IBAN</dt><dd><code data-iban>${e(collecte.iban.replace(/(.{4})/g, '$1 ').trim())}</code> <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-copier-iban>Copier</button></dd></div>
        ${collecte.bic ? `<div><dt>BIC</dt><dd><code>${e(collecte.bic)}</code></dd></div>` : ''}${collecte.banque ? `<div><dt>Banque</dt><dd>${e(collecte.banque)}</dd></div>` : ''}
        <div><dt>Montant</dt><dd>${e(formaterMontant(versement.montant))}</dd></div>
        <div><dt>Référence à indiquer, obligatoirement</dt><dd><code data-reference>${e(d.reference)}</code> <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-copier-reference>Copier</button></dd></div></dl></section>` : ''}
    <section aria-labelledby="t-historique"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-historique">Historique</h2>
      <ol class="app-fil">${evenements.map((x) => `<li><strong>${e(ETATS[x.etat_apres] || x.etat_apres || '')}</strong> — ${e(x.libelle_client || '')} <small>${date(x.created_at, 'long')}</small></li>`).join('') || '<li>Votre demande vient d’être créée.</li>'}</ol></section>`;
  zone.querySelector('[data-copier-iban]')?.addEventListener('click', (x) => copier(collecte.iban, x.currentTarget));
  zone.querySelector('[data-copier-reference]')?.addEventListener('click', (x) => copier(d.reference, x.currentTarget));
}

/* Documents --------------------------------------------------------------- */
async function documents() {
  const { d } = await ouvrirDossier('documents');
  const zone = $('[data-pieces]');
  if (!d) { zone.innerHTML = AUCUN; return; }
  const modifiable = ['brouillon', 'incomplet'].includes(d.etat);
  const rendre = async () => {
    const pieces = await lire('dossier_pieces', { colonnes: 'id, type, statut, motif_refus_client, date_document, depose_le', egal: { dossier_id: d.id }, ordre: 'type', croissant: true });
    zone.innerHTML = pieces.map((p) => {
      const deposable = modifiable && ['attendue', 'refusee', 'facultative'].includes(p.statut);
      return `<div class="gmb-carte gmb-pile gmb-pile--serree" data-type="${p.type}"><h2 class="gmb-section__titre gmb-section__titre--moyen">${e(PIECES[p.type] || p.type)}</h2>
        <p>${badge(...(STATUTS_PIECE[p.statut] || [p.statut, 'neutre']))}${p.depose_le ? ` · reçue le ${date(p.depose_le, 'long')}` : ''}</p>
        ${p.statut === 'refusee' && p.motif_refus_client ? `<p><strong>Motif :</strong> ${e(p.motif_refus_client)}</p>` : ''}
        ${deposable ? `<div class="gmb-champ"><label class="gmb-champ__libelle" for="f-${p.type}">Choisir le fichier</label><input class="gmb-saisie" id="f-${p.type}" type="file" accept="application/pdf,image/jpeg,image/png,image/heic"${p.type === 'selfie' ? ' capture="user"' : ''}></div>
          ${DATEES.has(p.type) ? `<div class="gmb-champ"><label class="gmb-champ__libelle" for="date-${p.type}">Date du document</label><input class="gmb-saisie" id="date-${p.type}" type="date"></div>` : ''}
          <p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-envoyer="${p.type}">Envoyer</button></p>` : ''}</div>`;
    }).join('') || '<p class="app-vide">Aucun document demandé.</p>';
    $('[data-etat-documents]').textContent = modifiable ? 'Vous pouvez déposer ou remplacer les documents signalés.' : 'Votre demande est à l’étude : les documents ne peuvent plus être modifiés, sauf si votre conseiller vous le demande.';
  };
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('[data-envoyer]');
    if (!b) return;
    const type = b.dataset.envoyer; const bloc = b.closest('[data-type]');
    executer(b, async () => {
      const fichier = $('input[type="file"]', bloc).files?.[0];
      const probleme = controlerFichier(fichier);
      if (probleme) throw new ErreurGmb(probleme);
      let dateDocument = null;
      if (DATEES.has(type)) { dateDocument = $(`#date-${type}`, bloc).value; if (!dateDocument || justificatifTropAncien(dateDocument, 3)) throw new ErreurGmb('Ce document doit dater de moins de 3 mois.'); }
      const cheminFichier = await deposerFichier('gmb-pieces', fichier);
      await appeler('gmb_dossier_piece_deposer', { p_dossier: d.id, p_type: type, p_chemin: cheminFichier, p_empreinte: await empreinteFichier(fichier), p_date_document: dateDocument });
      await rendre();
    }, 'Document reçu : votre conseiller en est informé.');
  });
  await rendre();
}

/* Échanges : messages et rendez-vous ------------------------------------- */
async function echanges() {
  const { d } = await ouvrirDossier('echanges');
  if (!d) { $('[data-messages]').innerHTML = AUCUN; $('[data-form="message"]').hidden = true; $('[data-rdv]').hidden = true; return; }
  const rendre = async () => {
    const [messages, rdv] = await Promise.all([lire('dossier_messages', { egal: { dossier_id: d.id }, ordre: 'created_at', croissant: true }), lire('dossier_rendez_vous', { egal: { dossier_id: d.id }, ordre: 'debut', croissant: false })]);
    $('[data-messages]').innerHTML = messages.length ? `<ol class="app-fil app-fil--messages">${messages.map((m) => `<li class="app-fil__message app-fil__message--${e(m.auteur)}"><p>${e(m.contenu)}</p><small>${e(m.auteur === 'client' ? 'Vous' : m.auteur === 'conseiller' ? 'Votre conseiller' : 'GerMoonBank')} · ${date(m.created_at, 'long')}</small></li>`).join('')}</ol>` : '<p class="app-vide">Aucun message pour le moment.</p>';
    $('[data-liste-rdv]').innerHTML = tableau('Vos rendez-vous', ['Date', 'Canal', 'Statut'], rdv.map((r) => [date(r.debut, 'long') + ' à ' + new Date(r.debut).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }), e(r.canal === 'video' ? 'Vidéo' : 'Téléphone'),
      badge({ demande: 'Demandé', confirme: 'Confirmé', annule: 'Annulé', termine: 'Terminé' }[r.statut] || r.statut, r.statut === 'confirme' ? 'succes' : 'neutre')]), 'Aucun rendez-vous.');
  };
  const form = $('[data-form="message"]');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const contenu = form.elements.contenu.value.trim();
      if (contenu.length < 2) throw new ErreurGmb('Écrivez votre message.');
      if (contenu.length > 2000) throw new ErreurGmb('Votre message ne doit pas dépasser 2 000 caractères.');
      await inserer('dossier_messages', { dossier_id: d.id, contenu });
      form.reset(); await rendre();
    }, 'Message envoyé à votre conseiller.');
  });
  $('[data-demander-rdv]').addEventListener('click', (x) => executer(x.currentTarget, async () => {
    const r = await demander('Demander un rendez-vous', [{ nom: 'quand', libelle: 'Date et heure souhaitées', type: 'datetime-local', requis: true, aide: 'Du lundi au vendredi, de 9 h à 18 h.' }, { nom: 'canal', libelle: 'Comment ?', options: [['telephone', 'Par téléphone'], ['video', 'En vidéo']] }], { valider: 'Demander' });
    if (!r) return;
    const debut = new Date(r.quand);
    if (Number.isNaN(debut.getTime()) || debut < new Date(Date.now() + 3600e3)) throw new ErreurGmb('Choisissez un créneau au moins une heure à l’avance.');
    if ([0, 6].includes(debut.getDay()) || debut.getHours() < 9 || debut.getHours() >= 18) throw new ErreurGmb('Choisissez un créneau du lundi au vendredi, de 9 h à 18 h.');
    await inserer('dossier_rendez_vous', { dossier_id: d.id, debut: debut.toISOString(), canal: r.canal });
    await rendre();
  }, 'Rendez-vous demandé : votre conseiller le confirmera.'));
  await rendre();
}

/* Signatures --------------------------------------------------------------- */
async function signatures() {
  const { s, d } = await ouvrirDossier('signatures');
  const consentements = await lire('consentements', { colonnes: 'type, version, accorde, horodatage', ordre: 'horodatage', croissant: false });
  $('[data-consentements]').innerHTML = tableau('Vos accords', ['Accord', 'Version', 'Réponse', 'Date'], consentements.map((c) => [e(CONSENTEMENTS[c.type] || c.type), e(c.version || '—'), badge(c.accorde ? 'Accordé' : 'Refusé', c.accorde ? 'succes' : 'neutre'), date(c.horodatage, 'long')]), 'Aucun accord enregistré.');
  const zone = $('[data-offre]');
  if (!d || d.type !== 'credit') { zone.hidden = true; return; }
  const rendre = async () => {
    const [dd, c] = await Promise.all([lire('dossiers', { colonnes: 'etat', egal: { id: d.id }, unique: true }), lire('dossier_credit', { egal: { dossier_id: d.id }, unique: true })]);
    zone.hidden = !c?.offre_emise_le;
    if (zone.hidden) return;
    zone.innerHTML = `<h2 class="gmb-section__titre gmb-section__titre--moyen">Votre offre de prêt</h2><dl class="app-recap"><div><dt>Montant</dt><dd>${e(formaterMontant(c.montant))} sur ${e(c.duree_mois)} mois</dd></div>
      <div><dt>Taux débiteur fixe</dt><dd>${e(String(c.taux_debiteur).replace('.', ','))} %</dd></div><div><dt>TAEG fixe</dt><dd>${e(String(c.taeg).replace('.', ','))} %</dd></div><div><dt>Mensualité</dt><dd>${e(formaterMontant(c.mensualite))}</dd></div>
      <div><dt>Coût total</dt><dd>${e(formaterMontant(c.cout_total))}</dd></div></dl>
      ${dd.etat === 'offre_emise' ? '<p><button type="button" class="gmb-bouton gmb-bouton--principal" data-accepter>Accepter l’offre</button></p>' : ''}
      ${dd.etat === 'delai_legal' && c.retractation_fin && new Date(c.retractation_fin) > new Date() ? `<p>Vous pouvez vous rétracter jusqu’au ${date(c.retractation_fin, 'long')}.</p><p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-retracter>Me rétracter</button></p>` : ''}`;
    zone.querySelector('[data-accepter]')?.addEventListener('click', (x) => executer(x.currentTarget, async () => { await appeler('gmb_credit_accepter', { p_id: d.id }); await rendre(); }, 'Offre acceptée : vous disposez de 14 jours pour vous rétracter.'));
    zone.querySelector('[data-retracter]')?.addEventListener('click', (x) => executer(x.currentTarget, async () => { await appeler('gmb_credit_retracter', { p_id: d.id }); await rendre(); }, 'Rétractation enregistrée.'));
  };
  await rendre();
}

/* Identifiant --------------------------------------------------------------- */
async function identifiant() {
  const { s, d } = await ouvrirDossier('identifiant');
  const zone = $('[data-identifiant]');
  if (!d) { zone.innerHTML = AUCUN; return; }
  if (!['compte_ouvert', 'archive'].includes(d.etat)) { zone.innerHTML = '<p>Votre identifiant bancaire sera affiché ici dès l’ouverture de votre compte : revenez dans cet espace après la validation de votre demande.</p>'; return; }
  // La suite : activer l'accès (première fois) ou se connecter (accès déjà activé). L'identifiant passe
  // dans la partie de l'adresse qui ne quitte jamais le navigateur (après le signe #).
  const suite = (r, id) => (r.acces_active
    ? `<p><a class="gmb-bouton gmb-bouton--principal" href="${chemin('auth/connexion.html')}">Se connecter à l’Espace client</a></p>`
    : `<p><a class="gmb-bouton gmb-bouton--principal" href="${chemin('auth/premiere-connexion.html')}${id ? `#identifiant=${encodeURIComponent(id)}` : ''}">Activer mon accès à l’Espace client</a></p>
       <p class="gmb-champ__aide">Un code vous sera envoyé par e-mail, puis vous choisirez votre code secret de 8 chiffres.</p>`);
  const montrer = async (reveler) => {
    const r = await appeler('gmb_dossier_identifiant', { p_dossier: d.id, p_reveler: reveler });
    const id = r?.identifiant || '';
    if (!r?.masque) {
      zone.innerHTML = `<p>Voici votre identifiant bancaire. Avec votre code secret, il ouvre votre Espace client.</p>
        <p class="app-solde"><code>${e(id.replace(/(\d{4})(\d{4})/, '$1 $2'))}</code> <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-copier-identifiant>Copier</button></p>
        <p>Notez-le en lieu sûr. GerMoonBank ne vous le demandera jamais par e-mail ni par téléphone. Vous pourrez l’afficher de nouveau ici en confirmant votre mot de passe.</p>${suite(r, id)}`;
      zone.querySelector('[data-copier-identifiant]').addEventListener('click', (x) => copier(id, x.currentTarget));
      return;
    }
    zone.innerHTML = `<p>Votre identifiant bancaire : <strong><code>${e(id)}</code></strong></p>
      <p>Il est masqué par sécurité. Pour l’afficher en entier, confirmez le mot de passe de votre Espace Mon Dossier.</p>
      <form class="gmb-pile gmb-pile--serree" data-form="reveler" novalidate>
        <div class="gmb-champ"><label class="gmb-champ__libelle" for="mdp-identifiant">Mot de passe de votre Espace Mon Dossier</label>
          <input class="gmb-saisie" id="mdp-identifiant" name="mdp" type="password" autocomplete="current-password" aria-describedby="mdp-identifiant-erreur"><p class="gmb-champ__erreur" id="mdp-identifiant-erreur" hidden></p></div>
        <div class="gmb-rangee"><button type="submit" class="gmb-bouton gmb-bouton--secondaire">Afficher mon identifiant</button></div>
      </form>${suite(r, '')}`;
    const form = zone.querySelector('[data-form="reveler"]');
    form.addEventListener('submit', (x) => {
      x.preventDefault();
      executer(form.querySelector('[type=submit]'), async () => {
        const mdp = form.elements.mdp.value;
        if (!erreurChamp(form.elements.mdp, mdp ? '' : 'Saisissez votre mot de passe.')) return;
        const c = await client();
        const { error } = await c.auth.signInWithPassword({ email: s.user.email, password: mdp });
        form.elements.mdp.value = '';
        if (error) {
          if (error.code === 'invalid_credentials' || /invalid login credentials/i.test(error.message || '')) { erreurChamp(form.elements.mdp, 'Mot de passe incorrect.'); return; }
          throw error;
        }
        oublierContexte();
        await montrer(true);
      });
    });
  };
  zone.innerHTML = '<p>Votre compte est ouvert. Votre identifiant de 8 chiffres vous permet d’accéder à votre Espace client.</p><p><button type="button" class="gmb-bouton gmb-bouton--principal" data-afficher>Afficher mon identifiant</button></p>';
  $('[data-afficher]').addEventListener('click', (x) => executer(x.currentTarget, () => montrer(false)));
}

document.addEventListener('submit', (x) => x.preventDefault());
const CONTROLEURS = { 'dossier-suivi': suivi, 'dossier-documents': documents, 'dossier-echanges': echanges, 'dossier-signatures': signatures, 'dossier-identifiant': identifiant };
(async () => {
  const c = CONTROLEURS[document.body.dataset.app];
  if (!c) return;
  try { await c(); } catch (x) { if (!/Session absente/.test(x?.message)) message(messageErreur(x)); }
})();
