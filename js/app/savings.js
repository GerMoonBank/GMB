/* =============================================================================
   GerMoonBank (GMB) · js/app/savings.js — Épargne (lot E1b)
   Livret (versements, retraits, intérêts), coffres et objectifs, épargne
   programmée. Les virements entre ses propres comptes sont immédiats et ne
   demandent pas de code secret (DSP2 : comptes du même titulaire).
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, e, date, parametre, page, montant, badge, tableau, demander, executer, message, authentifier, refusSca, ligneOperation, operationsParJour, ficheOperation, numeroLisible } from './app.js';
import { lire, appeler, ErreurGmb } from '../donnees.js';
import { formaterMontant, icone, CREDIT } from '../core.js';

const FREQUENCES = [['mensuelle', 'Tous les mois'], ['hebdomadaire', 'Toutes les semaines'], ['trimestrielle', 'Tous les trimestres']];
const pct = (v) => (v === null || v === undefined ? '—' : `${String(v).replace('.', ',')} %`);

async function comptesEpargne(ctx) {
  const k = ctx.comptes.length ? await lire('comptes', { colonnes: 'id, type, libelle, numero, solde, taux, plafond, statut, compte_parent_id', dans: { id: ctx.comptes }, ordre: 'created_at', croissant: true }) : [];
  const actifs = k.filter((c) => c.statut === 'actif');
  return { courant: actifs.find((c) => c.type === 'courant'), livret: actifs.find((c) => c.type === 'livret'), coffresComptes: k.filter((c) => c.type === 'coffre') };
}

/** Versement sur le Livret, ou retrait vers le compte courant. */
async function mouvementLivret(sens, k) {
  if (!k.courant || !k.livret) throw new ErreurGmb('Il vous faut un compte courant et un Livret actifs.');
  const vers = sens === 'verser';
  const maxi = vers ? Math.min(Number(k.courant.solde), k.livret.plafond ? Number(k.livret.plafond) - Number(k.livret.solde) : Infinity) : Number(k.livret.solde);
  const r = await demander(vers ? 'Verser sur le Livret' : 'Retirer du Livret', [{ nom: 'montant', libelle: 'Montant (€)', type: 'number', requis: true, verifier: (n) => (n > 0 ? '' : 'Indiquez un montant positif.') }],
    { valider: vers ? 'Verser' : 'Retirer', intro: `Au plus ${e(formaterMontant(Math.max(0, maxi)))}. Le virement est immédiat.` });
  if (!r) return false;
  await appeler('gmb_virement_interne', { p_depuis: vers ? k.courant.id : k.livret.id, p_vers: vers ? k.livret.id : k.courant.id, p_montant: r.montant });
  message(vers ? 'Versement effectué sur votre Livret.' : 'Retrait effectué vers votre compte courant.', 'succes');
  return true;
}

async function vueEnsemble() {
  const ctx = await ouvrirEspace('epargne');
  const rendre = async () => {
    const k = await comptesEpargne(ctx);
    const [coffres, programmes] = await Promise.all([lire('coffres', { ordre: 'created_at', croissant: true }), lire('epargnes_programmees', { egal: { actif: true }, ordre: 'prochaine_date', croissant: true })]);
    const soldeCoffre = Object.fromEntries(k.coffresComptes.map((c) => [c.id, Number(c.solde)]));
    const actifs = coffres.filter((c) => c.statut !== 'clos');
    $('[data-livret]').innerHTML = k.livret ? `<p class="app-solde">${montant(k.livret.solde)}</p><p>Taux ${pct(k.livret.taux)} · plafond ${e(k.livret.plafond ? formaterMontant(k.livret.plafond) : '—')} · intérêts versés chaque jour</p>
        <div class="gmb-rangee"><button type="button" class="gmb-bouton gmb-bouton--principal" data-verser>Verser</button><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-retirer>Retirer</button><a class="gmb-bouton gmb-bouton--fantome" href="${page('epargne/livret-detail.html')}">Détail</a></div>`
      : '<p class="app-vide">Vous ne détenez pas de Livret. Le Livret GerMoon+ est inclus dans les formules Orbit, Éclipse et Zénith.</p>';
    $('[data-coffres]').innerHTML = `<p>${actifs.length} coffre${actifs.length > 1 ? 's' : ''} · ${montant(actifs.reduce((t, c) => t + (soldeCoffre[c.compte_id] || 0), 0))}</p><p><a href="${page('epargne/coffres.html')}">Gérer vos coffres</a> · <a href="${page('epargne/objectifs.html')}">Vos objectifs</a></p>`;
    $('[data-programmes]').innerHTML = programmes.length ? `<ul>${programmes.map((p) => `<li>${montant(p.montant, { toujours: true })} · ${e(FREQUENCES.find(([f]) => f === p.frequence)?.[1].toLowerCase())} · prochain le ${date(p.prochaine_date, 'long')}</li>`).join('')}</ul>` : '<p class="app-vide">Aucune épargne programmée.</p>';
    $('[data-verser]')?.addEventListener('click', (x) => executer(x.currentTarget, async () => { if (await mouvementLivret('verser', k)) await rendre(); }));
    $('[data-retirer]')?.addEventListener('click', (x) => executer(x.currentTarget, async () => { if (await mouvementLivret('retirer', k)) await rendre(); }));
  };
  document.addEventListener('gmb:discret', () => rendre());
  await rendre();
}

async function livret() {
  const ctx = await ouvrirEspace('epargne');
  const rendre = async () => {
    const k = await comptesEpargne(ctx);
    if (!k.livret) { $('[data-livret]').innerHTML = '<p class="app-vide">Vous ne détenez pas de Livret.</p>'; return; }
    const debutAnnee = `${new Date().getFullYear()}-01-01`;
    const [ops, interets] = await Promise.all([lire('operations', { dans: { compte_id: [k.livret.id] }, ordre: 'date_operation', croissant: false, limite: 30 }), lire('interets', { colonnes: 'jour, montant', dans: { compte_id: [k.livret.id] }, depuis: { jour: debutAnnee } })]);
    $('[data-livret]').innerHTML = `<p class="app-solde">${montant(k.livret.solde)}</p><dl class="app-recap"><div><dt>Numéro</dt><dd>${e(numeroLisible(k.livret.numero))}</dd></div><div><dt>Taux annuel</dt><dd>${pct(k.livret.taux)}</dd></div>
        <div><dt>Plafond</dt><dd>${e(k.livret.plafond ? formaterMontant(k.livret.plafond) : '—')}</dd></div><div><dt>Intérêts versés depuis le 1<sup>er</sup> janvier</dt><dd>${montant(interets.reduce((t, i) => t + Number(i.montant), 0))}</dd></div></dl>
        <div class="gmb-rangee"><button type="button" class="gmb-bouton gmb-bouton--principal" data-verser>Verser</button><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-retirer>Retirer</button></div>`;
    $('[data-operations]').innerHTML = ops.length ? `<div class="app-jours">${operationsParJour(ops, (o) => ligneOperation(o, { action: `data-operation="${o.id}"`, avecJour: false }))}</div>` : '<p class="app-vide">Aucune opération.</p>';
    $('[data-verser]').addEventListener('click', (x) => executer(x.currentTarget, async () => { if (await mouvementLivret('verser', k)) await rendre(); }));
    $('[data-retirer]').addEventListener('click', (x) => executer(x.currentTarget, async () => { if (await mouvementLivret('retirer', k)) await rendre(); }));
  };
  $('[data-operations]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-operation]');
    if (b) ficheOperation(b.dataset.operation, ctx, rendre).catch((y) => message(y.message));
  });
  document.addEventListener('gmb:discret', () => rendre());
  await rendre();
}

function progression(solde, objectif) {
  if (!objectif) return '';
  const p = Math.max(0, Math.min(100, Math.round((Number(solde) / Number(objectif)) * 100)));
  return `<div class="app-progression" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${p}" aria-label="Objectif atteint à ${p} %"><span style="inline-size:${p}%"></span></div><small>${p} % de ${e(formaterMontant(objectif))}</small>`;
}

async function coffres() {
  const ctx = await ouvrirEspace('epargne');
  const rendre = async () => {
    const k = await comptesEpargne(ctx);
    const solde = Object.fromEntries(k.coffresComptes.map((c) => [c.id, Number(c.solde)]));
    const liste = (await lire('coffres', { ordre: 'created_at', croissant: true })).filter((c) => c.statut !== 'clos');
    $('[data-liste]').innerHTML = liste.length ? `<ul class="app-cartes-comptes">${liste.map((c) => `<li><a class="gmb-carte app-compte" href="${page('epargne/coffre-detail.html', `?id=${c.id}`)}"><span class="app-compte__type">${e(c.nom)}</span>
        <span class="app-compte__solde">${montant(solde[c.compte_id] || 0)}</span>${progression(solde[c.compte_id] || 0, c.objectif)}${c.statut === 'atteint' ? badge('Objectif atteint', 'succes') : ''}</a></li>`).join('')}</ul>` : '<p class="app-vide">Aucun coffre.</p>';
  };
  $('[data-creer]').addEventListener('click', (x) => executer(x.currentTarget, async () => {
    const r = await demander('Créer un coffre', [{ nom: 'nom', libelle: 'Nom du coffre', requis: true }, { nom: 'objectif', libelle: 'Objectif (€, facultatif)', type: 'number' }, { nom: 'date', libelle: 'Date visée (facultative)', type: 'date' }], { valider: 'Créer' });
    if (!r) return;
    if (r.date && r.date <= new Date().toISOString().slice(0, 10)) throw new ErreurGmb('Choisissez une date à venir.');
    await appeler('gmb_coffre_creer', { p_nom: r.nom, p_objectif: r.objectif, p_date: r.date || null, p_arrondi: 0 });
    await rendre();
  }, 'Coffre créé.'));
  document.addEventListener('gmb:discret', () => rendre());
  await rendre();
}

async function coffre() {
  const ctx = await ouvrirEspace('epargne');
  const id = parametre('id');
  const rendre = async () => {
    const c = await lire('coffres', { egal: { id }, unique: true });
    if (!c || c.statut === 'clos') { $('[data-coffre]').innerHTML = `<p class="app-vide">Ce coffre n’existe plus.</p><p><a href="${page('epargne/coffres.html')}">Vos coffres</a></p>`; return; }
    const compte = await lire('comptes', { colonnes: 'id, solde', egal: { id: c.compte_id }, unique: true });
    const ops = await lire('operations', { dans: { compte_id: [c.compte_id] }, ordre: 'created_at', croissant: false, limite: 20 });
    $('h1').textContent = c.nom;
    $('[data-coffre]').innerHTML = `<p class="app-solde">${montant(compte?.solde)}</p>${progression(compte?.solde, c.objectif)}
      ${c.date_objectif ? `<p>Date visée : ${date(c.date_objectif, 'long')}</p>` : ''}
      <div class="gmb-rangee"><button type="button" class="gmb-bouton gmb-bouton--principal" data-mouvement="1">Ajouter</button><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-mouvement="-1">Retirer</button>
      <button type="button" class="gmb-bouton gmb-bouton--fantome" data-cloturer>Clore le coffre</button></div>
      ${tableau('Mouvements du coffre', ['Date', 'Libellé', 'Montant'], ops.map((o) => [date(o.created_at), e(o.libelle), montant(o.montant, { signe: true })]), 'Aucun mouvement.')}`;
    $('[data-coffre]').querySelectorAll('[data-mouvement]').forEach((b) => b.addEventListener('click', () => executer(b, async () => {
      const ajout = b.dataset.mouvement === '1';
      const r = await demander(ajout ? 'Ajouter au coffre' : 'Retirer du coffre', [{ nom: 'montant', libelle: 'Montant (€)', type: 'number', requis: true, verifier: (n) => (n > 0 ? '' : 'Indiquez un montant positif.') }], { valider: ajout ? 'Ajouter' : 'Retirer', intro: ajout ? 'L’argent vient de votre compte courant.' : 'L’argent revient sur votre compte courant.' });
      if (!r) return;
      await appeler('gmb_coffre_mouvement', { p_coffre: id, p_montant: ajout ? r.montant : -r.montant });
      await rendre();
    }, b.dataset.mouvement === '1' ? 'Montant ajouté au coffre.' : 'Montant retiré du coffre.')));
    $('[data-cloturer]').addEventListener('click', (x) => executer(x.currentTarget, async () => {
      const r = await demander(`Clore le coffre « ${c.nom} » ?`, [], { valider: 'Clore le coffre', danger: true, intro: 'Son solde revient sur votre compte courant.' });
      if (!r) return;
      const res = await appeler('gmb_coffre_cloturer', { p_coffre: id });
      location.href = page('epargne/coffres.html');
      message(`Coffre clos : ${formaterMontant(res?.rendu || 0)} rendus sur votre compte courant.`, 'succes');
    }));
  };
  document.addEventListener('gmb:discret', () => rendre());
  await rendre();
}

async function objectifs() {
  const ctx = await ouvrirEspace('epargne');
  const k = await comptesEpargne(ctx);
  const solde = Object.fromEntries(k.coffresComptes.map((c) => [c.id, Number(c.solde)]));
  const liste = (await lire('coffres', { ordre: 'date_objectif', croissant: true })).filter((c) => c.statut !== 'clos' && c.objectif);
  const auj = new Date();
  $('[data-liste]').innerHTML = tableau('Vos objectifs', ['Coffre', 'Progression', 'Reste à épargner', 'Par mois jusqu’à la date visée'], liste.map((c) => {
    const reste = Math.max(0, Number(c.objectif) - (solde[c.compte_id] || 0));
    const mois = c.date_objectif ? Math.max(1, Math.ceil((new Date(`${c.date_objectif}T12:00:00`) - auj) / (30.44 * 864e5))) : null;
    return [`<a href="${page('epargne/coffre-detail.html', `?id=${c.id}`)}">${e(c.nom)}</a>`, progression(solde[c.compte_id] || 0, c.objectif), montant(reste, { toujours: true }),
      mois ? (reste ? `${montant(reste / mois, { toujours: true })} pendant ${mois} mois` : 'Objectif atteint') : 'Sans date visée'];
  }), 'Aucun coffre n’a d’objectif. Créez un coffre avec un objectif depuis la page Coffres.');
}

async function programmation() {
  const ctx = await ouvrirEspace('epargne');
  const rendre = async () => {
    const k = await comptesEpargne(ctx);
    const liste = await lire('epargnes_programmees', { ordre: 'created_at', croissant: false });
    const libelle = (id) => (id === k.livret?.id ? 'Livret' : id === k.courant?.id ? 'Compte courant' : 'Compte');
    $('[data-liste]').innerHTML = tableau('Épargne programmée', ['Virement', 'Montant', 'Fréquence', 'Prochaine fois', 'Dernier résultat', 'Action'], liste.map((p) => [e(`${libelle(p.compte_source)} → ${libelle(p.compte_cible)}`), montant(p.montant, { toujours: true }),
      e(FREQUENCES.find(([f]) => f === p.frequence)?.[1] || p.frequence), p.actif ? date(p.prochaine_date, 'long') : badge('Arrêtée'), e(p.dernier_resultat ? `${p.dernier_resultat}${p.derniere_execution ? ` (${date(p.derniere_execution)})` : ''}` : '—'),
      p.actif ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-arreter="${p.id}">Arrêter</button>` : '—']), 'Aucune épargne programmée.');
    $('[data-creer]').onclick = (x) => executer(x.currentTarget, async () => {
      if (!k.courant || !k.livret) throw new ErreurGmb('Il vous faut un compte courant et un Livret actifs.');
      const demain = new Date(Date.now() + 864e5).toISOString().slice(0, 10);
      const r = await demander('Programmer une épargne', [{ nom: 'sens', libelle: 'Virement', options: [['vers', 'Du compte courant vers le Livret'], ['depuis', 'Du Livret vers le compte courant']] },
        { nom: 'montant', libelle: 'Montant (€)', type: 'number', requis: true, verifier: (n) => (n > 0 ? '' : 'Indiquez un montant positif.') }, { nom: 'frequence', libelle: 'Fréquence', options: FREQUENCES },
        { nom: 'date', libelle: 'Premier virement le', type: 'date', valeur: demain, requis: true }], { valider: 'Programmer', intro: 'Le virement est effectué automatiquement chaque fois, tôt le matin. S’il ne peut pas être fait, vous en êtes informé.' });
      if (!r) return;
      await appeler('gmb_epargne_programmer', { p_source: r.sens === 'vers' ? k.courant.id : k.livret.id, p_cible: r.sens === 'vers' ? k.livret.id : k.courant.id, p_montant: r.montant, p_frequence: r.frequence, p_date: r.date });
      await rendre();
      message('Épargne programmée enregistrée.', 'succes');
    });
  };
  $('[data-liste]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-arreter]');
    if (b) executer(b, async () => { await appeler('gmb_epargne_programmee_arreter', { p_id: b.dataset.arreter }); await rendre(); }, 'Épargne programmée arrêtée.');
  });
  await rendre();
}

async function interets() {
  const ctx = await ouvrirEspace('epargne');
  const k = await comptesEpargne(ctx);
  if (!k.livret) { $('[data-liste]').innerHTML = '<p class="app-vide">Vous ne détenez pas de Livret.</p>'; return; }
  const depuis = new Date(new Date().getFullYear() - 1, new Date().getMonth(), 1).toISOString().slice(0, 10);
  const liste = await lire('interets', { colonnes: 'jour, montant, taux', dans: { compte_id: [k.livret.id] }, depuis: { jour: depuis }, ordre: 'jour', croissant: false, limite: 400 });
  const parMois = {};
  for (const i of liste) { const m = i.jour.slice(0, 7); parMois[m] = (parMois[m] || 0) + Number(i.montant); }
  $('[data-taux]').innerHTML = `Taux actuel : <strong>${pct(k.livret.taux)}</strong> par an. Les intérêts sont calculés chaque jour sur votre solde et versés sur le Livret le jour même.`;
  $('[data-liste]').innerHTML = tableau('Intérêts par mois', ['Mois', 'Intérêts versés'], Object.entries(parMois).map(([m, v]) => [e(new Date(`${m}-15T12:00:00`).toLocaleDateString('fr-FR', { month: 'long', year: 'numeric' })), montant(v, { toujours: true })]), 'Aucun intérêt versé sur les douze derniers mois.');
}


/* =============================================================================
   Crédit (lot E1b) : prêts, échéancier, remboursement anticipé, simulateur,
   demande et suivi (offre, acceptation, rétractation de 14 jours).
   ========================================================================== */
const STATUTS_CREDIT = { en_cours: ['En cours', 'succes'], impaye: ['Échéance impayée', 'danger'], rembourse: ['Remboursé', 'neutre'] };
const STATUTS_ECHEANCE = { a_venir: ['À venir', 'neutre'], payee: ['Payée', 'succes'], impayee: ['Impayée', 'danger'] };
const ETATS_DEMANDE = { demande_deposee: 'Demande déposée', analyse: 'En analyse', incomplet: 'Incomplète', offre_emise: 'Offre à accepter', delai_legal: 'Offre acceptée : délai légal',
  acceptee: 'Acceptée', fonds_debloques: 'Fonds versés', refusee: 'Refusée', renonciation: 'Rétractation', validee: 'Validée', realisee: 'Réalisée', annulee: 'Annulée' };
const MENTION_CREDIT = 'Un crédit vous engage et doit être remboursé. Vérifiez vos capacités de remboursement avant de vous engager.';

async function credits() {
  const ctx = await ouvrirEspace('credit');
  const [prets, demandes] = await Promise.all([lire('credits', { ordre: 'created_at', croissant: false }), lire('demandes', { egal: { type: 'pret_personnel' }, ordre: 'created_at', croissant: false })]);
  $('[data-prets]').innerHTML = tableau('Vos prêts', ['Prêt', 'Capital restant', 'Mensualité', 'Statut'], prets.map((c) => [`<a href="${page('credit/detail.html', `?id=${c.id}`)}">${e(formaterMontant(c.montant))} sur ${e(c.duree_mois)} mois</a>`,
    montant(c.capital_restant), montant(c.mensualite, { toujours: true }), badge(...(STATUTS_CREDIT[c.statut] || [c.statut, 'neutre']))]), 'Vous n’avez aucun prêt.');
  const enCours = demandes.filter((d) => !['fonds_debloques', 'refusee', 'renonciation', 'annulee', 'realisee'].includes(d.etat));
  $('[data-demandes]').innerHTML = enCours.length ? `<ul>${enCours.map((d) => `<li>${e(d.reference)} · ${e(formaterMontant(d.montant))} sur ${e(d.duree_mois)} mois · ${badge(ETATS_DEMANDE[d.etat] || d.etat, d.etat === 'offre_emise' ? 'succes' : 'neutre')}</li>`).join('')}</ul><p><a href="${page('credit/suivi.html')}">Suivre vos demandes</a></p>` : '<p class="app-vide">Aucune demande en cours.</p>';
}

async function credit() {
  const ctx = await ouvrirEspace('credit');
  const c = await lire('credits', { egal: { id: parametre('id') }, unique: true });
  if (!c) { $('[data-credit]').innerHTML = `<p class="app-vide">Prêt introuvable.</p><p><a href="${page('credit/index.html')}">Vos prêts</a></p>`; return; }
  const [echeances, anticipes] = await Promise.all([lire('credit_echeances', { egal: { credit_id: c.id }, ordre: 'numero', croissant: true }), lire('credit_remboursements_anticipes', { egal: { credit_id: c.id }, ordre: 'created_at', croissant: false })]);
  const prochaines = echeances.filter((x) => x.statut !== 'payee').slice(0, 3);
  const impayees = echeances.filter((x) => x.statut === 'impayee');
  $('[data-credit]').innerHTML = `${impayees.length ? `<div class="gmb-encadre gmb-encadre--neutre" role="alert">${icone('alerte')}<p><strong>${impayees.length} échéance${impayees.length > 1 ? 's' : ''} impayée${impayees.length > 1 ? 's' : ''} (${e(formaterMontant(impayees.reduce((t, x) => t + Number(x.montant), 0)))}).</strong> Approvisionnez votre compte courant : elle${impayees.length > 1 ? 's sont représentées' : ' est représentée'} chaque jour.</p></div>` : ''}
    <dl class="app-recap"><div><dt>Montant emprunté</dt><dd>${montant(c.montant, { toujours: true })}</dd></div><div><dt>Durée</dt><dd>${e(c.duree_mois)} mois depuis le ${date(c.debut, 'long')}</dd></div>
      <div><dt>Taux débiteur fixe</dt><dd>${pct(c.taux_debiteur)}</dd></div><div><dt>TAEG</dt><dd>${pct(c.taeg)}</dd></div><div><dt>Mensualité</dt><dd>${montant(c.mensualite, { toujours: true })}</dd></div>
      <div><dt>Capital restant</dt><dd>${montant(c.capital_restant)}</dd></div><div><dt>Statut</dt><dd>${badge(...(STATUTS_CREDIT[c.statut] || [c.statut, 'neutre']))}</dd></div></dl>
    ${tableau('Prochaines échéances', ['N°', 'Date', 'Montant', 'Statut'], prochaines.map((x) => [e(x.numero), date(x.date_echeance, 'long'), montant(x.montant, { toujours: true }), badge(...(STATUTS_ECHEANCE[x.statut] || [x.statut, 'neutre']))]), 'Plus aucune échéance.')}
    ${anticipes.length ? tableau('Remboursements anticipés', ['Date', 'Type', 'Montant', 'Indemnité'], anticipes.map((r) => [date(r.created_at, 'long'), e(r.type === 'total' ? 'Total' : 'Partiel'), montant(r.montant, { toujours: true }), montant(r.indemnite, { toujours: true })])) : ''}
    <p><a href="${page('credit/echeancier.html', `?id=${c.id}`)}">Échéancier complet</a>${c.statut !== 'rembourse' ? ` · <a href="${page('credit/remboursement-anticipe.html', `?id=${c.id}`)}">Rembourser par anticipation</a>` : ''}</p>`;
}

async function echeancier() {
  const ctx = await ouvrirEspace('credit');
  const c = await lire('credits', { egal: { id: parametre('id') }, unique: true });
  if (!c) { $('[data-echeancier]').innerHTML = '<p class="app-vide">Prêt introuvable.</p>'; return; }
  const liste = await lire('credit_echeances', { egal: { credit_id: c.id }, ordre: 'numero', croissant: true });
  $('[data-echeancier]').innerHTML = `<p>${e(formaterMontant(c.montant))} sur ${e(c.duree_mois)} mois, taux débiteur fixe ${pct(c.taux_debiteur)}.</p>
    ${tableau('Échéancier', ['N°', 'Date', 'Échéance', 'Capital', 'Intérêts', 'Capital restant', 'Statut'], liste.map((x) => [e(x.numero), date(x.date_echeance), montant(x.montant, { toujours: true }), montant(x.capital, { toujours: true }),
      montant(x.interets, { toujours: true }), montant(x.capital_restant, { toujours: true }), badge(...(STATUTS_ECHEANCE[x.statut] || [x.statut, 'neutre']))]), 'Aucune échéance.')}`;
}

async function anticipation() {
  const ctx = await ouvrirEspace('credit');
  const c = await lire('credits', { egal: { id: parametre('id') }, unique: true });
  const form = $('[data-form="anticipation"]');
  if (!c || c.statut === 'rembourse') { $('[data-resultat]').innerHTML = `<p class="app-vide">${c ? 'Ce prêt est entièrement remboursé.' : 'Prêt introuvable.'}</p>`; form.hidden = true; return; }
  $('[data-capital]').innerHTML = `Capital restant dû : ${montant(c.capital_restant, { toujours: true })}.`;
  let calcul = null;
  const montantSaisi = () => { const v = String(form.elements.montant.value).trim(); return v ? Number(v.replace(/\s/g, '').replace(',', '.')) : null; };
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const m = montantSaisi();
      if (m !== null && !(m > 0)) throw new ErreurGmb('Indiquez un montant positif, ou laissez vide pour tout rembourser.');
      calcul = await appeler('gmb_credit_anticipation', { p_credit: c.id, p_montant: m });
      $('[data-resultat]').innerHTML = `<div class="gmb-carte gmb-pile gmb-pile--serree"><h2 class="gmb-section__titre gmb-section__titre--moyen">Remboursement ${calcul.type === 'total' ? 'total' : 'partiel'}</h2>
        <dl class="app-recap"><div><dt>Capital remboursé</dt><dd>${montant(calcul.montant, { toujours: true })}</dd></div>
          <div><dt>Indemnité</dt><dd>${montant(calcul.indemnite, { toujours: true })}${calcul.exonere ? ' (aucune : moins de 10 000 € remboursés par anticipation sur 12 mois)' : ` (${pct(calcul.taux_indemnite)} du montant, plafonnée aux intérêts restant dus)`}</dd></div>
          <div><dt>Total débité</dt><dd><strong>${montant(calcul.total, { toujours: true })}</strong></dd></div>
          ${calcul.type === 'partiel' ? `<div><dt>Nouvelle mensualité</dt><dd>${montant(calcul.nouvelle_mensualite, { toujours: true })} au lieu de ${montant(calcul.mensualite_actuelle, { toujours: true })}, sur les ${e(calcul.echeances_restantes)} échéances restantes</dd></div>` : ''}</dl>
        <p><button type="button" class="gmb-bouton gmb-bouton--principal" data-confirmer>Rembourser ${montant(calcul.total, { toujours: true })}</button></p></div>`;
      $('[data-confirmer]').addEventListener('click', (y) => executer(y.currentTarget, async () => {
        const code = await authentifier('Confirmer le remboursement anticipé', [['Total débité', montant(calcul.total, { toujours: true })], ['Capital remboursé', montant(calcul.montant, { toujours: true })], ['Indemnité', montant(calcul.indemnite, { toujours: true })]], ctx.client.identifiant);
        if (!code) return;
        const r = await appeler('gmb_credit_rembourser_par_anticipation', { p_credit: c.id, p_montant: calcul.montant, p_grille: code.grille, p_positions: code.positions });
        await refusSca(r);
        $('[data-resultat]').innerHTML = '';
        form.hidden = true;
        message(r.type === 'total' ? 'Votre prêt est soldé.' : `Remboursement effectué : votre nouvelle mensualité est de ${formaterMontant(r.nouvelle_mensualite)}.`, 'succes');
      }));
    });
  });
}

async function simulateurCredit() {
  await ouvrirEspace('credit');
  const form = $('[data-form="simulation"]');
  form.elements.objet.innerHTML = CREDIT.objets.map((o) => `<option value="${o.code}">${e(o.libelle)}</option>`).join('');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const m = Number(String(form.elements.montant.value).replace(/\s/g, '').replace(',', '.')); const d = Number(form.elements.duree.value);
      if (!(m > 0) || !(d > 0)) throw new ErreurGmb('Indiquez un montant et une durée.');
      const s = await appeler('gmb_simuler_credit', { p_montant: m, p_duree: d, p_objet: form.elements.objet.value });
      if (!s.disponible) throw new ErreurGmb(s.message || 'Aucune offre pour ce montant et cette durée.');
      $('[data-resultat]').innerHTML = `<div class="gmb-carte gmb-pile gmb-pile--serree"><dl class="app-recap"><div><dt>Mensualité</dt><dd><strong>${montant(s.mensualite, { toujours: true })}</strong> pendant ${e(s.duree_mois)} mois</dd></div>
        <div><dt>Taux débiteur fixe</dt><dd>${pct(s.taux_debiteur)}</dd></div><div><dt>TAEG fixe</dt><dd>${pct(s.taeg)}</dd></div><div><dt>Coût total du crédit</dt><dd>${montant(s.cout_total, { toujours: true })}</dd></div>
        <div><dt>Montant total dû</dt><dd>${montant(s.montant_total_du, { toujours: true })}</dd></div></dl><p class="gmb-mention-obligatoire">${e(MENTION_CREDIT)}</p>
        <p><a class="gmb-bouton gmb-bouton--principal" href="${page('credit/demande.html', `?montant=${m}&duree=${d}&objet=${encodeURIComponent(form.elements.objet.value)}`)}">Faire cette demande</a></p></div>`;
    });
  });
}

async function demandeCredit() {
  await ouvrirEspace('credit');
  const form = $('[data-form="demande"]');
  form.elements.objet.innerHTML = CREDIT.objets.map((o) => `<option value="${o.code}">${e(o.libelle)}</option>`).join('');
  if (parametre('montant')) form.elements.montant.value = parametre('montant');
  if (parametre('duree')) form.elements.duree.value = parametre('duree');
  if (parametre('objet')) form.elements.objet.value = parametre('objet');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const m = Number(String(form.elements.montant.value).replace(/\s/g, '').replace(',', '.')); const d = Number(form.elements.duree.value);
      if (!(m > 0) || !(d > 0)) throw new ErreurGmb('Indiquez un montant et une durée.');
      if (!form.elements.engagement.checked) throw new ErreurGmb('Confirmez avoir vérifié votre capacité de remboursement.');
      await appeler('gmb_demande_credit', { p_montant: m, p_duree: d, p_objet: form.elements.objet.value });
      location.href = page('credit/suivi.html?depose=1');
    });
  });
}

async function suiviCredit() {
  await ouvrirEspace('credit');
  if (parametre('depose')) message('Votre demande est déposée : un conseiller l’étudie. L’offre apparaîtra ici.', 'succes');
  const rendre = async () => {
    const demandes = await lire('demandes', { egal: { type: 'pret_personnel' }, ordre: 'created_at', croissant: false });
    const maintenant = new Date();
    $('[data-demandes]').innerHTML = demandes.length ? demandes.map((d) => `<article class="gmb-carte gmb-pile gmb-pile--serree"><h2 class="gmb-section__titre gmb-section__titre--moyen">${e(d.reference)} · ${e(formaterMontant(d.montant))} sur ${e(d.duree_mois)} mois</h2>
        <p>${badge(ETATS_DEMANDE[d.etat] || d.etat, d.etat === 'offre_emise' ? 'succes' : d.etat === 'refusee' ? 'danger' : 'neutre')}</p>
        ${d.offre_emise_le ? `<dl class="app-recap"><div><dt>Taux débiteur fixe</dt><dd>${pct(d.taux_debiteur)}</dd></div><div><dt>TAEG fixe</dt><dd>${pct(d.taeg)}</dd></div><div><dt>Mensualité</dt><dd>${montant(d.mensualite, { toujours: true })}</dd></div>
          <div><dt>Coût total</dt><dd>${montant(d.cout_total, { toujours: true })}</dd></div><div><dt>Montant total dû</dt><dd>${montant(d.montant_total_du, { toujours: true })}</dd></div></dl>` : ''}
        ${d.etat === 'offre_emise' ? `<p class="gmb-mention-obligatoire">${e(MENTION_CREDIT)}</p><p><button type="button" class="gmb-bouton gmb-bouton--principal" data-accepter="${d.id}">Accepter l’offre</button></p>` : ''}
        ${d.etat === 'delai_legal' ? `<p>Vous avez accepté l’offre le ${date(d.acceptee_le, 'long')}. Les fonds seront versés sur votre compte courant à partir du ${date(d.deblocage_possible_le, 'long')}.</p>
          ${d.retractation_fin && new Date(d.retractation_fin) > maintenant ? `<p>Vous pouvez vous rétracter jusqu’au ${date(d.retractation_fin, 'long')}, sans motif ni frais.</p><p><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-retracter="${d.id}">Me rétracter</button></p>` : ''}` : ''}
      </article>`).join('') : '<p class="app-vide">Aucune demande de prêt.</p>';
  };
  $('[data-demandes]').addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.accepter) executer(b, async () => {
      const r = await demander('Accepter l’offre de prêt ?', [], { valider: 'J’accepte l’offre', intro: 'Vous disposez ensuite de 14 jours pour vous rétracter. Les fonds sont versés au plus tôt le 8e jour.' });
      if (!r) return;
      await appeler('gmb_credit_accepter', { p_id: b.dataset.accepter });
      await rendre();
    }, 'Offre acceptée.');
    if (b.dataset.retracter) executer(b, async () => {
      const r = await demander('Vous rétracter ?', [], { valider: 'Je me rétracte', danger: true, intro: 'La demande est annulée : aucun fonds ne sera versé.' });
      if (!r) return;
      await appeler('gmb_credit_retracter', { p_id: b.dataset.retracter });
      await rendre();
    }, 'Rétractation enregistrée.');
  });
  await rendre();
}

demarrerPage({ epargne: vueEnsemble, livret, coffres, coffre, objectifs, programmation, interets, credits, credit, echeancier, anticipation, 'simulateur-credit': simulateurCredit, 'demande-credit': demandeCredit, 'suivi-credit': suiviCredit });
