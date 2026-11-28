/* =============================================================================
   GerMoonBank (GMB) · js/langue.js
   Version anglaise du site : un clic sur « English » traduit toutes les pages,
   et le choix est gardé d'une page à l'autre (localStorage « gmb-langue »).
   -----------------------------------------------------------------------------
   - Les textes français restent dans les pages ; les traductions sont rangées par
     rubrique dans i18n/en/*.json (« textes » : français → anglais, « motifs » :
     expressions régulières pour les textes qui contiennent un nombre ou un nom).
   - Chaque page charge le dictionnaire commun (menus, pied de page, boutons) et
     celui de sa rubrique. Tout texte ajouté ensuite par les scripts (données de
     l'Espace client, messages, fenêtres) est traduit dès son apparition.
   - Dans un motif, chaque valeur reprise ($1, $2…) est elle-même traduite si elle
     est connue (un statut, une formule, « une carte virtuelle »…) ; « $^1 » la
     reprend avec une majuscule.
   - Un texte sans traduction reste en français ; la liste des textes manquants
     est disponible dans la console : gmbTextesManquants().
   - Le script placé en tête de chaque page applique la langue avant l'affichage
     (classe « gmb-en ») : l'écran de chargement couvre la page jusqu'à la fin de
     la traduction, sans éclair de français.
   ========================================================================== */

import { LANGUE, RACINE } from './core.js';

const CLE = 'gmb-langue';
const ATTRIBUTS = ['aria-label', 'title', 'placeholder', 'alt', 'aria-description', 'data-libelle'];
const IGNORES = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'svg', 'SVG', 'TEMPLATE']);
const LETTRE = /[A-Za-zÀ-ÿ]/;
const ESPACES = /[\s  ]+/g;
const PROFONDEUR_MAX = 3;

let promesse = null;
const textes = new Map();
const motifs = [];
const produits = new Set();
const manquants = new Set();

/** Change la langue du site et recharge la page. */
export function choisirLangue(code) {
  try {
    if (code === 'en') localStorage.setItem(CLE, 'en');
    else localStorage.removeItem(CLE);
  } catch { /* stockage indisponible : la langue ne peut pas être gardée */ }
  location.reload();
}

export const enAnglais = () => LANGUE === 'en';

/** Espaces (y compris insécables) réduits à un seul ; apostrophes unifiées. */
function normaliser(t) {
  return String(t).replace(ESPACES, ' ').replace(/[’‘]/g, '\'').trim();
}

/** Dictionnaires utiles à la page : le commun, puis celui de sa rubrique. */
function dictionnaires() {
  const chemin = decodeURIComponent(location.pathname).slice(new URL(RACINE).pathname.length);
  const morceaux = chemin.split('/').filter(Boolean);
  const noms = ['commun'];
  if (!morceaux.length || morceaux[0] === 'index.html') noms.push('accueil');
  else if (morceaux[0] === 'public' && morceaux.length > 2) noms.push(`public-${morceaux[1]}`);
  else if (['app', 'bo', 'auth', 'supabase'].includes(morceaux[0])) noms.push(morceaux[0]);
  if (morceaux[0] === 'app' && morceaux[1] === 'mon-dossier') noms.push('mon-dossier');
  return noms;
}

/** Poids d'un motif : la longueur de sa partie fixe. Les motifs les plus précis passent en premier. */
const poids = (expression) => expression.replace(/\(\?:\(\.\*\?\) \)\?|\(\?: \(\.\*\?\)\)\?|\(\.\*\?\)/g, '').replace(/\\/g, '').length;

async function charger() {
  const fichiers = await Promise.all(dictionnaires().map((nom) => fetch(new URL(`i18n/en/${nom}.json`, RACINE))
    .then((r) => (r.ok ? r.json() : {}))
    .catch(() => ({}))));
  for (const f of fichiers) {
    for (const [fr, en] of Object.entries(f.textes || {})) textes.set(normaliser(fr), en);
    for (const [expression, remplacement] of f.motifs || []) {
      try { motifs.push([new RegExp(`^${expression}$`), remplacement, poids(expression)]); } catch { /* motif invalide : ignoré */ }
    }
  }
  motifs.sort((a, b) => b[2] - a[2]);
}

/** Traduction d'un texte déjà normalisé, ou undefined. */
function chercher(n, profondeur) {
  const en = textes.get(n);
  if (en !== undefined || profondeur > PROFONDEUR_MAX) return en;
  for (const [expression, remplacement] of motifs) {
    const r = expression.exec(n);
    if (!r) continue;
    return remplacement.replace(/\$(\^?)(\d)/g, (_, majuscule, k) => {
      const valeur = fragment(r[Number(k)] ?? '', profondeur + 1);
      return majuscule ? valeur.charAt(0).toUpperCase() + valeur.slice(1) : valeur;
    });
  }
  return undefined;
}

/** Valeur reprise dans un motif : traduite si elle est connue (y compris « a et b », « a, b »), sinon telle quelle. */
function fragment(valeur, profondeur) {
  if (!valeur) return valeur;
  // Montant ou taux repris dans une phrase venue de la base (« 1 234,56 € ») : écrit à l'anglaise
  if (!LETTRE.test(valeur)) return nombre(normaliser(valeur)) ?? valeur;
  const n = normaliser(valeur);
  let en = chercher(n, profondeur);
  if (en === undefined) {
    for (const [separateur, anglais] of [[' et ', ' and '], [', ', ', ']]) {
      if (!n.includes(separateur)) continue;
      const morceaux = n.split(separateur).map((m) => chercher(m, profondeur));
      if (morceaux.every((m) => m !== undefined)) { en = morceaux.join(anglais); break; }
    }
  }
  if (en === undefined) return valeur;
  return valeur.match(/^[\s  ]*/)[0] + en + valeur.match(/[\s  ]*$/)[0];
}

/** Montant ou pourcentage écrit à la française (« 1 234,50 € », « -4,20 € », « 2,50 % ») -> écriture anglaise, sinon null. */
function nombre(n) {
  const montant = /^([+\-−]?) ?(\d{1,3}(?: \d{3})*|\d+)(?:,(\d+))? ?€$/.exec(n);
  if (montant) return `${montant[1]}€${montant[2].replace(/ /g, ',')}${montant[3] ? `.${montant[3]}` : ''}`;
  const taux = /^([+\-−]?)(\d+)(?:,(\d+))? ?%$/.exec(n);
  if (taux) return `${taux[1]}${taux[2]}${taux[3] ? `.${taux[3]}` : ''}%`;
  return null;
}

/** Traduction d'un texte, ou null s'il n'en a pas (il reste alors en français). */
export function traduire(brut) {
  const n = normaliser(brut);
  if (!n || produits.has(n)) return null;
  if (!LETTRE.test(n)) {
    const chiffres = nombre(n);
    if (chiffres === null || chiffres === n) return null;
    produits.add(chiffres);
    return String(brut).match(/^[\s  ]*/)[0] + chiffres + String(brut).match(/[\s  ]*$/)[0];
  }
  let en = chercher(n, 0);
  if (en === undefined) { manquants.add(n); return null; }
  const debut = String(brut).match(/^[\s  ]*/)[0];
  const fin = String(brut).match(/[\s  ]*$/)[0];
  // « d’ », « l’ » suivis d'un élément (un nom, un lien) : l'anglais a besoin d'une espace
  if (!fin && n.endsWith('\'') && !/[\s']$/.test(en)) en += ' ';
  produits.add(normaliser(en));
  return debut + en + fin;
}

function traduireTexte(noeud) {
  const parent = noeud.parentElement;
  if (!parent || IGNORES.has(parent.tagName) || parent.closest('[translate="no"]')) return;
  const en = traduire(noeud.nodeValue);
  if (en !== null && en !== noeud.nodeValue) noeud.nodeValue = en;
}

function traduireAttribut(element, nom) {
  const valeur = element.getAttribute(nom);
  if (!valeur || element.closest('[translate="no"]')) return;
  const en = traduire(valeur);
  if (en !== null && en !== valeur) element.setAttribute(nom, en);
}

const estBouton = (element) => element.tagName === 'INPUT' && ['submit', 'button', 'reset'].includes(element.type);

function traduireElement(element) {
  ATTRIBUTS.forEach((nom) => { if (element.hasAttribute(nom)) traduireAttribut(element, nom); });
  if (estBouton(element)) traduireAttribut(element, 'value');
}

function traduireArbre(racine) {
  if (racine.nodeType === Node.TEXT_NODE) { traduireTexte(racine); return; }
  if (racine.nodeType !== Node.ELEMENT_NODE || IGNORES.has(racine.tagName) || racine.closest('[translate="no"]')) return;
  traduireElement(racine);
  const marcheur = document.createTreeWalker(racine, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
      if (n.nodeType === Node.ELEMENT_NODE) {
        if (IGNORES.has(n.tagName) || n.getAttribute('translate') === 'no') return NodeFilter.FILTER_REJECT;
        traduireElement(n);
        return NodeFilter.FILTER_SKIP;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  const noeuds = [];
  while (marcheur.nextNode()) noeuds.push(marcheur.currentNode);
  noeuds.forEach(traduireTexte);
}

function traduireTitre() {
  const en = traduire(document.title);
  if (en !== null && en !== document.title) document.title = en;
}

/** Traduit la page puis tout ce qui s'y ajoute. Sans effet en français. */
export function traduirePage() {
  if (!enAnglais()) return Promise.resolve();
  if (promesse) return promesse;
  promesse = (async () => {
    document.documentElement.lang = 'en';
    await charger();
    traduireTitre();
    traduireArbre(document.body);
    new MutationObserver((changements) => {
      for (const c of changements) {
        if (c.type === 'childList') c.addedNodes.forEach(traduireArbre);
        else if (c.type === 'characterData') traduireTexte(c.target);
        else if (c.type === 'attributes' && (c.attributeName !== 'value' || estBouton(c.target))) traduireAttribut(c.target, c.attributeName);
      }
    }).observe(document.body, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: [...ATTRIBUTS, 'value'] });
    const titre = document.querySelector('title');
    if (titre) new MutationObserver(traduireTitre).observe(titre, { childList: true, characterData: true, subtree: true });
    document.documentElement.classList.add('gmb-traduit');
    globalThis.gmbTextesManquants = () => [...manquants];
  })();
  return promesse;
}
