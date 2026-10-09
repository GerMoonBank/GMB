/* =============================================================================
   GerMoonBank (GMB) · js/app/dashboard.js — Accueil de l'Espace client
   Version 5 (application bancaire « Nuit ») : solde global et comptes en
   pastilles, actions rapides, virements en attente, dernières opérations
   (fiche complète au toucher), mois en cours (dépenses, budget, répartition par
   catégorie), notifications.
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, e, date, page, montant, executer, demander, message, iconeEc, pastille, ligneOperation, ficheOperation,
  aspectOperation, trierComptes, STATUTS_VIREMENT, TYPES_COMPTE, LIBELLES_CATEGORIE, LIBELLES_TYPE_OPERATION } from './app.js';
import { lire, appeler, inserer, modifier } from '../donnees.js';
import { formaterMontant } from '../core.js';

/* Actions rapides : la première, « Ajouter » (recevoir de l'argent), porte la couleur d'action */
const ACTIONS = [['ajouter', 'Ajouter', 'comptes/rib.html'], ['virement', 'Virer', 'comptes/virements.html'], ['carte', 'Cartes', 'cartes/index.html'], ['epargne', 'Épargner', 'epargne/index.html']];
/* Mouvements entre vos propres comptes : ni dépense ni revenu */
const HORS_BUDGET = new Set(['interne', 'arrondi']);
const NOM_MOIS = new Intl.DateTimeFormat('fr-FR', { month: 'long' });
const NOMS_COURTS = { courant: 'Courant', livret: 'Livret', coffre: 'Coffre', devise: 'Devise', crypto: 'Crypto', titres: 'Titres', jeune: 'Jeunes', pro: 'Pro', business: 'Business' };

const nomCourt = (k) => (k.libelle && k.libelle.length <= 18 ? k.libelle : NOMS_COURTS[k.type] || TYPES_COMPTE[k.type] || 'Compte');
const debutDuMois = () => { const d = new Date(); return new Date(d.getFullYear(), d.getMonth(), 1); };
const moisIso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
const de = (mois) => (/^[aeiouyéèê]/i.test(mois) ? `d’${mois}` : `de ${mois}`);

/** Anneau de progression (part de 0 à 1 ; au-delà, l'anneau est plein et passe en alerte). */
function anneau(part, texte) {
  const r = 27; const c = 2 * Math.PI * r;
  const p = Math.max(0, Math.min(part, 1));
  return `<div class="app-anneau"${part > 1 ? ' data-depasse' : ''} aria-hidden="true"><svg viewBox="0 0 64 64" focusable="false"><circle class="app-anneau__fond" cx="32" cy="32" r="${r}"/>${p > 0
    ? `<circle class="app-anneau__part" cx="32" cy="32" r="${r}" stroke-dasharray="${c.toFixed(2)}" stroke-dashoffset="${(c * (1 - p)).toFixed(2)}"/>` : ''}</svg><span class="app-anneau__texte">${e(texte)}</span></div>`;
}

/** Mois en cours : dépenses comparées au budget (ou aux entrées), puis les quatre premières catégories. */
function carteMois(operations, budget) {
  const retenues = operations.filter((o) => ['comptabilisee', 'en_attente'].includes(o.statut) && !HORS_BUDGET.has(o.type));
  const debits = retenues.filter((o) => Number(o.montant) < 0);
  const depenses = -debits.reduce((t, o) => t + Number(o.montant), 0);
  const entrees = retenues.filter((o) => Number(o.montant) > 0).reduce((t, o) => t + Number(o.montant), 0);
  const nom = NOM_MOIS.format(new Date());
  const reference = budget ? Number(budget.montant) : entrees;
  const part = reference > 0 ? depenses / reference : 0;
  const texte = reference > 0 ? `${Math.round(part * 100)} %` : '—';
  const detail = budget
    ? (depenses <= reference ? `Budget ${formaterMontant(reference)} · reste ${formaterMontant(reference - depenses)}` : `Budget ${formaterMontant(reference)} · dépassé de ${formaterMontant(depenses - reference)}`)
    : (entrees > 0 ? `soit ${texte} de vos entrées du mois (${formaterMontant(entrees)})` : 'Aucune entrée ce mois-ci');

  // Répartition : par catégorie (ou, à défaut, par nature d'opération)
  const groupes = new Map();
  for (const o of debits) {
    const cle = o.categorie_code || `type:${o.type}`;
    const g = groupes.get(cle) || { libelle: LIBELLES_CATEGORIE[o.categorie_code] || LIBELLES_TYPE_OPERATION[o.type] || 'Autres', aspect: aspectOperation(o), total: 0 };
    g.total -= Number(o.montant);
    groupes.set(cle, g);
  }
  const principales = [...groupes.values()].sort((a, b) => b.total - a.total).slice(0, 4);
  const max = principales[0]?.total || 1;
  const repartition = principales.length
    ? `<ul class="app-repartition" aria-label="Dépenses par catégorie">${principales.map((g) => `<li class="app-pastille--${g.aspect[1]}">${pastille(g.aspect[0], g.aspect[1])}<span>${e(g.libelle)}</span>${montant(g.total)}
        <span class="app-repartition__barre" aria-hidden="true"><span style="inline-size:${Math.max(4, Math.round((g.total / max) * 100))}%"></span></span></li>`).join('')}</ul>`
    : '<p class="app-mois__vide">Aucune dépense ce mois-ci.</p>';

  return `<div class="app-mois"><div class="app-mois__haut">${anneau(part, texte)}
      <div class="app-mois__texte"><span class="app-mois__libelle">Dépenses ${e(de(nom))}</span><span class="app-mois__montant">${montant(depenses)}</span><span class="app-mois__detail">${e(detail)}</span></div></div>
    ${repartition}</div>`;
}

async function accueil() {
  const ctx = await ouvrirEspace('accueil');
  $('[data-actions-rapides]').innerHTML = ACTIONS.map(([ic, libelle, adresse]) => `<a class="app-action" href="${page(adresse)}"><span class="app-action__icone">${iconeEc(ic, 22)}</span><span class="app-action__libelle">${e(libelle)}</span></a>`).join('');
  let budget = null;

  const rendre = async () => {
    const comptes = ctx.comptes.length ? await lire('comptes', { colonnes: 'id, type, libelle, numero, solde, taux, statut', dans: { id: ctx.comptes }, ordre: 'created_at', croissant: true }) : [];
    const actifs = trierComptes(comptes.filter((k) => k.statut === 'actif'));
    const ids = actifs.map((k) => k.id);
    const [operations, duMois, attente, notifications, budgetDuMois] = await Promise.all([
      ids.length ? lire('operations', { colonnes: 'id, compte_id, type, libelle, contrepartie_nom, montant, statut, categorie_code, date_operation, created_at', dans: { compte_id: ids }, ordre: 'date_operation', croissant: false, limite: 6 }) : [],
      ids.length ? lire('operations', { colonnes: 'id, type, montant, statut, categorie_code', dans: { compte_id: ids }, depuis: { date_operation: debutDuMois().toISOString() }, limite: 3000 }) : [],
      ids.length ? lire('virements', { colonnes: 'id, montant, statut, created_at', dans: { compte_id: ids, statut: ['a_valider', 'en_approbation'] }, ordre: 'created_at', croissant: false }) : [],
      lire('notifications', { colonnes: 'id, titre, contenu, lien, lu_le, created_at', egal: { client_id: ctx.client.id }, ordre: 'created_at', croissant: false, limite: 5 }),
      lire('budgets', { colonnes: 'id, mois, montant', egal: { mois: moisIso(debutDuMois()) }, unique: true }).catch(() => null),
    ]);
    budget = budgetDuMois;

    // Solde global et comptes en pastilles
    $('[data-total]').innerHTML = montant(actifs.reduce((t, k) => t + Number(k.solde || 0), 0));
    $('[data-total-detail]').textContent = actifs.length ? `Sur ${actifs.length} compte${actifs.length > 1 ? 's' : ''}` : 'Aucun compte actif';
    $('[data-pilules]').innerHTML = actifs.map((k) => `<li><a class="app-pilule" href="${page('comptes/courant.html', `?id=${k.id}`)}"><span class="app-pilules__nom">${e(nomCourt(k))}</span> ${montant(k.solde)}</a></li>`).join('');

    // Virements qui attendent une action
    $('[data-attente]').hidden = !attente.length;
    $('[data-liste-attente]').innerHTML = attente.map((v) => `<li><div class="app-ligne">${pastille('horloge', 'ambre')}
        <span class="app-ligne__corps"><span class="app-ligne__titre">${montant(v.montant, { toujours: true })}</span><span class="app-ligne__detail">${e(STATUTS_VIREMENT[v.statut] || v.statut)}, le ${date(v.created_at, 'long')}</span></span>
        ${v.statut === 'a_valider' ? `<a class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" href="${page('comptes/virements.html', `?reprendre=${v.id}`)}">Valider</a>` : ''}</div></li>`).join('');

    // Dernières opérations : chaque ligne ouvre la fiche complète
    $('[data-operations]').innerHTML = operations.length ? `<ul class="app-groupe">${operations.map((o) => ligneOperation(o, { action: `data-operation="${o.id}"` })).join('')}</ul>`
      : '<p class="app-vide">Aucune opération pour le moment. Votre premier virement reçu apparaîtra ici.</p>';

    // Mois en cours
    $('[data-mois]').innerHTML = carteMois(duMois, budget);
    $('[data-budget]').textContent = budget ? 'Modifier le budget' : 'Définir un budget';

    // Notifications
    const nonLues = notifications.filter((n) => !n.lu_le);
    $('[data-notifications]').innerHTML = notifications.length ? `<ul class="app-groupe">${notifications.map((n) => `<li><div class="app-ligne app-ligne--haute${n.lu_le ? '' : ' app-ligne--nouvelle'}">${pastille('cloche', n.lu_le ? 'ardoise' : 'rose')}
        <span class="app-ligne__corps"><span class="app-ligne__titre">${e(n.titre)}</span>${n.contenu ? `<span class="app-ligne__texte">${e(n.contenu)}</span>` : ''}<span class="app-ligne__detail">${date(n.created_at, 'long')}</span></span></div></li>`).join('')}</ul>`
      : '<p class="app-vide">Aucune notification.</p>';
    $('[data-notifications-action]').innerHTML = nonLues.length ? '<button type="button" class="app-bloc__lien" data-tout-lu>Tout marquer comme lu</button>' : '';
    $('[data-tout-lu]')?.addEventListener('click', (x) => executer(x.currentTarget, async () => { await appeler('gmb_notification_lue', { p_notification: null }); await rendre(); }));
  };

  $('[data-operations]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-operation]');
    if (b) ficheOperation(b.dataset.operation, ctx, rendre).catch((y) => message(y.message));
  });
  $('[data-budget]').addEventListener('click', async (x) => {
    const bouton = x.currentTarget;
    const r = await demander(budget ? 'Modifier le budget du mois' : 'Définir un budget', [{ nom: 'montant', libelle: 'Budget mensuel (€)', type: 'number', requis: true, valeur: budget ? String(budget.montant).replace('.', ',') : '',
      verifier: (n) => (n > 0 && n <= 1000000 ? '' : 'Indiquez un montant compris entre 1 € et 1 000 000 €.') }],
    { valider: 'Enregistrer', intro: 'Vos dépenses du mois (cartes, prélèvements, virements émis, frais) sont comparées à ce montant. Les virements entre vos comptes n’en font pas partie.' });
    if (!r) return;
    await executer(bouton, async () => {
      if (budget) await modifier('budgets', budget.id, { montant: r.montant });
      else await inserer('budgets', { mois: moisIso(debutDuMois()), montant: r.montant });
      await rendre();
    }, 'Budget enregistré.');
  });
  document.addEventListener('gmb:discret', () => rendre());
  await rendre();
}
demarrerPage({ accueil });
