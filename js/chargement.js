/* =============================================================================
   GerMoonBank (GMB) · js/chargement.js
   Écran de chargement : le logo s'affiche et sa lune se remplit tant que la page
   n'est pas prête (styles : css/base.css, « Écran de chargement » ; logos animés :
   assets/logo/gmb-chargement-logo.svg et gmb-chargement-logo-sombre.svg).
   -----------------------------------------------------------------------------
   - Une page prête en moins de 200 ms s'affiche directement : l'écran n'apparaît
     jamais (il ne devient visible qu'après ce délai, voir css/base.css).
   - Sinon, l'écran termine son apparition avant de s'effacer en fondu.
   - À la première page d'une visite, il reste le temps de voir la lune se remplir.
   - Sans JavaScript, la feuille de style le retire d'elle-même après 8 secondes.
   ========================================================================== */

const APPARITION_MS = 200; // l'écran devient visible après ce délai (animation-delay de css/base.css)
const ENTREE_MS = 250; // durée de son apparition en fondu
const PREMIERE_VISITE_MS = 1100; // première page d'une visite : le temps d'un remplissage de la lune
const FONDU_MS = 320; // durée du fondu de sortie
const CLE_VISITE = 'gmb-chargement-vu';

let signale = false;

/** Première page de la visite (onglet) ? Le stockage peut être indisponible : on répond alors non. */
function premierePage() {
  try {
    if (sessionStorage.getItem(CLE_VISITE)) return false;
    sessionStorage.setItem(CLE_VISITE, '1');
    return true;
  } catch {
    return false;
  }
}

/** À appeler quand la page est prête : retire l'écran de chargement. */
export function pagePrete() {
  if (signale) return;
  signale = true;
  const racine = document.documentElement;
  const ecoule = performance.now();
  const premiere = premierePage();
  if (ecoule < APPARITION_MS) {
    racine.classList.add('gmb-pret');
    return;
  }
  const fin = Math.max(APPARITION_MS + ENTREE_MS, premiere ? APPARITION_MS + PREMIERE_VISITE_MS : 0);
  setTimeout(() => {
    racine.classList.add('gmb-sortie');
    setTimeout(() => racine.classList.add('gmb-pret'), FONDU_MS);
  }, Math.max(0, fin - ecoule));
}

/** Page prête au plus tard après « delai » millisecondes, quoi qu'il arrive. */
export function pagePreteAuPlusTard(delai) {
  setTimeout(pagePrete, delai);
}
