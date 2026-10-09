/* =============================================================================
   GerMoonBank (GMB) · js/app/app.js
   Socle de l'Espace client — version 5 (application bancaire « Nuit »)
   -----------------------------------------------------------------------------
   Accès réservé aux clients connectés (compte technique de l'Espace client),
   navigation limitée aux pages livrées, déconnexion après inactivité (DSP2 :
   5 minutes au plus, alerte 1 minute avant, selon parametres_securite), mode
   discret des montants, fenêtres de saisie et authentification forte : le code
   secret est saisi sur le clavier aléatoire, pour une opération précise dont le
   montant et le bénéficiaire sont affichés juste avant.
   Version 5 :
   - apparence « Nuit » par défaut, comme l'aperçu de l'application sur le site ;
     « Claire » ou « Comme mon appareil » au choix (Paramètres › Apparence) ;
   - cadre d'application : avatar et salutation (Bonjour / Bonsoir) sur les
     rubriques, bouton de retour sur les pages intérieures, barre d'onglets en bas
     du téléphone, menu latéral sur ordinateur, feuille « Plus » ;
   - fiche complète d'une opération (date et heure, titulaire, compte,
     contrepartie et son IBAN, motif, référence, date de valeur, statut) ;
   - visuel des cartes GerMoonBank ; mention légale unique en bas de page.
   ========================================================================== */

import { chemin, formaterMontant, formaterDate, echapperHtml, icone, logoSVG } from '../core.js';
import { client, session, espaceDe, contexte, lire, appeler, messageErreur, ErreurGmb, oublierContexte } from '../donnees.js';
import { occupe, afficherMessage, erreurChamp } from '../forms.js';
import { Clavier } from '../auth.js';

export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => [...r.querySelectorAll(s)];
export const e = (t) => echapperHtml(String(t ?? ''));
export const date = (d, f = 'court') => (d ? formaterDate(String(d).length === 10 ? `${d}T12:00:00` : d, f) : '—');
export const parametre = (nom) => new URLSearchParams(location.search).get(nom);
export const page = (nom, extra = '') => chemin(`app/${nom}${extra}`);

/* -----------------------------------------------------------------------------
   Apparence : « Nuit » par défaut. Appliquée dès le chargement du module, avant
   l'affichage du contenu. La valeur est celle qu'enregistre Paramètres › Apparence :
   'clair', 'sombre', ou '' (comme l'appareil).
   -------------------------------------------------------------------------- */
const CLE_THEME = 'gmb-theme';
const lireApparence = () => { try { return localStorage.getItem(CLE_THEME); } catch { return null; } };
export function appliquerApparence(valeur = lireApparence()) {
  // L'Espace Mon Dossier (demandeurs) garde l'apparence claire du site
  if (document.body?.dataset.app?.startsWith('dossier')) return 'claire';
  const claire = valeur === 'clair' || (valeur === '' && matchMedia('(prefers-color-scheme: light)').matches);
  if (claire) document.documentElement.dataset.apparence = 'claire'; else delete document.documentElement.dataset.apparence;
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', claire ? '#F4F5FB' : '#0B0926');
  return claire ? 'claire' : 'nuit';
}
appliquerApparence();

/* Rubriques livrées : la navigation ne propose jamais une page absente.
   Les quatre premières occupent la barre d'onglets du téléphone, les autres la feuille « Plus ». */
const RUBRIQUES = [
  { cle: 'accueil', libelle: 'Accueil', adresse: 'index.html', icone: 'maison', teinte: 'violet' },
  { cle: 'comptes', libelle: 'Comptes', adresse: 'comptes/index.html', icone: 'banque', teinte: 'violet' },
  { cle: 'virements', libelle: 'Virements', adresse: 'comptes/virements.html', icone: 'virement', teinte: 'violet' },
  { cle: 'cartes', libelle: 'Cartes', adresse: 'cartes/index.html', icone: 'carte', teinte: 'violet' },
  { cle: 'epargne', libelle: 'Épargne', adresse: 'epargne/index.html', icone: 'epargne', teinte: 'teal' },
  { cle: 'credit', libelle: 'Crédit', adresse: 'credit/index.html', icone: 'croissance', teinte: 'ambre' },
  { cle: 'placements', libelle: 'Placements', adresse: 'investissement/index.html', icone: 'graphique', teinte: 'ciel' },
  { cle: 'documents', libelle: 'Documents', adresse: 'documents/index.html', icone: 'dossier', teinte: 'ardoise' },
  { cle: 'messages', libelle: 'Messages', adresse: 'messages/index.html', icone: 'support', teinte: 'rose' },
  { cle: 'parametres', libelle: 'Paramètres', adresse: 'parametres/profil.html', icone: 'cadenas', teinte: 'ardoise' },
];
export const RUBRIQUES_LIVREES = new Set(['accueil', 'comptes', 'virements', 'cartes', 'epargne', 'credit', 'placements', 'documents', 'messages', 'parametres']);
const PRINCIPALES = new Set(['accueil', 'comptes', 'virements', 'cartes']);

/* -----------------------------------------------------------------------------
   Icônes propres à l'Espace client (tracés 24 × 24, trait de 2, comme celles du site)
   -------------------------------------------------------------------------- */
const TRACES_EC = {
  panier: '<circle cx="9.5" cy="19.5" r="1.5"/><circle cx="17" cy="19.5" r="1.5"/><path d="M3 4h2.2l2.3 10.6a1.5 1.5 0 0 0 1.5 1.2h8.4a1.5 1.5 0 0 0 1.5-1.1L21 8H6.1"/>',
  couverts: '<path d="M7 3v7a2 2 0 0 0 4 0V3"/><path d="M9 12v9"/><path d="M17 21V3c-2.2 1.3-3.3 3.6-3.3 6.8V13H17"/>',
  train: '<rect x="5" y="3" width="14" height="13" rx="3"/><path d="M5 10h14"/><path d="M8.5 13h.01M15.5 13h.01"/><path d="m8 21 2-5M16 21l-2-5"/>',
  coeur: '<path d="M12 20.5s-7.5-4.6-7.5-10.4A4.1 4.1 0 0 1 12 7.6a4.1 4.1 0 0 1 7.5 2.5c0 5.8-7.5 10.4-7.5 10.4z"/>',
  sac: '<path d="M5.5 8h13l-1 12.5h-11z"/><path d="M9 10V6.5a3 3 0 0 1 6 0V10"/>',
  repeter: '<path d="m17 2 3 3-3 3"/><path d="M4 11V9a4 4 0 0 1 4-4h12"/><path d="m7 22-3-3 3-3"/><path d="M20 13v2a4 4 0 0 1-4 4H4"/>',
  entree: '<path d="M17 7 7 17"/><path d="M16 17H7V8"/>',
  sortie: '<path d="M7 17 17 7"/><path d="M8 7h9v9"/>',
  recu: '<path d="M6 2.8h12v18.4l-3-2-3 2-3-2-3 2z"/><path d="M9 8h6M9 12h6"/>',
  recevoir: '<path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/>',
  ajouter: '<path d="M12 5v14M5 12h14"/>',
  points: '<circle cx="5" cy="12" r="1.7" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.7" fill="currentColor" stroke="none"/>',
  horloge: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  sortir: '<path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><path d="m10 17 5-5-5-5"/><path d="M15 12H3"/>',
  retour: '<path d="m15 18-6-6 6-6"/>',
  oeil: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  copier: '<rect x="9" y="9" width="12" height="12" rx="2.5"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/>',
  document: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9 13h6M9 17h4"/>',
  sanscontact: '<path d="M8.5 8.5a5 5 0 0 1 0 7"/><path d="M12 6a8.5 8.5 0 0 1 0 12"/><path d="M15.5 3.5a12 12 0 0 1 0 17"/>',
  tableur: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><path d="M3 10h18M3 15h18M9 4v16"/>',
  camion: '<path d="M2 6h11v10H2z"/><path d="M13 9h4.5l3.5 3.5V16h-8"/><circle cx="6" cy="18" r="1.8"/><circle cx="17" cy="18" r="1.8"/>',
  gel: '<path d="M12 2v20M4.9 6.5l14.2 11M19.1 6.5 4.9 17.5"/><path d="m9.5 3.5 2.5 2 2.5-2M9.5 20.5l2.5-2 2.5 2"/>',
  reglages: '<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
};
/** Icône de l'Espace client, ou à défaut celle du site (core.js). */
export function iconeEc(nom, taille = 20) {
  if (!TRACES_EC[nom]) return icone(nom, { taille });
  return `<svg class="gmb-icone" viewBox="0 0 24 24" width="${taille}" height="${taille}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${TRACES_EC[nom]}</svg>`;
}
/** Pastille de couleur portant une icône (comptes, opérations, rubriques). */
export const pastille = (nom, teinte, forme = '') => `<span class="app-pastille app-pastille--${teinte}${forme ? ` app-pastille--${forme}` : ''}" aria-hidden="true">${iconeEc(nom)}</span>`;

/* -----------------------------------------------------------------------------
   Messages, actions, montants
   -------------------------------------------------------------------------- */
export function message(texte, type = 'erreur') {
  afficherMessage($('[data-message]'), texte, type);
  if (texte) $('[data-message]')?.scrollIntoView({ block: 'nearest' });
}
export async function executer(bouton, action, succes) {
  message('');
  occupe(bouton, true);
  try { await action(); if (succes) message(succes, 'succes'); } catch (x) { message(messageErreur(x)); } finally { occupe(bouton, false); }
}
const DISCRET = 'gmb-montants-discrets';
export const discret = () => { try { return localStorage.getItem(DISCRET) === '1'; } catch { return false; } };
/** Montant affiché (masqué en mode discret, sauf demande contraire). Avec signe : les crédits sont mis en valeur. */
export function montant(v, { signe = false, toujours = false } = {}) {
  if (discret() && !toujours) return '<span class="app-discret" aria-label="Montant masqué">•••• €</span>';
  const n = Number(v || 0);
  return `<span class="app-montant${n < 0 ? ' app-montant--negatif' : ''}${signe && n > 0 ? ' app-montant--credit' : ''}">${signe && n > 0 ? '+' : ''}${e(formaterMontant(n))}</span>`;
}
export const badge = (texte, type = 'neutre') => `<span class="gmb-badge gmb-badge--${type}">${e(texte)}</span>`;
/** Tableau accessible ; sur téléphone, chaque ligne s'affiche en bloc, chaque valeur précédée du nom de sa colonne. */
export function tableau(legende, entetes, lignes, vide = 'Aucun élément.') {
  if (!lignes.length) return `<p class="app-vide">${e(vide)}</p>`;
  return `<div class="gmb-tableau-zone" tabindex="0" role="region" aria-label="${e(legende)}"><table class="gmb-tableau app-tableau"><caption>${e(legende)}</caption>
    <thead><tr>${entetes.map((h) => `<th scope="col">${e(h)}</th>`).join('')}</tr></thead>
    <tbody>${lignes.map((l) => `<tr>${l.map((c, i) => (i === 0 ? `<th scope="row">${c}</th>` : `<td data-label="${e(entetes[i] || '')}">${c}</td>`)).join('')}</tr>`).join('')}</tbody></table></div>`;
}

/* -----------------------------------------------------------------------------
   Comptes, opérations, cartes : lignes et visuels communs
   -------------------------------------------------------------------------- */
export const TYPES_COMPTE = { courant: 'Compte courant', livret: 'Livret GerMoon+', coffre: 'Coffre', devise: 'Compte en devise', crypto: 'Portefeuille crypto', titres: 'Compte-titres', jeune: 'Compte Jeunes', pro: 'Compte Pro', business: 'Compte Business' };
export const STATUTS_VIREMENT = { a_valider: 'À valider', en_approbation: 'En approbation', valide: 'Programmé', a_executer: 'En cours de traitement', execute: 'Exécuté', rejete: 'Rejeté', annule: 'Annulé' };
const ASPECT_COMPTE = { courant: ['banque', 'violet'], pro: ['mallette', 'nuit'], business: ['entreprise', 'nuit'], jeune: ['sourire', 'rose'], livret: ['epargne', 'teal'],
  coffre: ['coffre', 'rose'], devise: ['globe', 'ciel'], titres: ['graphique', 'ambre'], crypto: ['eclair', 'nuit'] };
export const aspectCompte = (type) => ASPECT_COMPTE[type] || ['banque', 'violet'];
/* Ordre d'affichage des comptes : paiement, puis épargne, puis les autres (à type égal, le plus ancien d'abord) */
const ORDRE_COMPTES = { courant: 0, pro: 0, business: 0, jeune: 0, livret: 1, coffre: 2, devise: 3, titres: 4, crypto: 5 };
export const trierComptes = (liste) => [...liste].sort((a, b) => (ORDRE_COMPTES[a.type] ?? 9) - (ORDRE_COMPTES[b.type] ?? 9));
/** Numéro de compte ou IBAN groupé par quatre caractères, lisible et dictable. */
export const numeroLisible = (n) => String(n || '').replace(/\s/g, '').replace(/(.{4})(?=.)/g, '$1 ');
const finNumero = (n) => `<span class="app-masque" aria-hidden="true">••••</span><span class="gmb-visuellement-masque">Numéro se terminant par </span>${e(String(n || '').slice(-4))}`;
/** Ligne d'un compte : pastille, nom, numéro, solde. */
export function ligneCompte(k, { lien = true, numeroComplet = true } = {}) {
  const [ic, teinte] = aspectCompte(k.type);
  const numero = numeroComplet ? `n° ${e(numeroLisible(k.numero))}` : finNumero(k.numero);
  const statut = k.statut && k.statut !== 'actif' ? ` ${badge(k.statut === 'bloque' ? 'Bloqué' : k.statut === 'cloture' ? 'Clôturé' : k.statut, 'neutre')}` : '';
  const taux = k.taux !== null && k.taux !== undefined && ['livret', 'coffre'].includes(k.type) ? `<span class="app-ligne__taux">${e(String(k.taux).replace('.', ','))} %</span>` : '';
  const corps = `${pastille(ic, teinte, 'carre')}<span class="app-ligne__corps"><span class="app-ligne__titre">${e(k.libelle || TYPES_COMPTE[k.type] || k.type)}${statut}</span>
    <span class="app-ligne__detail"><span>${numero}</span>${taux}</span></span>
    <span class="app-ligne__fin">${montant(k.solde)}</span>`;
  return lien ? `<li><a class="app-ligne app-ligne--lien" href="${page('comptes/courant.html', `?id=${k.id}`)}">${corps}${iconeEc('chevronDroite', 18)}</a></li>` : `<li><div class="app-ligne">${corps}</div></li>`;
}

const ASPECT_CATEGORIE = { alimentation: ['panier', 'teal'], restaurants: ['couverts', 'ambre'], transports: ['train', 'ciel'], logement: ['maison', 'violet'], loisirs: ['sourire', 'rose'],
  sante: ['coeur', 'rose'], shopping: ['sac', 'violet'], voyages: ['valise', 'ciel'], abonnements: ['repeter', 'ardoise'], salaire: ['mallette', 'teal'], epargne: ['epargne', 'teal'],
  impots: ['banque', 'ardoise'], transferts: ['virement', 'violet'], frais: ['recu', 'ardoise'], autres: ['dossier', 'ardoise'] };
const ASPECT_TYPE = { virement_recu: ['entree', 'teal'], remboursement: ['entree', 'teal'], versement_initial: ['entree', 'teal'], credit: ['entree', 'teal'], virement_emis: ['sortie', 'violet'],
  carte: ['carte', 'violet'], prelevement: ['repeter', 'ardoise'], interets: ['croissance', 'teal'], frais: ['recu', 'ardoise'], interne: ['virement', 'violet'], arrondi: ['epargne', 'teal'],
  moonpoints: ['eclair', 'rose'], argent_de_poche: ['sourire', 'rose'] };
export const LIBELLES_CATEGORIE = { alimentation: 'Courses', restaurants: 'Restaurants', transports: 'Transports', logement: 'Logement', loisirs: 'Loisirs', sante: 'Santé', shopping: 'Shopping',
  voyages: 'Voyages', abonnements: 'Abonnements', salaire: 'Revenus', epargne: 'Épargne', impots: 'Impôts', transferts: 'Virements', frais: 'Frais bancaires', autres: 'Autres' };
export const CATEGORIES = Object.entries(LIBELLES_CATEGORIE);
export const LIBELLES_TYPE_OPERATION = { virement_recu: 'Virement reçu', virement_emis: 'Virement émis', carte: 'Paiement par carte', prelevement: 'Prélèvement', interets: 'Intérêts',
  frais: 'Frais bancaires', arrondi: 'Arrondi épargné', interne: 'Virement entre vos comptes', remboursement: 'Remboursement', versement_initial: 'Premier versement',
  moonpoints: 'MoonPoints', argent_de_poche: 'Argent de poche', credit: 'Versement du prêt' };
const STATUTS_OPERATION = { comptabilisee: 'Effectuée', en_attente: 'En attente', refusee: 'Refusée', annulee: 'Annulée' };
/* Un virement se reconnaît à son sens (flèche entrante ou sortante) ; un paiement, à sa catégorie */
const SENS_D_ABORD = new Set(['virement_recu', 'virement_emis', 'versement_initial', 'remboursement', 'credit']);
export const aspectOperation = (o) => (SENS_D_ABORD.has(o.type) && (!o.categorie_code || o.categorie_code === 'transferts') ? ASPECT_TYPE[o.type] : null)
  || ASPECT_CATEGORIE[o.categorie_code] || ASPECT_TYPE[o.type] || [Number(o.montant) > 0 ? 'entree' : 'sortie', Number(o.montant) > 0 ? 'teal' : 'violet'];
const JOURS = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' });
const JOUR_COURT = new Intl.DateTimeFormat('fr-FR', { day: 'numeric', month: 'short' });
const HEURE = new Intl.DateTimeFormat('fr-FR', { hour: '2-digit', minute: '2-digit' });
const DATE_HEURE = new Intl.DateTimeFormat('fr-FR', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
const jourIso = (d) => { const x = new Date(d); return `${x.getFullYear()}-${String(x.getMonth() + 1).padStart(2, '0')}-${String(x.getDate()).padStart(2, '0')}`; };
const majuscule = (t) => t.charAt(0).toUpperCase() + t.slice(1);
/** « Aujourd'hui », « Hier » ou « Mardi 6 octobre ». */
export function jourRelatif(d) {
  const iso = jourIso(d); const hier = new Date(); hier.setDate(hier.getDate() - 1);
  if (iso === jourIso(new Date())) return 'Aujourd’hui';
  if (iso === jourIso(hier)) return 'Hier';
  return majuscule(JOURS.format(new Date(d)));
}
/** Ligne d'une opération : pastille de catégorie, libellé, détail, montant (crédit mis en valeur).
 *  Avec un identifiant, la ligne ouvre la fiche complète de l'opération. */
export function ligneOperation(o, { action = '', lien = '', avecJour = true } = {}) {
  const [ic, teinte] = aspectOperation(o);
  const quand = o.date_operation || o.created_at;
  // Accueil : le jour de l'opération ; historique (déjà groupé par jour) : la catégorie ou la contrepartie
  const jour = jourRelatif(quand);
  const detail = avecJour ? (jour === 'Aujourd’hui' ? `Aujourd’hui, ${HEURE.format(new Date(quand))}` : jour === 'Hier' ? `Hier, ${HEURE.format(new Date(quand))}` : JOUR_COURT.format(new Date(quand)))
    : (LIBELLES_CATEGORIE[o.categorie_code] || o.contrepartie_nom || LIBELLES_TYPE_OPERATION[o.type] || '');
  const etat = o.statut && o.statut !== 'comptabilisee' ? ` ${badge(STATUTS_OPERATION[o.statut] || o.statut, o.statut === 'refusee' ? 'danger' : 'neutre')}` : '';
  const corps = `${pastille(ic, teinte)}<span class="app-ligne__corps"><span class="app-ligne__titre">${e(o.libelle)}${etat}</span>${detail ? `<span class="app-ligne__detail">${e(detail)}</span>` : ''}</span>
    <span class="app-ligne__fin">${montant(o.montant, { signe: true })}</span>`;
  if (action) return `<li><button type="button" class="app-ligne app-ligne--lien" aria-haspopup="dialog" ${action}>${corps}</button></li>`;
  if (lien) return `<li><a class="app-ligne app-ligne--lien" href="${lien}">${corps}</a></li>`;
  return `<li><div class="app-ligne">${corps}</div></li>`;
}
/** Opérations groupées par jour (historique). */
export function operationsParJour(operations, ligne) {
  const groupes = new Map();
  for (const o of operations) { const j = jourIso(o.date_operation || o.created_at); if (!groupes.has(j)) groupes.set(j, []); groupes.get(j).push(o); }
  return [...groupes.values()].map((l) => `<section class="app-jour" aria-label="${e(jourRelatif(l[0].date_operation || l[0].created_at))}"><h3 class="app-jour__titre">${e(jourRelatif(l[0].date_operation || l[0].created_at))}</h3>
    <ul class="app-groupe">${l.map(ligne).join('')}</ul></section>`).join('');
}

/* Cartes : visuel aux couleurs de la formule. Marque GerMoonBank, puce, sans contact, numéro
   masqué (quatre derniers chiffres), titulaire, expiration, mention « Débit ». Une carte commandée
   et pas encore activée ne montre pas ses chiffres. */
const VARIANTE_CARTE = { luna: 'nuit', halo: 'marque', orbit: 'marque', eclipse: 'nuit', zenith: 'metal', pro_solo: 'metal', pro_plus: 'metal',
  business_start: 'nuit', business_growth: 'metal', business_scale: 'metal' };
export const NOMS_FORMULE = { luna: 'LUNA', halo: 'HALO', orbit: 'ORBIT', eclipse: 'ÉCLIPSE', zenith: 'ZÉNITH', pro_solo: 'PRO SOLO', pro_plus: 'PRO PLUS',
  business_start: 'BUSINESS', business_growth: 'BUSINESS', business_scale: 'BUSINESS' };
const ETATS_VISUEL = { commandee: 'À activer', gelee: 'Gelée', opposition: 'Opposition', expiree: 'Expirée' };
/** Code de formule à partir d'un nom (« Éclipse », « Pro Solo ») ou d'un code. */
export const codeFormule = (f) => String(f || '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').trim().replace(/\s+/g, '_');
/** Visuel d'une carte bancaire GerMoonBank. */
export function visuelCarte({ formule = '', chiffres = '', titulaire = '', expiration = '', type = 'physique', statut = 'active' } = {}) {
  const code = codeFormule(formule);
  const visibles = /^\d{4}$/.test(String(chiffres)) && statut !== 'commandee';
  return `<div class="app-carte-visuel app-carte-visuel--${VARIANTE_CARTE[code] || 'marque'}" data-type="${e(type)}" data-statut="${e(statut)}" aria-hidden="true"><div class="app-carte-visuel__face">
    <span class="app-carte-visuel__lune"></span>
    <div class="app-carte-visuel__haut"><span class="app-carte-visuel__logo">${logoSVG({ variante: 'icone', decoratif: true })}</span><span class="app-carte-visuel__formule">${e(NOMS_FORMULE[code] || String(formule || 'GerMoonBank').toUpperCase())}</span></div>
    <div class="app-carte-visuel__milieu">${type === 'physique' ? '<span class="app-carte-visuel__puce"></span>' : '<span class="app-carte-visuel__virtuelle">Virtuelle</span>'}${iconeEc('sanscontact', 22)}${ETATS_VISUEL[statut] ? `<span class="app-carte-visuel__etat">${e(ETATS_VISUEL[statut])}</span>` : ''}</div>
    <div class="app-carte-visuel__numero">•••• •••• •••• ${visibles ? e(chiffres) : '••••'}</div>
    <div class="app-carte-visuel__bas"><span class="app-carte-visuel__titulaire">${e(titulaire)}</span>${expiration ? `<span class="app-carte-visuel__expiration"><small>Exp.</small>${e(expiration)}</span>` : ''}<span class="app-carte-visuel__debit">Débit</span></div>
  </div></div>`;
}

/* -----------------------------------------------------------------------------
   Fenêtres : saisie, authentification forte, fiche d'opération
   -------------------------------------------------------------------------- */
function fenetre(titre, corps, classe = '') {
  const d = document.createElement('dialog');
  d.className = `gmb-dialogue app-dialogue${classe ? ` ${classe}` : ''}`;
  d.setAttribute('aria-labelledby', 'app-dialogue-titre');
  d.innerHTML = `<form method="dialog" class="gmb-pile gmb-pile--moyenne" novalidate><div class="app-dialogue__poignee" aria-hidden="true"></div><h2 class="gmb-section__titre gmb-section__titre--moyen" id="app-dialogue-titre">${e(titre)}</h2>${corps}</form>`;
  document.body.append(d);
  return d;
}

/** Saisie : renvoie les valeurs, ou null si annulée. Nombres en champ texte (virgule acceptée). */
export function demander(titre, champs, { valider = 'Valider', danger = false, intro = '' } = {}) {
  return new Promise((resoudre) => {
    const d = fenetre(titre, `${intro ? `<p class="app-dialogue__intro">${intro}</p>` : ''}${champs.map((c) => `<div class="gmb-champ"><label class="gmb-champ__libelle" for="app-${c.nom}">${e(c.libelle)}</label>
        ${c.options ? `<div class="gmb-liste"><select class="gmb-saisie" id="app-${c.nom}" name="${c.nom}">${c.options.map(([v, t]) => `<option value="${e(v)}"${String(c.valeur ?? '') === String(v) ? ' selected' : ''}>${e(t)}</option>`).join('')}</select></div>`
          : c.type === 'textarea' ? `<textarea class="gmb-saisie" id="app-${c.nom}" name="${c.nom}" rows="3">${e(c.valeur || '')}</textarea>`
          : `<input class="gmb-saisie" id="app-${c.nom}" name="${c.nom}" type="${c.type === 'number' ? 'text' : c.type || 'text'}"${c.type === 'number' ? ' inputmode="decimal" autocomplete="off"' : ''} value="${e(c.valeur ?? '')}">`}
        ${c.aide ? `<p class="gmb-champ__aide">${e(c.aide)}</p>` : ''}<p class="gmb-champ__erreur" id="app-${c.nom}-erreur" hidden></p></div>`).join('')}
      <div class="gmb-rangee"><button type="submit" class="gmb-bouton gmb-bouton--${danger ? 'danger' : 'principal'}">${e(valider)}</button><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-annuler>Annuler</button></div>`);
    const form = $('form', d);
    const fermer = (v) => { d.close(); d.remove(); resoudre(v); };
    $('[data-annuler]', d).addEventListener('click', () => fermer(null));
    d.addEventListener('cancel', (x) => { x.preventDefault(); fermer(null); });
    form.addEventListener('submit', (x) => {
      x.preventDefault();
      const valeurs = {}; let ok = true;
      for (const c of champs) {
        const el = form.elements[c.nom]; const v = String(el.value || '').trim();
        const n = c.type === 'number' && v ? Number(v.replace(/\s/g, '').replace(',', '.')) : null;
        const err = c.requis && !v ? `Indiquez ${c.libelle.toLowerCase()}.` : (c.type === 'number' && v && !Number.isFinite(n) ? 'Saisissez un nombre, par exemple 25,50.' : (c.verifier ? c.verifier(c.type === 'number' ? n : v) : ''));
        if (!erreurChamp(el, err || '')) ok = false;
        valeurs[c.nom] = c.type === 'number' ? n : v;
      }
      if (ok) fermer(valeurs);
    });
    d.showModal();
    $('input, select, textarea', d)?.focus();
  });
}

/** Authentification forte : récapitulatif de l'opération, puis code secret sur le clavier
 *  aléatoire. Renvoie { grille, positions } ou null si le client annule. */
export function authentifier(titre, lignes, identifiant, consigne = 'Pour confirmer, saisissez votre code secret.') {
  return new Promise((resoudre, rejeter) => {
    const d = fenetre(titre, `<dl class="app-recap">${lignes.map(([t, v]) => `<div><dt>${e(t)}</dt><dd>${v}</dd></div>`).join('')}</dl>
      <p class="app-dialogue__intro">${e(consigne)}</p><div id="app-clavier-sca" data-clavier></div>
      <div class="gmb-rangee"><button type="submit" class="gmb-bouton gmb-bouton--principal">Confirmer</button><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-annuler>Annuler</button></div>`, 'app-dialogue--clavier');
    const form = $('form', d);
    const clavier = new Clavier($('[data-clavier]', d), { surComplet: () => form.requestSubmit() });
    const fermer = (v) => { d.close(); d.remove(); resoudre(v); };
    $('[data-annuler]', d).addEventListener('click', () => fermer(null));
    d.addEventListener('cancel', (x) => { x.preventDefault(); fermer(null); });
    form.addEventListener('submit', (x) => { x.preventDefault(); if (clavier.complet()) fermer(clavier.saisie()); });
    d.showModal();
    clavier.charger(identifiant).catch((x) => { d.close(); d.remove(); rejeter(x); });
  });
}

/** Résultat d'une authentification forte refusée : message clair, déconnexion si l'accès est bloqué. */
export async function refusSca(r) {
  if (r?.statut === 'echec') throw new ErreurGmb(`Code secret incorrect. Il vous reste ${r.essais_restants} essai${r.essais_restants > 1 ? 's' : ''} avant le blocage de votre accès.`);
  if (r?.statut === 'bloque' || r?.statut === 'bloque_definitif') { await deconnecter(r.statut === 'bloque_definitif' ? 'auth/code-secret.html?raison=bloque' : 'auth/connexion.html?raison=bloque'); throw new ErreurGmb('Votre accès est bloqué par sécurité.'); }
  if (r?.statut === 'grille_expiree' || r?.statut === 'format') throw new ErreurGmb('Le clavier a expiré. Recommencez la validation.');
}

const CONTESTABLES = new Set(['carte', 'prelevement', 'frais']);
const VIREMENTS = new Set(['virement_recu', 'virement_emis', 'interne']);
/** Fiche complète d'une opération : tout ce que la banque enregistre, la catégorie et la note du client,
 *  la contestation d'un débit. Rappelle « apres » quand l'opération a été modifiée. */
export async function ficheOperation(idOperation, ctx, apres = () => {}) {
  const o = await lire('operations', { egal: { id: idOperation }, unique: true });
  if (!o) throw new ErreurGmb('Cette opération est introuvable.');
  const [compte, virement, carte] = await Promise.all([
    lire('comptes', { colonnes: 'id, type, libelle, numero, iban', egal: { id: o.compte_id }, unique: true }),
    o.virement_id ? lire('virements', { colonnes: 'id, motif, type, statut, date_execution, reference_execution, created_at', egal: { id: o.virement_id }, unique: true }).catch(() => null) : null,
    o.carte_id ? lire('cartes', { colonnes: 'type, gamme, derniers_chiffres', egal: { id: o.carte_id }, unique: true }).catch(() => null) : null,
  ]);
  const credit = Number(o.montant) > 0;
  const quand = new Date(o.date_operation || o.created_at);
  const [ic, teinte] = aspectOperation(o);
  const lignes = [
    ['Type', e(LIBELLES_TYPE_OPERATION[o.type] || o.type)],
    ['Date et heure', `${e(majuscule(DATE_HEURE.format(quand)))} à ${e(HEURE.format(quand))}`],
    o.date_valeur ? ['Date de valeur', e(date(o.date_valeur, 'long'))] : null,
    ['Titulaire du compte', e(ctx.nom || '—')],
    ['Compte', `${e(compte?.libelle || TYPES_COMPTE[compte?.type] || 'Compte')}<br><span class="app-fiche__secondaire">n° ${e(numeroLisible(compte?.numero))}</span>`],
  ];
  if (VIREMENTS.has(o.type) || o.contrepartie_nom || o.contrepartie_iban) {
    const role = credit ? 'Émetteur' : 'Bénéficiaire';
    if (o.contrepartie_nom) lignes.push([role, e(o.contrepartie_nom)]);
    if (o.contrepartie_iban) lignes.push([`${/^[A-Z]{2}\d{2}/.test(o.contrepartie_iban) ? 'IBAN' : 'Compte'} ${credit ? 'de l’émetteur' : 'du bénéficiaire'}`, `<code>${e(numeroLisible(o.contrepartie_iban))}</code>`]);
  }
  if (carte) lignes.push(['Carte', e(`${carte.type === 'physique' ? 'Carte' : 'Carte virtuelle'}${carte.gamme ? ` ${carte.gamme}` : ''} •••• ${carte.derniers_chiffres || '—'}`)]);
  if (o.lieu) lignes.push(['Lieu', e(o.lieu)]);
  if (o.devise_origine && o.montant_origine) lignes.push(['Montant d’origine', e(`${String(Math.abs(o.montant_origine)).replace('.', ',')} ${o.devise_origine}${o.taux_change ? `, au taux de ${String(o.taux_change).replace('.', ',')}` : ''}`)]);
  const motifVirement = virement?.motif || (VIREMENTS.has(o.type) ? o.motif : '');
  if (motifVirement) lignes.push(['Motif', e(motifVirement)]);
  lignes.push(['Référence', `<code>${e(o.reference || virement?.reference_execution || String(o.id).slice(0, 8).toUpperCase())}</code>`]);
  lignes.push(['Statut', `${badge(STATUTS_OPERATION[o.statut] || o.statut, o.statut === 'comptabilisee' ? 'succes' : o.statut === 'refusee' ? 'danger' : 'neutre')}${o.motif_refus ? `<br><span class="app-fiche__secondaire">${e(o.motif_refus)}</span>` : ''}`]);
  // La note du client n'écrase jamais le motif d'un virement (même colonne côté base)
  const note = !VIREMENTS.has(o.type);
  const contestable = !credit && o.statut === 'comptabilisee' && CONTESTABLES.has(o.type);
  return new Promise((resoudre) => {
    const d = fenetre(o.libelle, `<div class="app-fiche__tete"><span class="app-pastille app-pastille--${teinte} app-pastille--grande" aria-hidden="true">${iconeEc(ic, 26)}</span>
        <p class="app-fiche__montant">${montant(o.montant, { signe: true, toujours: true })}</p></div>
      <dl class="app-recap app-fiche__lignes">${lignes.filter(Boolean).map(([t, v]) => `<div><dt>${e(t)}</dt><dd>${v}</dd></div>`).join('')}</dl>
      <div class="gmb-champ"><label class="gmb-champ__libelle" for="app-fiche-categorie">Catégorie</label><div class="gmb-liste"><select class="gmb-saisie" id="app-fiche-categorie" name="categorie">
        <option value="">Sans catégorie</option>${CATEGORIES.map(([v, t]) => `<option value="${v}"${o.categorie_code === v ? ' selected' : ''}>${e(t)}</option>`).join('')}</select></div></div>
      ${note ? `<div class="gmb-champ"><label class="gmb-champ__libelle" for="app-fiche-note">Note personnelle</label><input class="gmb-saisie" id="app-fiche-note" name="note" type="text" maxlength="140" value="${e(o.motif || '')}"></div>` : ''}
      <div class="gmb-rangee"><button type="submit" class="gmb-bouton gmb-bouton--principal" data-enregistrer>Enregistrer</button><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-annuler>Fermer</button></div>
      ${contestable ? '<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--danger app-fiche__contester" data-contester>Je ne reconnais pas cette opération</button>' : ''}`, 'app-fiche');
    d.querySelector('h2').classList.add('app-fiche__titre');
    d.querySelector('h2').tabIndex = -1;
    const j = jourRelatif(quand);
    const jourTexte = j === 'Aujourd’hui' ? 'aujourd’hui' : j === 'Hier' ? 'hier' : `le ${JOUR_COURT.format(quand)}`;
    d.querySelector('h2').insertAdjacentHTML('afterend', `<p class="app-fiche__quand">${e(LIBELLES_TYPE_OPERATION[o.type] || 'Opération')}, ${e(jourTexte)} à ${e(HEURE.format(quand))}</p>`);
    d.querySelector('.app-fiche__tete').append(d.querySelector('.app-fiche__titre'), d.querySelector('.app-fiche__quand'));
    const form = $('form', d);
    const fermer = (modifie) => { d.close(); d.remove(); if (modifie) apres(); resoudre(modifie); };
    $('[data-annuler]', d).addEventListener('click', () => fermer(false));
    d.addEventListener('cancel', (x) => { x.preventDefault(); fermer(false); });
    form.addEventListener('submit', async (x) => {
      x.preventDefault();
      const b = $('[data-enregistrer]', d); occupe(b, true);
      try {
        await appeler('gmb_operation_annoter', { p_operation: o.id, p_categorie: form.elements.categorie.value || null, p_motif: note ? (form.elements.note.value.trim() || null) : (o.motif || null) });
        fermer(true); message('Opération mise à jour.', 'succes');
      } catch (y) { occupe(b, false); d.querySelector('.app-fiche__erreur')?.remove(); b.closest('.gmb-rangee').insertAdjacentHTML('beforebegin', `<p class="gmb-champ__erreur app-fiche__erreur">${e(messageErreur(y))}</p>`); }
    });
    $('[data-contester]', d)?.addEventListener('click', async () => {
      d.close(); d.remove();
      const c = await demander('Contester l’opération', [{ nom: 'motif', libelle: 'Expliquez ce qui s’est passé', type: 'textarea', requis: true }], { valider: 'Envoyer la contestation', danger: true,
        intro: 'Une opération non autorisée vous est remboursée au plus tard à la fin du premier jour ouvrable suivant, sauf soupçon de fraude de votre part. Faites aussi opposition sur votre carte si elle est en cause.' });
      if (c) {
        try { await appeler('gmb_operation_contester', { p_operation: o.id, p_motif: c.motif }); message('Contestation enregistrée : vous serez informé de son traitement.', 'succes'); apres(); } catch (y) { message(messageErreur(y)); }
      }
      resoudre(Boolean(c));
    });
    d.showModal();
    d.querySelector('.app-fiche__titre').focus(); // la fiche s'ouvre sur son titre, pas sur un champ
  });
}

/* -----------------------------------------------------------------------------
   Session, cadre, inactivité
   -------------------------------------------------------------------------- */
export async function deconnecter(vers = 'auth/connexion.html') {
  try { await (await client()).auth.signOut({ scope: 'local' }); } catch { /* déconnexion locale malgré tout */ }
  oublierContexte();
  location.replace(chemin(vers));
}

async function surveillerInactivite() {
  let limite = 5; let alerte = 4;
  try {
    const p = await lire('parametres_securite', { colonnes: 'cle, valeur', dans: { cle: ['inactivite_minutes', 'alerte_inactivite_minutes'] } });
    limite = Math.min(5, Number(p.find((x) => x.cle === 'inactivite_minutes')?.valeur) || 5);
    const demande = Number(p.find((x) => x.cle === 'alerte_inactivite_minutes')?.valeur);
    alerte = demande > 0 && demande < limite ? demande : limite * 0.8;
  } catch { /* valeurs réglementaires par défaut */ }
  let minuteurAlerte; let minuteurFin; let dialogue = null;
  const relancer = () => {
    clearTimeout(minuteurAlerte); clearTimeout(minuteurFin);
    minuteurAlerte = setTimeout(() => {
      dialogue = fenetre('Toujours là ?', `<p>Par sécurité, vous serez déconnecté dans 1 minute sans activité.</p><div class="gmb-rangee"><button type="submit" class="gmb-bouton gmb-bouton--principal">Rester connecté</button></div>`);
      $('form', dialogue).addEventListener('submit', (x) => { x.preventDefault(); dialogue.close(); dialogue.remove(); dialogue = null; relancer(); });
      dialogue.showModal();
    }, alerte * 60_000);
    minuteurFin = setTimeout(() => deconnecter('auth/connexion.html?raison=inactivite'), limite * 60_000);
  };
  ['pointerdown', 'keydown', 'scroll', 'touchstart'].forEach((t) => addEventListener(t, () => { if (!dialogue) relancer(); }, { passive: true }));
  relancer();
}

/** Liens associés écrits « A · B · C » : présentés en raccourcis (pastilles), séparateurs retirés. */
function raccourcis(racine = document) {
  for (const p of racine.querySelectorAll('.app-principal p:not(.app-raccourcis):not(.gmb-rangee):not(.app-mentions p)')) {
    const elements = [...p.children];
    if (elements.length < 2 || elements.some((x) => x.tagName !== 'A' || x.classList.contains('gmb-bouton'))) continue;
    const textes = [...p.childNodes].filter((x) => x.nodeType === Node.TEXT_NODE);
    if (textes.some((t) => !/^\s*·?\s*$/.test(t.textContent))) continue;
    textes.forEach((t) => t.remove());
    p.classList.add('app-raccourcis');
  }
}
function surveillerRaccourcis() {
  raccourcis();
  const zone = $('.app-principal');
  if (!zone) return;
  let prevu = false;
  new MutationObserver(() => { if (prevu) return; prevu = true; requestAnimationFrame(() => { prevu = false; raccourcis(); }); }).observe(zone, { childList: true, subtree: true });
}

/** Feuille « Plus » du téléphone : les rubriques qui ne tiennent pas dans la barre d'onglets. */
function feuillePlus(secondaires, rubrique) {
  const d = document.createElement('dialog');
  d.className = 'gmb-dialogue app-dialogue app-feuille';
  d.setAttribute('aria-labelledby', 'app-feuille-titre');
  d.innerHTML = `<div class="app-dialogue__poignee" aria-hidden="true"></div><h2 class="app-feuille__titre" id="app-feuille-titre">Toutes les rubriques</h2>
    <ul class="app-feuille__liste">${secondaires.map((r) => `<li><a class="app-feuille__lien" href="${page(r.adresse)}"${r.cle === rubrique ? ' aria-current="page"' : ''}>${pastille(r.icone, r.teinte, 'carre')}<span>${e(r.libelle)}</span></a></li>`).join('')}</ul>
    <div class="app-feuille__pied"><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-feuille-sortir>${iconeEc('sortir', 18)}<span>Se déconnecter</span></button>
      <button type="button" class="gmb-bouton gmb-bouton--fantome" data-feuille-fermer>Fermer</button></div>`;
  document.body.append(d);
  d.addEventListener('click', (x) => { if (x.target === d || x.target.closest('[data-feuille-fermer]')) d.close(); });
  $('[data-feuille-sortir]', d).addEventListener('click', () => deconnecter());
  return d;
}

/** Page de tête de la rubrique (accueil, comptes, virements…) ou page intérieure (avec retour). */
function racineDe(rubrique) {
  const r = RUBRIQUES.find((x) => x.cle === rubrique);
  if (!r) return null;
  const ici = location.pathname.replace(/\/$/, '/index.html');
  return { rubrique: r, estRacine: ici.endsWith(`/app/${r.adresse}`) };
}

/** Mention légale de l'Espace client : une seule, exacte, en bas de chaque page. */
function mentionLegale() {
  const zone = $('.app-principal');
  if (!zone || $('.app-mentions', zone)) return;
  zone.insertAdjacentHTML('beforeend', `<footer class="app-mentions"><p><strong>Statut.</strong> GerMoonBank est édité par The Hub of Inspiration of Soccer (HubISoccer), RCCM RB/ABC/24 A 111814, Bénin. GerMoonBank n’est pas un établissement agréé par l’ACPR : les sommes versées ne bénéficient pas de la garantie des dépôts (FGDR).</p>
    <p><a href="${chemin('public/legal/cgu.html')}">Conditions générales</a><a href="${chemin('public/legal/rgpd.html')}">Confidentialité</a><a href="${chemin('public/legal/mentions-legales.html')}">Mentions légales</a></p></footer>`);
}

function cadre(rubrique, ctx) {
  document.body.classList.add('app-corps--client');
  const livrees = RUBRIQUES.filter((r) => RUBRIQUES_LIVREES.has(r.cle));
  const secondaires = livrees.filter((r) => !PRINCIPALES.has(r.cle));
  const nav = $('[data-app-nav]');
  nav.innerHTML = `<a class="app-nav__marque" href="${page('index.html')}">${logoSVG({ titre: 'GerMoonBank, accueil de l’Espace client' })}</a>
    <ul class="app-nav__liste">${livrees.map((r) => `<li${PRINCIPALES.has(r.cle) ? ' data-principale' : ''}><a class="app-nav__lien" href="${page(r.adresse)}"${r.cle === rubrique ? ' aria-current="page"' : ''}>${icone(r.icone)}<span>${e(r.libelle)}</span></a></li>`).join('')}
    <li class="app-nav__plus"><button type="button" class="app-nav__lien" data-plus aria-haspopup="dialog" aria-expanded="false"${secondaires.some((r) => r.cle === rubrique) ? ' data-actif' : ''}>${iconeEc('points')}<span>Plus</span></button></li></ul>`;
  const feuille = feuillePlus(secondaires, rubrique);
  const plus = $('[data-plus]', nav);
  plus.addEventListener('click', () => { feuille.showModal(); plus.setAttribute('aria-expanded', 'true'); });
  feuille.addEventListener('close', () => plus.setAttribute('aria-expanded', 'false'));

  // Barre du haut : avatar et salutation sur les rubriques ; retour vers la rubrique sur les pages intérieures
  const heure = new Date().getHours();
  const identite = $('[data-app-identite]');
  identite.innerHTML = `<span class="app-avatar" aria-hidden="true">${e(ctx.initiales || '·')}</span><span class="app-entete__salut"><small>${heure >= 18 || heure < 5 ? 'Bonsoir' : 'Bonjour'}</small> <strong>${e(ctx.prenom || '')}</strong></span>`;
  const lieu = racineDe(rubrique);
  if (lieu && !lieu.estRacine) {
    document.body.classList.add('app-corps--interieur');
    $('.app-entete').insertAdjacentHTML('afterbegin', `<a class="app-retour" href="${page(lieu.rubrique.adresse)}">${iconeEc('retour', 22)}<span>${e(lieu.rubrique.libelle)}</span></a>`);
  }
  const bouton = $('[data-discret]');
  const majDiscret = () => { bouton.setAttribute('aria-pressed', String(discret())); (bouton.querySelector('.app-entete__libelle') || bouton).textContent = discret() ? 'Afficher les montants' : 'Masquer les montants'; };
  bouton.addEventListener('click', () => { try { localStorage.setItem(DISCRET, discret() ? '0' : '1'); } catch { /* stockage indisponible */ } majDiscret(); document.dispatchEvent(new CustomEvent('gmb:discret')); });
  majDiscret();
  $('[data-deconnexion]').addEventListener('click', () => deconnecter());
  surveillerRaccourcis();
  mentionLegale();
}

/** Ouvre une page de l'Espace client : session vérifiée, contexte, cadre, inactivité. */
export async function ouvrirEspace(rubrique) {
  const marque = document.querySelector('.app-entete__marque'); if (marque && !marque.querySelector('svg')) marque.innerHTML = logoSVG({ titre: 'GerMoonBank, accueil de l’Espace client' });

  const s = await session();
  if (!s || espaceDe(s) !== 'client') { location.replace(chemin('auth/connexion.html?raison=session')); throw new ErreurGmb('Session absente'); }
  const ctx = await contexte();
  const [personne, moi] = await Promise.all([
    ctx.client?.personne_id ? lire('personnes', { colonnes: 'prenoms, nom_naissance, nom_usage', egal: { id: ctx.client.personne_id }, unique: true }) : null,
    lire('clients', { colonnes: 'id, formule_code, segment, theme', egal: { id: ctx.client.id }, unique: true }).catch(() => null),
  ]);
  const nomFamille = (personne?.nom_usage || '').trim() || personne?.nom_naissance || '';
  ctx.prenom = personne?.prenoms?.split(' ')[0] || '';
  ctx.nom = `${personne?.prenoms || ''} ${nomFamille.toUpperCase()}`.trim();
  ctx.initiales = `${(personne?.prenoms || '').trim().charAt(0)}${nomFamille.trim().charAt(0)}`.toUpperCase();
  ctx.formule = moi?.formule_code || '';
  ctx.segment = moi?.segment || '';
  // Apparence choisie sur un autre appareil : reprise ici si celui-ci n'en a pas encore
  // (« clair » est la valeur par défaut de la base : elle ne vaut pas choix, l'Espace client reste alors en « Nuit »)
  if (lireApparence() === null && ['sombre', 'systeme'].includes(moi?.theme)) { try { localStorage.setItem(CLE_THEME, moi.theme === 'systeme' ? '' : moi.theme); } catch { /* facultatif */ } appliquerApparence(); }
  cadre(rubrique, ctx);
  surveillerInactivite();
  return ctx;
}

/** Démarre le contrôleur de la page, d'après data-app. */
export function demarrerPage(controleurs) {
  document.addEventListener('submit', (x) => x.preventDefault());
  const lancer = async () => {
    const c = controleurs[document.body.dataset.app];
    if (!c) return;
    try { await c(); } catch (x) { if (!/Session absente/.test(x?.message)) message(messageErreur(x)); }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', lancer, { once: true }); else lancer();
}
