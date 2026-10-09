/* =============================================================================
   GerMoonBank (GMB) · js/app/history.js — Historique d'un compte (lot E1)
   Filtres, détail d'une opération, catégorie et note, contestation, export.
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, $$, e, date, page, parametre, montant, tableau, executer, message, iconeEc, pastille, aspectCompte,
  TYPES_COMPTE, CATEGORIES, LIBELLES_CATEGORIE, LIBELLES_TYPE_OPERATION, ligneOperation, operationsParJour, numeroLisible, ficheOperation, trierComptes } from './app.js';
import { lire, ErreurGmb } from '../donnees.js';
import { chemin, formaterMontant } from '../core.js';

const STATUTS_OPERATION_CSV = { comptabilisee: 'Effectuée', en_attente: 'En attente', refusee: 'Refusée', annulee: 'Annulée' };

/* Historique d'un compte : en-tête du compte (solde, numéro, IBAN s'il est attribué, actions),
   filtres, opérations groupées par jour ; une opération ouvre sa fiche complète. */
async function historique() {
  const ctx = await ouvrirEspace('comptes');
  const comptes = trierComptes(ctx.comptes.length ? await lire('comptes', { colonnes: 'id, type, libelle, numero, iban, solde, statut', dans: { id: ctx.comptes }, ordre: 'created_at', croissant: true }) : []);
  if (!comptes.length) { $('[data-entete]').innerHTML = '<p class="app-vide">Aucun compte.</p>'; return; }
  let compteId = comptes.some((k) => k.id === parametre('id')) ? parametre('id') : (comptes.find((k) => k.type === 'courant') || comptes[0]).id;
  const form = $('[data-form="filtres"]');
  form.elements.categorie.innerHTML = '<option value="">Toutes</option>' + CATEGORIES.map(([v, t]) => `<option value="${v}">${e(t)}</option>`).join('');
  let operations = [];
  let visibles = [];

  // Choix du compte : pastilles (seulement s'il y en a plusieurs)
  const choix = $('[data-choix-compte]');
  choix.innerHTML = comptes.length > 1 ? `<nav class="app-sous-nav" aria-label="Choisir le compte"><ul>${comptes.map((k) => `<li><a href="${page('comptes/courant.html', `?id=${k.id}`)}" data-compte="${k.id}"${k.id === compteId ? ' aria-current="page"' : ''}>${e(k.libelle || TYPES_COMPTE[k.type] || k.type)}</a></li>`).join('')}</ul></nav>` : '';
  choix.addEventListener('click', (x) => {
    const a = x.target.closest('[data-compte]');
    if (!a) return;
    x.preventDefault();
    compteId = a.dataset.compte;
    history.replaceState(null, '', a.href);
    $$('[data-compte]', choix).forEach((y) => (y === a ? y.setAttribute('aria-current', 'page') : y.removeAttribute('aria-current')));
    charger().catch((y) => message(y.message));
  });

  const charger = async () => {
    const jours = Number(form.elements.periode.value);
    const depuis = new Date(Date.now() - jours * 864e5).toISOString();
    operations = await lire('operations', { dans: { compte_id: [compteId] }, depuis: { date_operation: depuis }, ordre: 'date_operation', croissant: false, limite: 1000 });
    rendre();
  };
  const rendre = () => {
    const k = comptes.find((x) => x.id === compteId);
    const [ic, teinte] = aspectCompte(k.type);
    const actions = [['virement', 'Virer', page('comptes/virements.html')], ['recevoir', 'Recevoir', page('comptes/rib.html')], ['document', 'Relevés', page('documents/releves.html')]];
    $('[data-entete]').innerHTML = `<section class="app-compte-entete" aria-label="${e(k.libelle || TYPES_COMPTE[k.type] || 'Compte')}">
        <div class="app-compte-entete__haut">${pastille(ic, teinte, 'carre')}<span class="app-compte-entete__nom">${e(k.libelle || TYPES_COMPTE[k.type] || k.type)}</span></div>
        <p class="app-solde">${montant(k.solde)}</p>
        <span class="app-compte-entete__numero">n° ${e(numeroLisible(k.numero))}${k.iban ? ` · IBAN ${e(numeroLisible(k.iban))}` : ''}</span>
        <nav class="app-compte-entete__actions" aria-label="Actions sur le compte">${actions.map(([icone, libelle, adresse]) => `<a class="app-action" href="${adresse}"><span class="app-action__icone">${iconeEc(icone, 20)}</span><span class="app-action__libelle">${e(libelle)}</span></a>`).join('')}
          <button type="button" class="app-action" data-export><span class="app-action__icone">${iconeEc('tableur', 20)}</span><span class="app-action__libelle">Exporter</span></button></nav></section>`;
    const t = form.elements.texte.value.trim().toLowerCase();
    const sens = form.elements.sens.value;
    const categorie = form.elements.categorie.value;
    visibles = operations.filter((o) => (!t || `${o.libelle} ${o.contrepartie_nom || ''} ${o.motif || ''} ${o.reference || ''}`.toLowerCase().includes(t))
      && (!sens || (sens === 'debit' ? Number(o.montant) < 0 : Number(o.montant) > 0)) && (!categorie || o.categorie_code === categorie));
    $('[data-operations]').innerHTML = visibles.length
      ? `<div class="app-jours">${operationsParJour(visibles, (o) => ligneOperation(o, { action: `data-operation="${o.id}"`, avecJour: false }))}</div>`
      : '<p class="app-vide">Aucune opération sur cette période.</p>';
    $('[data-export]').disabled = !visibles.length;
  };

  $('[data-operations]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-operation]');
    if (b) ficheOperation(b.dataset.operation, ctx, charger).catch((y) => message(y.message));
  });
  // Export en tableur (CSV, séparateur « ; », ouvert directement par Excel ou LibreOffice)
  $('[data-entete]').addEventListener('click', (x) => {
    if (!x.target.closest('[data-export]')) return;
    const k = comptes.find((y) => y.id === compteId);
    const lignes = [['Date', 'Heure', 'Libellé', 'Type', 'Contrepartie', 'IBAN de la contrepartie', 'Motif', 'Catégorie', 'Montant (EUR)', 'Statut', 'Référence']]
      .concat(visibles.map((o) => { const d = new Date(o.date_operation || o.created_at);
        return [d.toLocaleDateString('fr-FR'), d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }), o.libelle, LIBELLES_TYPE_OPERATION[o.type] || o.type, o.contrepartie_nom || '', o.contrepartie_iban || '',
          o.motif || '', LIBELLES_CATEGORIE[o.categorie_code] || '', String(o.montant).replace('.', ','), STATUTS_OPERATION_CSV[o.statut] || o.statut, o.reference || '']; }));
    const csv = '\ufeff' + lignes.map((l) => l.map((c) => `"${String(c ?? '').replace(/"/g, '""')}"`).join(';')).join('\r\n');
    const lien = document.createElement('a');
    lien.href = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
    lien.download = `operations-${k.numero}.csv`;
    document.body.append(lien); lien.click(); lien.remove();
  });
  form.addEventListener('input', (x) => { if (x.target.name === 'periode') charger().catch((y) => message(y.message)); else rendre(); });
  document.addEventListener('gmb:discret', rendre);
  await charger();
}

/* =============================================================================
   Documents (lot E2a) : relevés, attestations, récapitulatif des intérêts,
   contrats, factures de cotisation et récapitulatif annuel des frais. Chaque
   document est construit à partir des données réelles et s'imprime ou
   s'enregistre en PDF depuis le navigateur.
   ========================================================================== */
const NOMS_FORMULES = { luna: 'Luna', halo: 'Halo', orbit: 'Orbit', eclipse: 'Éclipse', zenith: 'Zénith', pro_solo: 'Pro Solo', pro_plus: 'Pro Plus', business_start: 'Business Start', business_growth: 'Business Growth', business_scale: 'Business Scale' };
const MOIS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre'];
const PIED_DOCUMENT = 'GerMoonBank, édité par The Hub of Inspiration of Soccer (HubISoccer), RCCM RB/ABC/24 A 111814, Bénin. Établissement non agréé par l’ACPR : sommes non couvertes par la garantie des dépôts (FGDR).';
const eur = (n) => formaterMontant(Number(n || 0));
function documentImprimable(titre, corps) {
  return `<article class="app-document" data-document aria-label="${e(titre)}"><header class="app-document__entete"><p><strong>GerMoonBank</strong></p><h2>${e(titre)}</h2><p>Édité le ${e(new Date().toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' }))}</p></header>
    ${corps}<footer class="app-document__pied"><p>${e(PIED_DOCUMENT)}</p></footer></article>
    <p class="app-document__actions"><button type="button" class="gmb-bouton gmb-bouton--principal" data-imprimer>Imprimer ou enregistrer en PDF</button></p>`;
}
function brancherImpression(zone) { zone.querySelector('[data-imprimer]')?.addEventListener('click', () => window.print()); }
async function comptesDuClient(ctx) { return ctx.comptes.length ? lire('comptes', { colonnes: 'id, type, libelle, numero, iban, bic, solde, statut, ouvert_le', dans: { id: ctx.comptes }, ordre: 'created_at', croissant: true }) : []; }

async function documentsIndex() { await ouvrirEspace('documents'); }

async function releves() {
  const ctx = await ouvrirEspace('documents');
  const comptes = (await comptesDuClient(ctx)).filter((k) => k.statut !== 'cloture');
  const form = $('[data-form="releve"]');
  form.elements.compte.innerHTML = comptes.map((k) => `<option value="${k.id}">${e(k.libelle || TYPES_COMPTE[k.type])} · n° ${e(k.numero)}</option>`).join('');
  const maintenant = new Date();
  form.elements.mois.innerHTML = Array.from({ length: 12 }, (_, i) => new Date(maintenant.getFullYear(), maintenant.getMonth() - i, 1)).map((m) => `<option value="${m.getFullYear()}-${String(m.getMonth() + 1).padStart(2, '0')}">${MOIS[m.getMonth()]} ${m.getFullYear()}</option>`).join('');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const k = comptes.find((c) => c.id === form.elements.compte.value);
      if (!k) throw new ErreurGmb('Choisissez un compte.');
      const [a, m] = form.elements.mois.value.split('-').map(Number);
      const debut = new Date(Date.UTC(a, m - 1, 1)); const fin = new Date(Date.UTC(a, m, 1));
      const ops = (await lire('operations', { colonnes: 'libelle, montant, statut, date_operation, created_at', dans: { compte_id: [k.id] }, depuis: { created_at: debut.toISOString() }, ordre: 'created_at', croissant: true, limite: 5000 })).filter((o) => o.statut === 'comptabilisee');
      const duMois = ops.filter((o) => new Date(o.created_at) < fin);
      const apres = ops.filter((o) => new Date(o.created_at) >= fin).reduce((t, o) => t + Number(o.montant), 0);
      const soldeFin = Number(k.solde) - apres; const soldeDebut = soldeFin - duMois.reduce((t, o) => t + Number(o.montant), 0);
      const debits = duMois.filter((o) => Number(o.montant) < 0).reduce((t, o) => t + Number(o.montant), 0); const credits = duMois.filter((o) => Number(o.montant) > 0).reduce((t, o) => t + Number(o.montant), 0);
      const zone = $('[data-document-zone]');
      zone.innerHTML = documentImprimable(`Relevé de compte — ${MOIS[m - 1]} ${a}`, `<dl class="app-recap"><div><dt>Titulaire</dt><dd>${e(ctx.nom)}</dd></div><div><dt>Compte</dt><dd>${e(k.libelle || TYPES_COMPTE[k.type])} n° ${e(numeroLisible(k.numero))}</dd></div>${k.iban ? `<div><dt>IBAN</dt><dd>${e(numeroLisible(k.iban))}</dd></div>` : ''}
        <div><dt>Solde au 1<sup>er</sup> ${MOIS[m - 1]}</dt><dd>${e(eur(soldeDebut))}</dd></div><div><dt>Total des débits</dt><dd>${e(eur(debits))}</dd></div><div><dt>Total des crédits</dt><dd>${e(eur(credits))}</dd></div><div><dt>Solde en fin de mois</dt><dd><strong>${e(eur(soldeFin))}</strong></dd></div></dl>
        ${tableau('Opérations du mois', ['Date', 'Libellé', 'Montant'], duMois.map((o) => [date(o.date_operation || o.created_at), e(o.libelle), e(eur(o.montant))]), 'Aucune opération ce mois-ci.')}`);
      brancherImpression(zone);
    });
  });
}

async function attestations() {
  const ctx = await ouvrirEspace('documents');
  const comptes = (await comptesDuClient(ctx)).filter((k) => k.statut === 'actif');
  const form = $('[data-form="attestation"]');
  form.elements.compte.innerHTML = comptes.map((k) => `<option value="${k.id}">${e(k.libelle || TYPES_COMPTE[k.type])} · n° ${e(k.numero)}</option>`).join('');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const k = comptes.find((c) => c.id === form.elements.compte.value);
      if (!k) throw new ErreurGmb('Choisissez un compte.');
      const avecSolde = form.elements.type.value === 'solde';
      const zone = $('[data-document-zone]');
      zone.innerHTML = documentImprimable(avecSolde ? 'Attestation de solde' : 'Attestation de titularité de compte', `<p>GerMoonBank atteste que ${e(ctx.nom)} est titulaire, depuis le ${date(k.ouvert_le, 'long')}, du compte suivant :</p>
        <dl class="app-recap"><div><dt>Compte</dt><dd>${e(k.libelle || TYPES_COMPTE[k.type])}</dd></div><div><dt>Numéro de compte</dt><dd>${e(numeroLisible(k.numero))}</dd></div>${k.iban ? `<div><dt>IBAN</dt><dd>${e(numeroLisible(k.iban))}</dd></div>${k.bic ? `<div><dt>BIC</dt><dd>${e(k.bic)}</dd></div>` : ''}` : ''}<div><dt>Statut</dt><dd>Actif</dd></div>
        ${avecSolde ? `<div><dt>Solde au ${e(new Date().toLocaleDateString('fr-FR', { day: 'numeric', month: 'long', year: 'numeric' }))}</dt><dd><strong>${e(eur(k.solde))}</strong></dd></div>` : ''}</dl>`);
      brancherImpression(zone);
    });
  });
}

async function fiscaux() {
  const ctx = await ouvrirEspace('documents');
  const comptes = (await comptesDuClient(ctx)).filter((k) => k.type === 'livret');
  const form = $('[data-form="fiscal"]');
  const annee = new Date().getFullYear();
  form.elements.annee.innerHTML = [annee - 1, annee].map((a) => `<option value="${a}"${a === annee - 1 ? ' selected' : ''}>${a}</option>`).join('');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const a = Number(form.elements.annee.value);
      const interets = comptes.length ? (await lire('interets', { colonnes: 'compte_id, jour, montant', dans: { compte_id: comptes.map((k) => k.id) }, depuis: { jour: `${a}-01-01` }, limite: 5000 })).filter((i) => i.jour < `${a + 1}-01-01`) : [];
      const parMois = Array(12).fill(0); for (const i of interets) parMois[Number(i.jour.slice(5, 7)) - 1] += Number(i.montant);
      const total = parMois.reduce((t, v) => t + v, 0);
      const zone = $('[data-document-zone]');
      zone.innerHTML = documentImprimable(`Récapitulatif des intérêts ${a}`, `<p>Intérêts versés en ${a} à ${e(ctx.nom)} sur ${comptes.length ? `le Livret n° ${e(comptes.map((k) => k.numero).join(', '))}` : 'aucun Livret'} : <strong>${e(eur(total))}</strong>.</p>
        ${tableau('Intérêts par mois', ['Mois', 'Intérêts'], parMois.map((v, i) => [e(MOIS[i]), e(eur(v))]).filter((_, i) => parMois[i] > 0 || total === 0).slice(0, 12), 'Aucun intérêt versé cette année.')}
        <p>Ce récapitulatif n’est pas un imprimé fiscal unique (IFU) : conservez-le pour votre déclaration de revenus.</p>`);
      brancherImpression(zone);
    });
  });
}

async function contrats() {
  const ctx = await ouvrirEspace('documents');
  const [moi, demandes] = await Promise.all([lire('clients', { colonnes: 'id, formule_code, ouvert_le, segment', egal: { id: ctx.client.id }, unique: true }), lire('demandes', { egal: { type: 'pret_personnel' }, ordre: 'created_at', croissant: false })]);
  const acceptees = demandes.filter((d) => d.acceptee_le);
  const zone = $('[data-document-zone]');
  zone.innerHTML = documentImprimable('Vos contrats', `<h3>Convention de compte</h3><dl class="app-recap"><div><dt>Titulaire</dt><dd>${e(ctx.nom)}</dd></div><div><dt>Formule</dt><dd>${e(NOMS_FORMULES[moi?.formule_code] || moi?.formule_code || '—')}</dd></div><div><dt>Compte ouvert le</dt><dd>${date(moi?.ouvert_le, 'long')}</dd></div></dl>
    <p>Documents contractuels en vigueur : <a href="${chemin('public/legal/cgu.html')}">conditions générales d’utilisation</a>, <a href="${chemin('public/legal/cgv.html')}">conditions générales de vente</a>, <a href="${chemin('public/tarifs/grille-tarifaire.html')}">grille tarifaire</a>, <a href="${chemin('public/legal/tarification.html')}">document d’information tarifaire</a>.</p>
    <h3>Offres de prêt acceptées</h3>${tableau('Offres de prêt acceptées', ['Référence', 'Montant', 'Taux débiteur', 'TAEG', 'Mensualité', 'Acceptée le'], acceptees.map((d) => [e(d.reference), e(`${eur(d.montant)} sur ${d.duree_mois} mois`), e(`${String(d.taux_debiteur).replace('.', ',')} %`), e(`${String(d.taeg).replace('.', ',')} %`), e(eur(d.mensualite)), date(d.acceptee_le, 'long')]), 'Aucune offre de prêt acceptée.')}`);
  brancherImpression(zone);
}

async function factures() {
  const ctx = await ouvrirEspace('documents');
  const rendre = async () => {
    const cotisations = await lire('cotisations', { ordre: 'mois', croissant: false, limite: 36 });
    $('[data-cotisations]').innerHTML = tableau('Vos cotisations', ['Mois', 'Libellé', 'Montant', 'Statut'], cotisations.map((c) => [e(`${MOIS[Number(c.mois.slice(5, 7)) - 1]} ${c.mois.slice(0, 4)}`), e(c.libelle), e(eur(c.montant)), badge(c.statut === 'prelevee' ? `Prélevée le ${date(c.prelevee_le)}` : 'Impayée : représentée chaque jour', c.statut === 'prelevee' ? 'succes' : 'danger')]),
      'Aucune cotisation : la première est prélevée le mois qui suit l’ouverture, si votre formule est payante.');
  };
  const form = $('[data-form="frais"]');
  const annee = new Date().getFullYear();
  form.elements.annee.innerHTML = [annee - 1, annee].map((a) => `<option value="${a}"${a === annee - 1 ? ' selected' : ''}>${a}</option>`).join('');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const a = Number(form.elements.annee.value);
      const ids = (await comptesDuClient(ctx)).map((k) => k.id);
      const frais = ids.length ? (await lire('operations', { colonnes: 'libelle, montant, statut, created_at', dans: { compte_id: ids, type: ['frais'] }, depuis: { created_at: `${a}-01-01` }, limite: 5000 })).filter((o) => o.statut === 'comptabilisee' && o.created_at < `${a + 1}-01-01`) : [];
      const total = frais.reduce((t, o) => t - Number(o.montant), 0);
      const zone = $('[data-document-zone]');
      zone.innerHTML = documentImprimable(`Récapitulatif annuel des frais ${a}`, `<p>Total des frais prélevés en ${a} à ${e(ctx.nom)} : <strong>${e(eur(total))}</strong>.</p>
        ${tableau('Frais prélevés', ['Date', 'Libellé', 'Montant'], frais.map((o) => [date(o.created_at), e(o.libelle), e(eur(-o.montant))]), 'Aucun frais prélevé cette année.')}`);
      brancherImpression(zone);
    });
  });
  await rendre();
}

demarrerPage({ historique, 'documents': documentsIndex, releves, attestations, fiscaux, contrats, factures });
