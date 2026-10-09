/* =============================================================================
   GerMoonBank (GMB) · js/app/transfers.js — Virements et bénéficiaires (lot E1)
   Virement instantané, différé ou permanent ; vérification du nom du
   bénéficiaire ; authentification forte (code secret sur le clavier aléatoire,
   pour ce virement précis) ; programmés ; bénéficiaires de confiance.
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, e, date, parametre, page, montant, badge, tableau, demander, authentifier, refusSca, executer, message, TYPES_COMPTE, STATUTS_VIREMENT } from './app.js';
import { lire, appeler, modifier, supprimer, ErreurGmb } from '../donnees.js';
import { formaterMontant } from '../core.js';

const nombre = (t) => { const n = Number(String(t || '').replace(/\s/g, '').replace(',', '.')); return Number.isFinite(n) ? n : null; };
const FREQUENCES = [['mensuelle', 'Tous les mois'], ['hebdomadaire', 'Toutes les semaines'], ['trimestrielle', 'Tous les trimestres'], ['annuelle', 'Tous les ans']];

async function comptesEmetteurs(ctx) {
  const k = ctx.comptes.length ? await lire('comptes', { colonnes: 'id, type, libelle, numero, solde, statut', dans: { id: ctx.comptes }, ordre: 'created_at', croissant: true }) : [];
  return k.filter((c) => ['courant', 'pro', 'business'].includes(c.type) && c.statut === 'actif');
}

/** Validation d'un virement à valider : récapitulatif, code secret, exécution. */
async function validerVirement(ctx, v, details) {
  const saisie = await authentifier('Confirmer le virement', details, ctx.client.identifiant);
  if (!saisie) { message('Virement non confirmé : il reste à valider dans vos virements programmés.', 'info'); return null; }
  const r = await appeler('gmb_virement_valider', { p_virement: v, p_grille: saisie.grille, p_positions: saisie.positions });
  await refusSca(r);
  const textes = { execute: 'Virement effectué.', a_executer: r.message || 'Votre compte est débité ; le virement est transmis à la banque du bénéficiaire.', valide: `Virement programmé pour le ${date(r.date_execution, 'long')}.`, rejete: r.message || 'Virement rejeté.' };
  message(textes[r.statut] || 'Virement enregistré.', r.statut === 'rejete' ? 'erreur' : 'succes');
  return r;
}

async function virements() {
  const ctx = await ouvrirEspace('virements');
  const form = $('[data-form="virement"]');
  const [comptes, beneficiaires] = await Promise.all([comptesEmetteurs(ctx), lire('beneficiaires', { ordre: 'nom', croissant: true })]);
  form.elements.compte.innerHTML = comptes.map((k) => `<option value="${k.id}">${e(k.libelle || TYPES_COMPTE[k.type])} · n° ${e(k.numero)}</option>`).join('');
  form.elements.beneficiaire.innerHTML = '<option value="">Choisissez</option>' + beneficiaires.map((b) => `<option value="${b.id}">${e(b.nom_verifie || b.nom)} · ${e(b.numero_compte || b.iban || '')}${b.favori ? ' ★' : ''}</option>`).join('');
  $('[data-aucun-beneficiaire]').hidden = beneficiaires.length > 0;
  const majType = () => { const t = form.elements.type.value; $('[data-si-date]').hidden = t === 'instantane'; $('[data-si-frequence]').hidden = t !== 'permanent'; };
  form.addEventListener('change', (x) => { if (x.target.name === 'type') majType(); if (x.target.name === 'beneficiaire') majPlafond(); });
  const majPlafond = () => {
    const b = beneficiaires.find((y) => y.id === form.elements.beneficiaire.value);
    const zone = $('[data-plafond]');
    zone.hidden = !(b?.plafond_temporaire_jusqu && new Date(b.plafond_temporaire_jusqu) > new Date());
    if (!zone.hidden) zone.textContent = `Nouveau bénéficiaire : virements limités à ${formaterMontant(b.plafond_temporaire)} jusqu’au ${date(b.plafond_temporaire_jusqu, 'long')}, par sécurité.`;
  };
  majType();
  const details = (b, k, mt, type, quand) => [['Montant', montant(mt, { toujours: true })], ['Bénéficiaire', e(b ? `${b.nom_verifie || b.nom} · ${b.numero_compte || b.iban}` : '—')], ['Depuis', e(k ? `${k.libelle || TYPES_COMPTE[k.type]} · n° ${k.numero}` : '—')], ['Exécution', e(type === 'instantane' ? 'Immédiate' : `Le ${date(quand, 'long')}${type === 'permanent' ? ' puis selon la fréquence choisie' : ''}`)]];
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const mt = nombre(form.elements.montant.value);
      const type = form.elements.type.value;
      const quand = type === 'instantane' ? new Date().toISOString().slice(0, 10) : form.elements.date.value;
      if (!form.elements.compte.value) throw new ErreurGmb('Aucun compte ne permet d’émettre un virement.');
      if (!form.elements.beneficiaire.value) throw new ErreurGmb('Choisissez un bénéficiaire.');
      if (!(mt > 0)) throw new ErreurGmb('Indiquez un montant positif, par exemple 25,50.');
      if (type !== 'instantane' && (!quand || quand < new Date().toISOString().slice(0, 10))) throw new ErreurGmb('Choisissez une date à venir.');
      if (form.elements.motif.value.length > 140) throw new ErreurGmb('Le motif ne doit pas dépasser 140 caractères.');
      const parametres = { p_compte: form.elements.compte.value, p_beneficiaire: form.elements.beneficiaire.value, p_montant: mt, p_motif: form.elements.motif.value.trim() || null, p_type: type, p_date: quand, p_frequence: type === 'permanent' ? form.elements.frequence.value : null };
      let cree;
      try {
        cree = await appeler('gmb_virement_creer', parametres);
      } catch (erreur) {
        if (!/nom du bénéficiaire/i.test(erreur.message || '')) throw erreur;
        const choix = await demander('Vérification du bénéficiaire', [{ nom: 'choix', libelle: 'Que souhaitez-vous faire ?', options: [['annuler', 'J’annule ce virement'], ['continuer', 'Je confirme ce bénéficiaire et je continue']] }], { valider: 'Valider mon choix', intro: e(erreur.message) });
        if (!choix || choix.choix === 'annuler') { message('Virement annulé.', 'info'); return; }
        cree = await appeler('gmb_virement_creer', { ...parametres, p_vop_choix: 'continuer' });
      }
      if (cree.statut === 'en_approbation') { message('Virement soumis à l’approbation des responsables de votre entreprise.', 'succes'); form.reset(); majType(); return; }
      const b = beneficiaires.find((y) => y.id === parametres.p_beneficiaire);
      const k = comptes.find((y) => y.id === parametres.p_compte);
      const r = await validerVirement(ctx, cree.virement, details(b, k, mt, type, quand));
      if (r) { form.reset(); majType(); }
    });
  });
  const reprendre = parametre('reprendre');
  if (reprendre) {
    const v = await lire('virements', { egal: { id: reprendre }, unique: true });
    if (v?.statut === 'a_valider') await validerVirement(ctx, v.id, details(beneficiaires.find((b) => b.id === v.beneficiaire_id), comptes.find((k) => k.id === v.compte_id), v.montant, v.type, v.date_execution)).catch((x) => message(x.message));
  }
}

async function programmes() {
  const ctx = await ouvrirEspace('virements');
  const rendre = async () => {
    const ids = ctx.comptes;
    const [liste, beneficiaires] = await Promise.all([ids.length ? lire('virements', { dans: { compte_id: ids }, ordre: 'created_at', croissant: false, limite: 100 }) : [], lire('beneficiaires', { colonnes: 'id, nom, nom_verifie' })]);
    const nom = Object.fromEntries(beneficiaires.map((b) => [b.id, b.nom_verifie || b.nom]));
    const aVenir = liste.filter((v) => ['a_valider', 'en_approbation', 'valide'].includes(v.statut));
    $('[data-a-venir]').innerHTML = tableau('Virements à venir', ['Bénéficiaire', 'Montant', 'Exécution', 'Statut', 'Actions'], aVenir.map((v) => [e(nom[v.beneficiaire_id] || '—'), montant(v.montant, { toujours: true }),
      e(`${date(v.date_execution, 'long')}${v.frequence ? ` · ${FREQUENCES.find(([f]) => f === v.frequence)?.[1].toLowerCase() || v.frequence}` : ''}`), badge(STATUTS_VIREMENT[v.statut] || v.statut),
      `${v.statut === 'a_valider' ? `<a class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" href="${page('comptes/virements.html', `?reprendre=${v.id}`)}">Valider</a> ` : ''}<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-annuler="${v.id}">Annuler</button>`]), 'Aucun virement à venir.');
    $('[data-historique]').innerHTML = tableau('Derniers virements', ['Bénéficiaire', 'Montant', 'Créé le', 'Statut'], liste.filter((v) => !aVenir.includes(v)).slice(0, 50).map((v) => [e(nom[v.beneficiaire_id] || '—'), montant(v.montant, { toujours: true }), date(v.created_at, 'long'),
      `${badge(STATUTS_VIREMENT[v.statut] || v.statut, v.statut === 'rejete' ? 'danger' : v.statut === 'execute' ? 'succes' : 'neutre')}${v.motif_rejet ? `<br><small>${e(v.motif_rejet)}</small>` : ''}`]), 'Aucun virement.');
  };
  $('[data-a-venir]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-annuler]');
    if (!b) return;
    executer(b, async () => {
      const r = await demander('Annuler ce virement ?', [], { valider: 'Oui, annuler', danger: true });
      if (!r) return;
      await appeler('gmb_virement_annuler', { p_virement: b.dataset.annuler });
      await rendre();
    }, 'Virement annulé.');
  });
  await rendre();
}

async function beneficiaires() {
  const ctx = await ouvrirEspace('virements');
  const reglages = await lire('parametres_securite', { colonnes: 'cle, valeur', dans: { cle: ['nouveau_beneficiaire_plafond', 'nouveau_beneficiaire_heures'] } });
  const plafond = reglages.find((x) => x.cle === 'nouveau_beneficiaire_plafond')?.valeur ?? 1000;
  const heures = reglages.find((x) => x.cle === 'nouveau_beneficiaire_heures')?.valeur ?? 72;
  const VOP = { correspondance: ['Nom vérifié', 'succes'], partielle: ['Nom proche', 'neutre'], aucune: ['Nom non concordant', 'danger'], impossible: ['Vérification impossible', 'neutre'] };
  const rendre = async () => {
    const liste = await lire('beneficiaires', { ordre: 'nom', croissant: true });
    $('[data-liste]').innerHTML = tableau('Vos bénéficiaires', ['Bénéficiaire', 'Compte', 'Vérification du nom', 'Actions'], liste.map((b) => [`${e(b.nom_verifie || b.nom)}${b.favori ? ' ★' : ''}${b.plafond_temporaire_jusqu && new Date(b.plafond_temporaire_jusqu) > new Date() ? `<br><small>Plafond de ${e(formaterMontant(b.plafond_temporaire))} jusqu’au ${date(b.plafond_temporaire_jusqu, 'long')}</small>` : ''}`,
      e(b.numero_compte ? `GerMoonBank n° ${b.numero_compte}` : b.iban || '—'), b.vop_resultat ? badge(...VOP[b.vop_resultat]) : '—',
      `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-favori="${b.id}" data-valeur="${b.favori ? 'false' : 'true'}" aria-pressed="${Boolean(b.favori)}">${b.favori ? 'Retirer des favoris' : 'Favori'}</button>
       <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-supprimer="${b.id}" data-nom="${e(b.nom_verifie || b.nom)}">Supprimer</button>`]), 'Aucun bénéficiaire enregistré.');
  };
  $('[data-liste]').addEventListener('click', (x) => {
    const b = x.target.closest('button');
    if (!b) return;
    if (b.dataset.favori) executer(b, async () => { await modifier('beneficiaires', b.dataset.favori, { favori: b.dataset.valeur === 'true' }); await rendre(); });
    if (b.dataset.supprimer) executer(b, async () => {
      const r = await demander(`Supprimer ${b.dataset.nom} ?`, [], { valider: 'Supprimer', danger: true, intro: 'Les virements programmés vers ce bénéficiaire ne seront plus possibles.' });
      if (!r) return;
      await supprimer('beneficiaires', b.dataset.supprimer);
      await rendre();
    }, 'Bénéficiaire supprimé.');
  });
  $('[data-ajouter]').addEventListener('click', (x) => executer(x.currentTarget, async () => {
    const saisie = await demander('Ajouter un bénéficiaire', [{ nom: 'nom', libelle: 'Nom du titulaire du compte', requis: true }, { nom: 'compte', libelle: 'IBAN ou numéro de compte GerMoonBank', requis: true, aide: 'IBAN de la zone SEPA, ou numéro de compte GerMoonBank à 11 chiffres.' }], { valider: 'Vérifier' });
    if (!saisie) return;
    const compte = saisie.compte.replace(/\s/g, '').toUpperCase();
    const v = await appeler('gmb_vop_verifier', { p_nom: saisie.nom, p_iban: compte });
    if (v.resultat === 'iban_invalide') throw new ErreurGmb(v.message || 'Ce compte n’est pas valide.');
    let utiliserNomVerifie = false;
    if (v.resultat !== 'correspondance') {
      const options = v.resultat === 'partielle' && (v.nom_verifie || v.nom) ? [['verifie', `Utiliser le nom enregistré : ${v.nom_verifie || v.nom}`], ['saisi', 'Garder le nom saisi'], ['annuler', 'Annuler']] : [['saisi', 'Je confirme et je continue'], ['annuler', 'Annuler']];
      const c = await demander('Vérification du nom du bénéficiaire', [{ nom: 'choix', libelle: 'Que souhaitez-vous faire ?', options }], { valider: 'Valider mon choix', intro: e(v.message || 'Le nom ne correspond pas exactement au titulaire du compte.') });
      if (!c || c.choix === 'annuler') return;
      utiliserNomVerifie = c.choix === 'verifie';
    }
    const code = await authentifier('Ajouter ce bénéficiaire', [['Nom', e(utiliserNomVerifie ? (v.nom_verifie || v.nom) : saisie.nom)], ['Compte', e(compte)], ['Sécurité', e(`virements limités à ${formaterMontant(plafond)} pendant ${heures} heures`)]], ctx.client.identifiant);
    if (!code) return;
    const r = await appeler('gmb_beneficiaire_ajouter', { p_nom: saisie.nom, p_iban: compte, p_grille: code.grille, p_positions: code.positions, p_utiliser_nom_verifie: utiliserNomVerifie });
    await refusSca(r);
    await rendre();
    message(`Bénéficiaire ajouté. Par sécurité, vos virements vers lui sont limités à ${formaterMontant(plafond)} pendant ${heures} heures.`, 'succes');
  }));
  await rendre();
}

async function internationaux() { await ouvrirEspace('virements'); }
demarrerPage({ virements, programmes, beneficiaires, internationaux });
