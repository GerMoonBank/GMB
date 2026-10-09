/* =============================================================================
   GerMoonBank (GMB) · js/core.js
   Noyau JavaScript partagé — version 2.1
   -----------------------------------------------------------------------------
   Rôle        : configuration, mise en forme des montants, taux et dates,
                 contrôles (identifiant, IBAN), calculs (crédit, Livret),
                 thème clair et sombre, stockage local avec expiration,
                 consentement aux cookies, accessibilité (annonces vocales,
                 piège à focus), notifications, icônes, logo, lune et client
                 Supabase chargé à la demande.
   Chargement  : module ES, sans npm ni outil de construction :
                   import { formaterMontant } from './js/core.js';
                 (adapter le chemin relatif selon la page).
   Sécurité    : seule la clé publiable de Supabase figure ici ; elle est
                 conçue pour être publique et protégée par les règles RLS.
                 La clé secrète (service_role) ne doit JAMAIS être placée dans
                 ce dépôt public.
   Compatible  : navigateurs récents (2022 et après) et Node.js 18+ pour les
                 fonctions sans interface (tests).
   ========================================================================== */

export const VERSION = '2.1.0';

/** Racine du site, déduite de l'emplacement de ce fichier (js/ est à la racine).
 *  Fonctionne sur GitHub Pages (…/GMB/), en local et dans tous les sous-dossiers. */
export const RACINE = new URL('../', import.meta.url);

export const CONFIG = Object.freeze({
  nom: 'GerMoonBank',
  locale: 'fr-FR',
  devise: 'EUR',
  fuseau: 'Europe/Paris',
  supabase: Object.freeze({
    url: 'https://ufrzpdnsfuuchyywkeqt.supabase.co',
    cle: 'sb_publishable_qWT5YOj7PMe4W7MuG934Dg_f4ops3r5',
    module: 'https://esm.sh/@supabase/supabase-js@2',
  }),
  /** Durées de conservation, en jours */
  durees: Object.freeze({ banniereApp: 30, bandeau: 30, consentement: 180 }),
  /** Les codes de sécurité sont envoyés par e-mail par Supabase (modèles avec
   *  {{ .Token }}). Pendant le développement, la base n'a pas de RLS : chaque accès
   *  aux données passe par js/donnees.js, qui filtre sur la personne connectée. */
});

const NBSP = '\u00A0';
const MOINS = '\u2212';
const ESTNAVIGATEUR = typeof window !== 'undefined' && typeof document !== 'undefined';


/* =============================================================================
   1. CHEMINS ET LIENS
   ========================================================================== */

/** Adresse absolue d'une page du site à partir de la racine.
 *  chemin('public/epargne/index.html') → https://…/GMB/public/epargne/index.html */
export function chemin(relatif = '') {
  return new URL(String(relatif).replace(/^\/+/, ''), RACINE).href;
}

/** Lien vers le tunnel d'ouverture. Ne transmet que le segment et la formule,
 *  jamais de donnée personnelle (règle VIT-00). */
export function lienOuverture({ segment = 'particuliers', formule = '' } = {}) {
  const url = new URL(chemin('public/inscription/index.html'));
  if (segment) url.searchParams.set('segment', segment);
  if (formule) url.searchParams.set('formule', formule);
  return url.href;
}


/* =============================================================================
   2. MISE EN FORME : MONTANTS, TAUX, DATES, IBAN
   Espace insécable avant €, chiffres tabulaires (CSS), signe moins
   typographique (−).
   ========================================================================== */
const cacheFormats = new Map();

function formatNombre(options) {
  const cle = JSON.stringify(options);
  if (!cacheFormats.has(cle)) cacheFormats.set(cle, new Intl.NumberFormat(CONFIG.locale, options));
  return cacheFormats.get(cle);
}

/** Arrondi bancaire simple au centime (ou à d décimales). */
export function arrondir(valeur, decimales = 2) {
  const f = 10 ** decimales;
  return Math.round((Number(valeur) + Number.EPSILON) * f) / f;
}

/** 12480.36 → « 12 480,36 € » ; -4.2 → « −4,20 € » ; signe: true → « +2 850,00 € » */
export function formaterMontant(valeur, { devise = CONFIG.devise, decimales = 2, signe = false } = {}) {
  const n = Number(valeur);
  if (!Number.isFinite(n)) return '—';
  const arrondi = arrondir(n, decimales);
  const texte = formatNombre({
    style: 'currency',
    currency: devise,
    minimumFractionDigits: decimales,
    maximumFractionDigits: decimales,
  }).format(Math.abs(arrondi));
  if (arrondi < 0) return MOINS + texte;
  if (signe && arrondi > 0) return '+' + texte;
  return texte;
}

/** 10000 → « 10 000 » */
export function formaterNombre(valeur, decimales = 0) {
  const n = Number(valeur);
  if (!Number.isFinite(n)) return '—';
  const texte = formatNombre({ minimumFractionDigits: decimales, maximumFractionDigits: decimales }).format(Math.abs(n));
  return (arrondir(n, decimales) < 0 ? MOINS : '') + texte;
}

/** 5.25 → « 5,25 % » */
export function formaterTaux(pourcentage, decimales = 2) {
  const n = Number(pourcentage);
  if (!Number.isFinite(n)) return '—';
  return formatNombre({ style: 'percent', minimumFractionDigits: decimales, maximumFractionDigits: decimales }).format(n / 100);
}

function enDate(valeur) {
  const d = valeur instanceof Date ? valeur : new Date(valeur);
  return Number.isNaN(d.getTime()) ? null : d;
}

const STYLES_DATE = {
  court: { day: '2-digit', month: '2-digit', year: 'numeric' },
  long: { day: 'numeric', month: 'long', year: 'numeric' },
  complet: { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' },
  jour: { weekday: 'long', day: 'numeric', month: 'long' },
  heure: { hour: '2-digit', minute: '2-digit' },
  dateHeure: { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' },
};

/** Date au fuseau de Paris. Styles : court, long, complet, jour, heure, dateHeure. */
export function formaterDate(valeur, style = 'long') {
  const d = enDate(valeur);
  if (!d) return '—';
  const options = STYLES_DATE[style] || STYLES_DATE.long;
  return new Intl.DateTimeFormat(CONFIG.locale, { ...options, timeZone: CONFIG.fuseau }).format(d);
}

function jourCivil(d) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: CONFIG.fuseau, year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

/** « Aujourd'hui », « Hier », « Demain », sinon « lundi 28 septembre » (avec l'année si elle diffère). */
export function formaterDateRelative(valeur, maintenant = new Date()) {
  const d = enDate(valeur);
  if (!d) return '—';
  const [a1, m1, j1] = jourCivil(d).split('-').map(Number);
  const [a2, m2, j2] = jourCivil(maintenant).split('-').map(Number);
  const ecart = Math.round((Date.UTC(a1, m1 - 1, j1) - Date.UTC(a2, m2 - 1, j2)) / 864e5);
  if (ecart === 0) return 'Aujourd\u2019hui';
  if (ecart === -1) return 'Hier';
  if (ecart === 1) return 'Demain';
  const texte = formaterDate(d, a1 === a2 ? 'jour' : 'complet');
  return texte.charAt(0).toUpperCase() + texte.slice(1);
}

export function normaliserIban(valeur) {
  return String(valeur ?? '').replace(/[\s-]/g, '').toUpperCase();
}

/** Groupé par 4 : « FR76 3000 6000 0112 3456 7890 189 » */
export function formaterIban(valeur) {
  return normaliserIban(valeur).replace(/(.{4})(?=.)/g, '$1 ');
}

/** « •••• 2741 » */
export function masquerCarte(quatreDerniers) {
  return '\u2022\u2022\u2022\u2022' + NBSP + String(quatreDerniers ?? '').slice(-4);
}


/* =============================================================================
   3. CONTRÔLES DE SAISIE
   ========================================================================== */

/** Clé de Luhn (identifiant bancaire de 8 chiffres, numéros de carte). */
export function luhnValide(valeur) {
  const chiffres = String(valeur ?? '').replace(/\D/g, '');
  if (chiffres.length < 2) return false;
  let somme = 0;
  for (let i = 0; i < chiffres.length; i += 1) {
    let c = Number(chiffres[chiffres.length - 1 - i]);
    if (i % 2 === 1) {
      c *= 2;
      if (c > 9) c -= 9;
    }
    somme += c;
  }
  return somme % 10 === 0;
}

/** Identifiant de l'Espace client : 8 chiffres avec clé de Luhn. */
export function identifiantValide(valeur) {
  const v = String(valeur ?? '');
  return /^\d{8}$/.test(v) && luhnValide(v);
}

const LONGUEURS_IBAN = { FR: 27, MC: 27, DE: 22, BE: 16, ES: 24, IT: 27, NL: 18, LU: 20, PT: 25, AT: 20, IE: 22, CH: 21, GB: 22 };

/** Contrôle d'IBAN : format, longueur du pays et clé modulo 97. */
export function ibanValide(valeur) {
  const iban = normaliserIban(valeur);
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(iban)) return false;
  const pays = iban.slice(0, 2);
  if (LONGUEURS_IBAN[pays] && iban.length !== LONGUEURS_IBAN[pays]) return false;
  let reste = 0;
  for (const car of iban.slice(4) + iban.slice(0, 4)) {
    const bloc = /\d/.test(car) ? car : String(car.charCodeAt(0) - 55);
    for (const c of bloc) reste = (reste * 10 + Number(c)) % 97;
  }
  return reste === 1;
}

export function emailValide(valeur) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(String(valeur ?? '').trim());
}


/* =============================================================================
   4. CALCULS FINANCIERS (simulateurs de la vitrine)
   ========================================================================== */

/** Mensualité d'un prêt amortissable à taux fixe.
 *  mensualiteCredit(10000, 5.75, 48) → 233.71 */
export function mensualiteCredit(capital, tauxAnnuelPourcentage, mois) {
  const c = Number(capital);
  const n = Number(mois);
  const t = Number(tauxAnnuelPourcentage) / 100 / 12;
  if (!(c > 0) || !(n > 0)) return 0;
  if (t === 0) return arrondir(c / n);
  return arrondir((c * t) / (1 - (1 + t) ** -n));
}

/** Récapitulatif d'un exemple représentatif de crédit. */
export function coutCredit(capital, tauxAnnuelPourcentage, mois) {
  const mensualite = mensualiteCredit(capital, tauxAnnuelPourcentage, mois);
  const montantDu = arrondir(mensualite * mois);
  return {
    mensualite,
    montantDu,
    cout: arrondir(montantDu - capital),
    taeg: arrondir(((1 + tauxAnnuelPourcentage / 1200) ** 12 - 1) * 100),
  };
}

/** Intérêts du Livret calculés jour par jour, base 365 jours, bruts.
 *  interetsLivret(10000, 5.25) → { parJour: 1.44, parAn: 525 } */
export function interetsLivret(montant, tauxPourcentage, jours = 365) {
  const parAnExact = (Number(montant) * Number(tauxPourcentage)) / 100;
  const parJourExact = parAnExact / 365;
  return {
    parJour: arrondir(parJourExact),
    parAn: arrondir(parAnExact),
    surPeriode: arrondir(parJourExact * jours),
  };
}


/* =============================================================================
   5. STOCKAGE LOCAL AVEC EXPIRATION
   Ne stocke jamais de donnée personnelle ni de secret.
   ========================================================================== */
export const stockage = {
  lire(cle) {
    try {
      const brut = globalThis.localStorage?.getItem(cle);
      if (brut == null) return null;
      const objet = JSON.parse(brut);
      if (objet && typeof objet === 'object' && 'v' in objet) {
        if (objet.e && Date.now() > objet.e) {
          globalThis.localStorage.removeItem(cle);
          return null;
        }
        return objet.v;
      }
      return objet;
    } catch {
      return null;
    }
  },

  ecrire(cle, valeur, dureeJours = 0) {
    try {
      globalThis.localStorage?.setItem(cle, JSON.stringify({ v: valeur, e: dureeJours ? Date.now() + dureeJours * 864e5 : 0 }));
      return true;
    } catch {
      return false;
    }
  },

  supprimer(cle) {
    try {
      globalThis.localStorage?.removeItem(cle);
    } catch {
      /* stockage indisponible : rien à faire */
    }
  },
};


/* =============================================================================
   6. THÈME CLAIR ET SOMBRE
   Clair par défaut partout ; le sombre premium est proposé dans l'Espace
   client (PAR-16) : préférence « clair », « sombre » ou « systeme ».
   ========================================================================== */
const CLE_THEME = 'gmb-theme';
export const THEMES = Object.freeze(['clair', 'sombre', 'systeme']);

export function lireThemePrefere() {
  const valeur = stockage.lire(CLE_THEME);
  return THEMES.includes(valeur) ? valeur : 'clair';
}

export function themeEffectif(preference) {
  if (preference === 'systeme') {
    return ESTNAVIGATEUR && matchMedia('(prefers-color-scheme: dark)').matches ? 'sombre' : 'clair';
  }
  return preference === 'sombre' ? 'sombre' : 'clair';
}

function majCouleurNavigateur(theme) {
  const meta = document.querySelector('meta[name="theme-color"]:not([media])');
  if (!meta) return;
  const valeur = getComputedStyle(document.documentElement).getPropertyValue(`--gmb-theme-color-${theme}`).trim();
  if (valeur) meta.setAttribute('content', valeur);
}

export function appliquerTheme(preference, { memoriser = true } = {}) {
  const theme = themeEffectif(preference);
  document.documentElement.dataset.theme = theme;
  majCouleurNavigateur(theme);
  if (memoriser) stockage.ecrire(CLE_THEME, preference);
  document.dispatchEvent(new CustomEvent('gmb:theme', { detail: { preference, theme } }));
  return theme;
}

/** À appeler une fois par page. Vitrine : initialiserTheme() (toujours clair).
 *  Espace client : initialiserTheme({ autoriserSombre: true }). */
export function initialiserTheme({ autoriserSombre = false } = {}) {
  if (!autoriserSombre) {
    document.documentElement.dataset.theme = 'clair';
    return 'clair';
  }
  const preference = lireThemePrefere();
  if (preference === 'systeme') {
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      if (lireThemePrefere() === 'systeme') appliquerTheme('systeme', { memoriser: false });
    });
  }
  return appliquerTheme(preference, { memoriser: false });
}


/* =============================================================================
   7. CONSENTEMENT AUX COOKIES (VIT-00)
   Choix conservé 6 mois ; aucun traceur non exempté avant le choix.
   ========================================================================== */
const CLE_CONSENTEMENT = 'gmb-consentement';

export const consentement = {
  lire() {
    return stockage.lire(CLE_CONSENTEMENT);
  },

  aDecide() {
    return this.lire() !== null;
  },

  /** finalite : « mesure » (audience) ou « tiers » (contenus externes) */
  autorise(finalite) {
    return Boolean(this.lire()?.[finalite]);
  },

  enregistrer({ mesure = false, tiers = false } = {}) {
    const valeur = { mesure: Boolean(mesure), tiers: Boolean(tiers), date: new Date().toISOString(), version: 1 };
    stockage.ecrire(CLE_CONSENTEMENT, valeur, CONFIG.durees.consentement);
    if (ESTNAVIGATEUR) document.dispatchEvent(new CustomEvent('gmb:consentement', { detail: valeur }));
    return valeur;
  },

  /** Rouvre la fenêtre de réglage (lien « Gérer les cookies »). */
  ouvrirReglages() {
    document.dispatchEvent(new CustomEvent('gmb:cookies-reglages'));
  },
};


/* =============================================================================
   8. ACCESSIBILITÉ
   ========================================================================== */
let regionAnnonce = null;

/** Annonce un message aux lecteurs d'écran (« 3 chiffres saisis sur 8 »). */
export function annoncer(message, politesse = 'polite') {
  if (!ESTNAVIGATEUR) return;
  if (!regionAnnonce) {
    regionAnnonce = document.createElement('div');
    regionAnnonce.className = 'gmb-visuellement-masque';
    regionAnnonce.setAttribute('aria-atomic', 'true');
    document.body.append(regionAnnonce);
  }
  regionAnnonce.setAttribute('aria-live', politesse);
  regionAnnonce.textContent = '';
  setTimeout(() => {
    regionAnnonce.textContent = message;
  }, 60);
}

export function mouvementReduit() {
  return ESTNAVIGATEUR && matchMedia('(prefers-reduced-motion: reduce)').matches;
}

/** Bloque le défilement de la page (menu ouvert, fenêtre de validation). */
export function bloquerDefilement(actif) {
  const html = document.documentElement;
  if (actif) html.dataset.menuOuvert = 'true';
  else delete html.dataset.menuOuvert;
}

const SELECTEUR_FOCUSABLE = [
  'a[href]', 'area[href]', 'button:not([disabled])', 'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])', 'textarea:not([disabled])', 'summary', '[tabindex]:not([tabindex="-1"])',
].join(',');

export function elementsFocusables(racine) {
  return [...racine.querySelectorAll(SELECTEUR_FOCUSABLE)]
    .filter((el) => !el.closest('[hidden],[inert]') && el.getClientRects().length > 0);
}

/** Garde le focus clavier dans un conteneur. Renvoie la fonction qui libère. */
export function pieger(conteneur) {
  function surTouche(evenement) {
    if (evenement.key !== 'Tab') return;
    const elements = elementsFocusables(conteneur);
    if (!elements.length) return;
    const premier = elements[0];
    const dernier = elements[elements.length - 1];
    if (evenement.shiftKey && document.activeElement === premier) {
      evenement.preventDefault();
      dernier.focus();
    } else if (!evenement.shiftKey && document.activeElement === dernier) {
      evenement.preventDefault();
      premier.focus();
    }
  }
  conteneur.addEventListener('keydown', surTouche);
  return () => conteneur.removeEventListener('keydown', surTouche);
}


/* =============================================================================
   9. OUTILS
   ========================================================================== */
export const $ = (selecteur, racine = document) => racine.querySelector(selecteur);
export const $$ = (selecteur, racine = document) => [...racine.querySelectorAll(selecteur)];

let compteurId = 0;

/** Identifiant unique, utile pour les SVG insérés plusieurs fois (dégradés). */
export function idUnique(prefixe = 'gmb') {
  compteurId += 1;
  return `${prefixe}-${compteurId.toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

export function echapperHtml(texte) {
  return String(texte ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

export function antiRebond(fonction, delai = 200) {
  let minuteur;
  return (...args) => {
    clearTimeout(minuteur);
    minuteur = setTimeout(() => fonction(...args), delai);
  };
}

/** Limite une fonction à un appel par image affichée (défilement, redimensionnement). */
export function parImage(fonction) {
  let enAttente = false;
  let derniersArgs;
  return (...args) => {
    derniersArgs = args;
    if (enAttente) return;
    enAttente = true;
    requestAnimationFrame(() => {
      enAttente = false;
      fonction(...derniersArgs);
    });
  };
}

export function quandPret(fonction) {
  if (document.readyState !== 'loading') fonction();
  else document.addEventListener('DOMContentLoaded', fonction, { once: true });
}


/* =============================================================================
   10. ICÔNES (dessinées pour GerMoonBank, trait de 2 px, grille de 24 px)
   ========================================================================== */
const TRACES = {
  accessibilite: '<circle cx="12" cy="4.5" r="1.6"/><path d="M5 8.6c2.3.7 4.6 1 7 1s4.7-.3 7-1M12 9.6v4.6m0 0-3.2 6.3M12 14.2l3.2 6.3"/>',
  aide: '<circle cx="12" cy="12" r="9"/><path d="M9.6 9.4a2.5 2.5 0 1 1 3.4 2.4c-.6.3-1 .9-1 1.6v.5M12 17h.01"/>',
  alerte: '<path d="M10.3 4.3 2.7 17.6a2 2 0 0 0 1.7 3h15.2a2 2 0 0 0 1.7-3L13.7 4.3a2 2 0 0 0-3.4 0z"/><path d="M12 9.6v4M12 17h.01"/>',
  banque: '<path d="M3 9.5 12 4l9 5.5M5 10v8m4.7-8v8m4.6-8v8M19 10v8M3 20.5h18"/>',
  bouclier: '<path d="M12 3 4.5 6v5.6c0 4.6 3.1 8.2 7.5 9.4 4.4-1.2 7.5-4.8 7.5-9.4V6z"/><path d="m9 12 2.2 2.2L15.2 10"/>',
  cadenas: '<rect x="5" y="11" width="14" height="10" rx="2.2"/><path d="M8 11V7.5a4 4 0 0 1 8 0V11"/>',
  carte: '<rect x="3" y="5.5" width="18" height="13" rx="2.5"/><path d="M3 10h18M7 15h4"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  chevronBas: '<path d="m6 9 6 6 6-6"/>',
  chevronDroite: '<path d="m9 6 6 6-6 6"/>',
  clavier: '<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><path d="M7.5 9h.01M12 9h.01M16.5 9h.01M7.5 12.5h.01M12 12.5h.01M16.5 12.5h.01M9 16h6"/>',
  cloche: '<path d="M6 9.5a6 6 0 0 1 12 0c0 4.5 1.8 6 1.8 6H4.2S6 14 6 9.5"/><path d="M10 19a2 2 0 0 0 4 0"/>',
  coffre: '<rect x="3.5" y="5" width="17" height="14" rx="2.5"/><circle cx="12" cy="12" r="3"/><path d="M12 9v.01M6.5 19v1.5m11-1.5v1.5"/>',
  croissance: '<path d="m3 16.5 6-6 4 4 8-8"/><path d="M15 6.5h6v6"/>',
  croix: '<path d="M6 6l12 12M18 6 6 18"/>',
  dossier: '<path d="M3 7.5a2 2 0 0 1 2-2h4.2l2 2.2H19a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  eclair: '<path d="M13.5 3 5 13.5h6.2L10.5 21 19 10.5h-6.2z"/>',
  effacer: '<path d="M9 5.5h10.5a1.5 1.5 0 0 1 1.5 1.5v10a1.5 1.5 0 0 1-1.5 1.5H9L3 12z"/><path d="m11.5 9.5 5 5m0-5-5 5"/>',
  entreprise: '<path d="M4 21V5a2 2 0 0 1 2-2h8a2 2 0 0 1 2 2v16m0-12h2.5a1.5 1.5 0 0 1 1.5 1.5V21M2.5 21h19M8 7.5h4m-4 4h4m-4 4h4"/>',
  epargne: '<path d="M4.5 12a7.5 6.5 0 0 1 13.8-3.5l2.2-.5-.3 3a6 6 0 0 1-1.2 4.5V19h-3v-1.6a8.9 8.9 0 0 1-4 0V19h-3v-2.2A6.2 6.2 0 0 1 4.5 12z"/><path d="M15.5 10.5h.01M9.5 7.5h4"/>',
  feuille: '<path d="M5 19.5C5 11 10 5.5 20 4.5c-.6 10-6 15-14.5 15"/><path d="m5 19.5 8.5-8.5"/>',
  flecheDroite: '<path d="M5 12h14m-6-6 6 6-6 6"/>',
  flocon: '<path d="M12 2.5v19M3.8 7.2l16.4 9.6M3.8 16.8l16.4-9.6"/><path d="m9.2 4.3 2.8 2 2.8-2m-5.6 15.4 2.8-2 2.8 2"/>',
  globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z"/>',
  graphique: '<path d="M4 4v15.5a.5.5 0 0 0 .5.5H20"/><path d="m7.5 15 3.5-4 3 2.5 4.5-6"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5.5M12 7.8h.01"/>',
  maison: '<path d="M4 10.5 12 4l8 6.5V19a1.5 1.5 0 0 1-1.5 1.5h-4v-6h-5v6h-4A1.5 1.5 0 0 1 4 19z"/>',
  mallette: '<rect x="3" y="7" width="18" height="13" rx="2.5"/><path d="M8.5 7V5.5A1.5 1.5 0 0 1 10 4h4a1.5 1.5 0 0 1 1.5 1.5V7M3 12.5h18"/>',
  menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  recherche: '<circle cx="11" cy="11" r="6.5"/><path d="m16 16 4.5 4.5"/>',
  serveur: '<rect x="4" y="4" width="16" height="7" rx="2"/><rect x="4" y="13" width="16" height="7" rx="2"/><path d="M8 7.5h.01M8 16.5h.01"/>',
  smartphone: '<rect x="6.5" y="2.5" width="11" height="19" rx="2.5"/><path d="M11 18h2"/>',
  sourire: '<circle cx="12" cy="12" r="9"/><path d="M8.5 14.3c.9 1.2 2.1 1.8 3.5 1.8s2.6-.6 3.5-1.8M9 9.6h.01M15 9.6h.01"/>',
  support: '<path d="M4.5 14v-2a7.5 7.5 0 0 1 15 0v2"/><rect x="3" y="13.5" width="4" height="6" rx="1.5"/><rect x="17" y="13.5" width="4" height="6" rx="1.5"/><path d="M19 19.5c0 1-1 1.5-2.5 1.5H13"/>',
  utilisateur: '<circle cx="12" cy="8" r="4"/><path d="M4.5 20.5a7.5 7.5 0 0 1 15 0"/>',
  valise: '<rect x="3.5" y="7" width="17" height="13" rx="2.5"/><path d="M9 7V5.5A1.5 1.5 0 0 1 10.5 4h3A1.5 1.5 0 0 1 15 5.5V7M8 7v13m8-13v13"/>',
  voiture: '<path d="M4 15.5v-3.2l1.9-4.6a2 2 0 0 1 1.8-1.2h8.6a2 2 0 0 1 1.8 1.2l1.9 4.6v3.2a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1zM4.5 12h15"/><circle cx="7.5" cy="16.5" r="1.8"/><circle cx="16.5" cy="16.5" r="1.8"/>',
  famille: '<circle cx="9" cy="7.5" r="3"/><circle cx="17" cy="9.5" r="2.2"/><path d="M3.5 19.5a5.5 5.5 0 0 1 11 0m0 0a3.5 3.5 0 0 1 6.5-1.8"/>',
  virement: '<path d="M20.5 3.5 10 14m10.5-10.5-6.5 17-3.5-6.5-6.5-3.5z"/>',
};

export const NOMS_ICONES = Object.freeze(Object.keys(TRACES));

/** Icône SVG en ligne. Décorative par défaut ; avec titre, elle est annoncée. */
export function icone(nom, { taille = 20, classe = '', titre = '' } = {}) {
  const trace = TRACES[nom] || TRACES.info;
  const accessibilite = titre
    ? `role="img" aria-label="${echapperHtml(titre)}"`
    : 'aria-hidden="true" focusable="false"';
  return `<svg class="gmb-icone ${classe}" viewBox="0 0 24 24" width="${taille}" height="${taille}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" ${accessibilite}>${trace}</svg>`;
}


/* =============================================================================
   11. LOGO EN LIGNE (couleurs selon le thème, identifiants SVG uniques)
   ========================================================================== */
const LOGO_CROISSANT = 'M319.95 124.38A150 150 0 1 0 319.95 387.62A132 132 0 0 1 319.95 124.38Z';
const LOGO_GOUTTE = 'M322 220C344 252 362 274 362 294C362 316 344 330 322 330C300 330 282 316 282 294C282 274 300 252 322 220Z';
const LOGO_NOM = 'M169.68 84Q165.33 84 161.39 82.45Q157.46 80.9 154.43 77.86Q151.41 74.82 149.66 70.34Q147.92 65.86 147.92 60Q147.92 52.35 150.85 46.99Q153.78 41.63 158.72 38.82Q163.66 36 169.68 36Q178.58 36 183.66 40.13Q188.75 44.26 190.48 51.81L181.58 53.09Q180.34 49.06 177.5 46.64Q174.67 44.22 170.26 44.19Q165.87 44.13 162.96 46.08Q160.05 48.03 158.59 51.62Q157.14 55.2 157.14 60Q157.14 64.8 158.59 68.32Q160.05 71.84 162.96 73.79Q165.87 75.74 170.26 75.81Q173.23 75.87 175.65 74.78Q178.06 73.7 179.73 71.36Q181.39 69.02 182.1 65.38H174.8V58.66H191.38Q191.44 59.07 191.47 60.13Q191.5 61.18 191.5 61.34Q191.5 67.97 188.82 73.09Q186.13 78.21 181.23 81.1Q176.34 84 169.68 84ZM212.69 84Q207.38 84 203.33 81.71Q199.28 79.42 196.99 75.41Q194.7 71.39 194.7 66.21Q194.7 60.54 196.94 56.35Q199.18 52.16 203.12 49.84Q207.06 47.52 212.18 47.52Q217.62 47.52 221.42 50.08Q225.23 52.64 227.06 57.28Q228.88 61.92 228.34 68.19H219.73V64.99Q219.73 59.71 218.05 57.39Q216.37 55.07 212.56 55.07Q208.11 55.07 206.02 57.78Q203.92 60.48 203.92 65.76Q203.92 70.59 206.02 73.23Q208.11 75.87 212.18 75.87Q214.74 75.87 216.56 74.75Q218.38 73.63 219.34 71.52L228.05 74.02Q226.1 78.75 221.89 81.38Q217.68 84 212.69 84ZM201.23 68.19V61.73H224.14V68.19ZM234.26 83.04V48.48H241.94V56.93L241.1 55.84Q241.78 54.05 242.9 52.58Q244.02 51.1 245.65 50.14Q246.9 49.38 248.37 48.94Q249.84 48.51 251.41 48.4Q252.98 48.29 254.54 48.48V56.61Q253.1 56.16 251.2 56.3Q249.3 56.45 247.76 57.18Q246.22 57.89 245.17 59.06Q244.11 60.22 243.57 61.81Q243.02 63.39 243.02 65.38V83.04ZM259.34 83.04V36.96H267.15L282.38 67.55L297.62 36.96H305.42V83.04H297.3V55.52L283.92 83.04H280.85L267.47 55.52V83.04ZM328.66 84Q323.44 84 319.5 81.66Q315.57 79.33 313.38 75.22Q311.18 71.1 311.18 65.76Q311.18 60.35 313.42 56.24Q315.66 52.13 319.6 49.82Q323.54 47.52 328.66 47.52Q333.87 47.52 337.82 49.86Q341.78 52.19 343.98 56.3Q346.19 60.42 346.19 65.76Q346.19 71.14 343.97 75.25Q341.74 79.36 337.79 81.68Q333.84 84 328.66 84ZM328.66 75.87Q332.85 75.87 334.91 73.04Q336.98 70.21 336.98 65.76Q336.98 61.15 334.88 58.4Q332.78 55.65 328.66 55.65Q325.81 55.65 323.98 56.93Q322.16 58.21 321.28 60.48Q320.4 62.75 320.4 65.76Q320.4 70.4 322.5 73.14Q324.59 75.87 328.66 75.87ZM367.5 84Q362.29 84 358.35 81.66Q354.42 79.33 352.22 75.22Q350.03 71.1 350.03 65.76Q350.03 60.35 352.27 56.24Q354.51 52.13 358.45 49.82Q362.38 47.52 367.5 47.52Q372.72 47.52 376.67 49.86Q380.62 52.19 382.83 56.3Q385.04 60.42 385.04 65.76Q385.04 71.14 382.82 75.25Q380.59 79.36 376.64 81.68Q372.69 84 367.5 84ZM367.5 75.87Q371.7 75.87 373.76 73.04Q375.82 70.21 375.82 65.76Q375.82 61.15 373.73 58.4Q371.63 55.65 367.5 55.65Q364.66 55.65 362.83 56.93Q361.01 58.21 360.13 60.48Q359.25 62.75 359.25 65.76Q359.25 70.4 361.34 73.14Q363.44 75.87 367.5 75.87ZM414.35 83.04V66.72Q414.35 65.54 414.22 63.7Q414.1 61.86 413.42 60Q412.75 58.14 411.23 56.9Q409.71 55.65 406.93 55.65Q405.81 55.65 404.53 56Q403.25 56.35 402.13 57.36Q401.01 58.37 400.29 60.32Q399.57 62.27 399.57 65.5L394.58 63.14Q394.58 59.04 396.24 55.46Q397.9 51.87 401.25 49.66Q404.59 47.46 409.68 47.46Q413.74 47.46 416.3 48.83Q418.86 50.21 420.29 52.32Q421.71 54.43 422.32 56.72Q422.93 59.01 423.06 60.9Q423.18 62.78 423.18 63.65V83.04ZM390.74 83.04V48.48H398.48V59.94H399.57V83.04Z';
const LOGO_BANQUE = 'M430.22 83.04V36.96H448.66Q453.58 36.96 456.62 38.93Q459.66 40.9 461.07 43.87Q462.48 46.85 462.48 49.89Q462.48 53.76 460.74 56.32Q458.99 58.88 455.95 59.74V58.14Q460.27 59.04 462.43 62.14Q464.59 65.25 464.59 69.09Q464.59 73.22 463.07 76.35Q461.55 79.49 458.45 81.26Q455.34 83.04 450.64 83.04ZM439.06 74.85H449.74Q451.5 74.85 452.88 74.1Q454.26 73.34 455.04 71.98Q455.82 70.62 455.82 68.77Q455.82 67.14 455.15 65.86Q454.48 64.58 453.12 63.82Q451.76 63.07 449.74 63.07H439.06ZM439.06 54.94H448.53Q450 54.94 451.15 54.43Q452.3 53.92 452.98 52.85Q453.65 51.78 453.65 50.08Q453.65 47.97 452.34 46.53Q451.02 45.09 448.53 45.09H439.06ZM479.31 84Q475.6 84 473.02 82.58Q470.45 81.15 469.12 78.77Q467.79 76.38 467.79 73.5Q467.79 71.1 468.53 69.12Q469.26 67.14 470.91 65.62Q472.56 64.1 475.34 63.07Q477.26 62.37 479.92 61.82Q482.58 61.28 485.94 60.78Q489.3 60.29 493.33 59.68L490.19 61.41Q490.19 58.34 488.72 56.9Q487.25 55.46 483.79 55.46Q481.87 55.46 479.79 56.38Q477.71 57.31 476.88 59.68L469.01 57.18Q470.32 52.9 473.94 50.21Q477.55 47.52 483.79 47.52Q488.37 47.52 491.92 48.93Q495.47 50.34 497.3 53.79Q498.32 55.71 498.51 57.63Q498.7 59.55 498.7 61.92V83.04H491.09V75.94L492.18 77.41Q489.65 80.9 486.72 82.45Q483.79 84 479.31 84ZM481.17 77.15Q483.57 77.15 485.22 76.3Q486.86 75.46 487.84 74.37Q488.82 73.28 489.17 72.54Q489.84 71.14 489.95 69.26Q490.06 67.39 490.06 66.14L492.62 66.78Q488.75 67.42 486.35 67.86Q483.95 68.29 482.48 68.64Q481.01 68.99 479.89 69.41Q478.61 69.92 477.82 70.51Q477.04 71.1 476.67 71.81Q476.3 72.51 476.3 73.38Q476.3 74.56 476.9 75.41Q477.49 76.26 478.58 76.7Q479.66 77.15 481.17 77.15ZM529.3 83.04V66.72Q529.3 65.54 529.17 63.7Q529.04 61.86 528.37 60Q527.7 58.14 526.18 56.9Q524.66 55.65 521.87 55.65Q520.75 55.65 519.47 56Q518.19 56.35 517.07 57.36Q515.95 58.37 515.23 60.32Q514.51 62.27 514.51 65.5L509.52 63.14Q509.52 59.04 511.18 55.46Q512.85 51.87 516.19 49.66Q519.54 47.46 524.62 47.46Q528.69 47.46 531.25 48.83Q533.81 50.21 535.23 52.32Q536.66 54.43 537.26 56.72Q537.87 59.01 538 60.9Q538.13 62.78 538.13 63.65V83.04ZM505.68 83.04V48.48H513.42V59.94H514.51V83.04ZM545.1 83.04 545.17 36.96H554V65.12L565.71 48.48H576.46L563.98 65.76L577.3 83.04H565.97L554 66.4V83.04Z';

function symboleLogo(id) {
  return `<defs><linearGradient id="${id}-d" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#635BFF"/><stop offset=".55" stop-color="#7B5BFF"/><stop offset="1" stop-color="#00D4B8"/></linearGradient>`
    + `<radialGradient id="${id}-r" cx=".3" cy=".22" r=".68"><stop offset="0" stop-color="#FFFFFF" stop-opacity=".3"/><stop offset=".62" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient></defs>`
    + `<rect width="512" height="512" rx="112" fill="url(#${id}-d)"/><rect width="512" height="512" rx="112" fill="url(#${id}-r)"/>`
    + `<path d="${LOGO_CROISSANT}" fill="#FFFFFF"/><path d="${LOGO_GOUTTE}" fill="#FFFFFF"/>`
    + '<ellipse cx="306" cy="286" rx="7" ry="11" fill="#00D4B8" fill-opacity=".55"/>';
}

/** variante : « horizontal » (icône et nom) ou « icone ». */
export function logoSVG({ variante = 'horizontal', titre = 'GerMoonBank', decoratif = false } = {}) {
  const id = idUnique('gmb-logo');
  const accessibilite = decoratif
    ? 'aria-hidden="true" focusable="false"'
    : `role="img" aria-label="${echapperHtml(titre)}"`;
  if (variante === 'icone') {
    return `<svg class="gmb-logo gmb-logo--icone" viewBox="0 0 512 512" ${accessibilite}>${symboleLogo(id)}</svg>`;
  }
  return `<svg class="gmb-logo" viewBox="0 0 581 120" ${accessibilite}>`
    + `<g transform="scale(.234375)">${symboleLogo(id)}</g>`
    + `<path class="gmb-logo__nom" d="${LOGO_NOM}"/><path class="gmb-logo__banque" d="${LOGO_BANQUE}"/></svg>`;
}


/* =============================================================================
   12. LA LUNE, LANGAGE FONCTIONNEL
   phase : 0 = nouvelle lune, 1 = pleine lune ; la surface éclairée est
   proportionnelle à la valeur (37 % d'un objectif → 37 % du disque).
   ========================================================================== */
export function luneSVG(phase = 1, { taille = 24, classe = '', titre = '' } = {}) {
  const f = Math.min(1, Math.max(0, Number(phase) || 0));
  let eclairee = '';
  if (f >= 0.995) {
    eclairee = '<circle class="gmb-lune__eclairee" cx="12" cy="12" r="10"/>';
  } else if (f > 0.005) {
    const rx = (Math.abs(1 - 2 * f) * 10).toFixed(3);
    const balayage = f < 0.5 ? 0 : 1;
    eclairee = `<path class="gmb-lune__eclairee" d="M12 2A10 10 0 0 1 12 22A${rx} 10 0 0 ${balayage} 12 2Z"/>`;
  }
  const accessibilite = titre
    ? `role="img" aria-label="${echapperHtml(titre)}"`
    : 'aria-hidden="true" focusable="false"';
  return `<svg class="gmb-lune ${classe}" viewBox="0 0 24 24" width="${taille}" height="${taille}" ${accessibilite}>`
    + `<circle class="gmb-lune__ombre" cx="12" cy="12" r="10"/>${eclairee}</svg>`;
}


/* =============================================================================
   13. NOTIFICATIONS ÉPHÉMÈRES
   ========================================================================== */
let zoneNotifications = null;

/** type : info, succes, alerte, danger. Renvoie la fonction de fermeture. */
export function notifier(message, { type = 'info', duree = 6000 } = {}) {
  if (!zoneNotifications) {
    zoneNotifications = document.createElement('div');
    zoneNotifications.className = 'gmb-notifications';
    zoneNotifications.setAttribute('aria-live', 'polite');
    zoneNotifications.setAttribute('aria-relevant', 'additions');
    document.body.append(zoneNotifications);
  }
  const element = document.createElement('div');
  element.className = `gmb-notification gmb-notification--${type}`;
  element.setAttribute('role', type === 'danger' ? 'alert' : 'status');
  const nomIcone = { succes: 'check', alerte: 'alerte', danger: 'alerte' }[type] || 'info';
  element.innerHTML = `${icone(nomIcone, { classe: 'gmb-notification__icone' })}<p class="gmb-notification__texte"></p>`
    + `<button type="button" class="gmb-notification__fermer" aria-label="Fermer la notification">${icone('croix', { taille: 18 })}</button>`;
  element.querySelector('.gmb-notification__texte').textContent = message;

  let minuteur;
  const fermer = () => {
    clearTimeout(minuteur);
    element.dataset.visible = 'false';
    setTimeout(() => element.remove(), mouvementReduit() ? 0 : 260);
  };
  const programmer = () => {
    if (duree) minuteur = setTimeout(fermer, duree);
  };
  element.querySelector('.gmb-notification__fermer').addEventListener('click', fermer);
  element.addEventListener('pointerenter', () => clearTimeout(minuteur));
  element.addEventListener('pointerleave', programmer);
  element.addEventListener('focusin', () => clearTimeout(minuteur));

  setTimeout(() => {
    zoneNotifications.append(element);
    requestAnimationFrame(() => {
      element.dataset.visible = 'true';
    });
    programmer();
  }, 40);
  return fermer;
}


/* =============================================================================
   14. SUPABASE (chargé à la demande, une seule instance)
   Les opérations sensibles (code secret, activation) passent par des
   fonctions serveur (Edge Functions), jamais par le navigateur.
   ========================================================================== */
let promesseClient = null;

export function supabase() {
  if (!promesseClient) {
    promesseClient = import(CONFIG.supabase.module)
      .then(({ createClient }) => createClient(CONFIG.supabase.url, CONFIG.supabase.cle, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, storageKey: 'gmb-auth' },
      }))
      .catch((erreur) => {
        promesseClient = null;
        throw erreur;
      });
  }
  return promesseClient;
}

/** Appelle une fonction serveur Supabase (Edge Function). */
export async function fonctionServeur(nom, corps = {}) {
  const client = await supabase();
  const { data, error } = await client.functions.invoke(nom, { body: corps });
  if (error) throw error;
  return data;
}

/* =============================================================================
   CATALOGUE — prix, taux, frais et formules
   Source unique : data/products.json et data/rates.json, chargés au démarrage.
   Les éléments calculés (comparatif, Livret) sont dérivés de ces données.
   ========================================================================== */
async function lireDonnees(nom) {
  const reponse = await fetch(new URL(`../data/${nom}`, import.meta.url), { cache: 'no-cache' });
  if (!reponse.ok) throw new Error(`Données ${nom} indisponibles (HTTP ${reponse.status})`);
  return reponse.json();
}
function gelerProfond(valeur) {
  if (valeur && typeof valeur === 'object' && !Object.isFrozen(valeur)) {
    Object.values(valeur).forEach(gelerProfond);
    Object.freeze(valeur);
  }
  return valeur;
}
const [DONNEES_PRODUITS, DONNEES_TAUX] = await Promise.all([lireDonnees('products.json'), lireDonnees('rates.json')]);
// JSON ne connaît pas l'infini : un nombre d'utilisateurs null signifie « illimité »
DONNEES_PRODUITS.formulesPro.forEach((f) => { if (f.utilisateurs === null) f.utilisateurs = Infinity; });

/** Date d'effet des taux et prix affichés (mentions « en vigueur au … »). */
export const DATE_EFFET = gelerProfond(DONNEES_PRODUITS.dateEffet);

/* -----------------------------------------------------------------------------
   Formules Particuliers (prix TTC par mois)
   -------------------------------------------------------------------------- */
export const FORMULES = gelerProfond(DONNEES_PRODUITS.formules);

/** Paiement annuel : deux mois offerts (prix annuel = 10 mois). */
export const MOIS_PAYES_PAR_AN = gelerProfond(DONNEES_PRODUITS.moisPayesParAn);

export function formule(code) {
  return FORMULES.find((f) => f.code === code) || null;
}

export function prixAnnuel(code) {
  const f = formule(code);
  return f ? Math.round(f.prix * MOIS_PAYES_PAR_AN * 100) / 100 : null;
}

/* -----------------------------------------------------------------------------
   Tableau comparatif des formules (VIT-17)
   Chaque ligne donne une valeur par formule, dans l'ordre Luna → Zénith.
   true = inclus, false = non inclus, texte = valeur affichée telle quelle.
   -------------------------------------------------------------------------- */
const tous = (valeur) => FORMULES.map(() => valeur);
const parFormule = (fonction) => FORMULES.map(fonction);
const euros = (n) => `${new Intl.NumberFormat('fr-FR').format(n)}\u00A0€`;
const taux = (n) => `${new Intl.NumberFormat('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n)}\u00A0%`;
const assurance = (code) => parFormule((f) => f.assurances.includes(code));

export const COMPARATIF = Object.freeze([
  {
    groupe: 'Compte et carte',
    lignes: [
      { libelle: 'Compte courant', valeurs: tous(true) },
      { libelle: 'Carte physique', valeurs: parFormule((f) => f.carte) },
      { libelle: 'Cartes virtuelles', valeurs: parFormule((f) => String(f.cartesVirtuelles)) },
        { libelle: 'Gel de la carte et plafonds dans l’application', valeurs: tous(true) },
      { libelle: 'Notifications en temps réel', valeurs: tous(true) },
      { libelle: 'Découvert autorisé', valeurs: tous('Non proposé') },
    ],
  },
  {
    groupe: 'Virements',
    lignes: [
      { libelle: 'Virements SEPA, instantanés compris', valeurs: tous('Gratuits') },
      { libelle: 'Vérification du nom du bénéficiaire', valeurs: tous(true) },
      { libelle: 'Virements programmés et permanents', valeurs: tous(true) },
    ],
  },
  {
    groupe: 'À l’étranger',
    lignes: [
      { libelle: 'Paiements par carte en euros', valeurs: tous('Gratuits') },
      { libelle: 'Retraits hors zone euro inclus', valeurs: parFormule((f) => `${euros(f.retraitsHorsZone)} par mois`) },
      { libelle: 'Change sans frais', valeurs: parFormule((f) => (f.changeSansFrais ? `${euros(f.changeSansFrais)} par mois` : 'Illimité en jours ouvrés')) },
      { libelle: 'Retrait au-delà de la franchise', valeurs: tous('2 % (minimum 1 €)') },
      { libelle: 'Change au-delà de la franchise', valeurs: tous('0,5 % (+1 % le week-end)') },
    ],
  },
  {
    groupe: 'Épargne et avantages',
    lignes: [
      { libelle: 'Livret GMB, taux annuel brut', valeurs: parFormule((f) => taux(f.tauxLivret)) },
      { libelle: 'Coffres d’épargne', valeurs: parFormule((f) => (f.coffres ? String(f.coffres) : 'Illimités')) },
      { libelle: 'Arrondis automatiques', valeurs: tous(true) },
      { libelle: 'MoonPoints sur les paiements', valeurs: parFormule((f) => (f.moonpoints ? taux(f.moonpoints) : false)) },
    ],
  },
  {
    groupe: 'Assurances incluses',
    lignes: [
      { libelle: 'Assurance voyage', valeurs: assurance('voyage') },
      { libelle: 'Garantie des achats', valeurs: assurance('achats') },
      { libelle: 'Annulation de voyage', valeurs: assurance('annulation') },
      { libelle: 'Location de véhicule', valeurs: assurance('location') },
      { libelle: 'Téléphone', valeurs: assurance('telephone') },
      { libelle: 'Couverture familiale étendue', valeurs: assurance('famille') },
    ],
  },
  {
    groupe: 'Services',
    lignes: [
      { libelle: 'Service client', valeurs: parFormule((f) => f.service) },
      { libelle: 'Accès aux salons d’aéroport', valeurs: parFormule((f) => Boolean(f.salonsAeroport)) },
      { libelle: 'Engagement', valeurs: tous('Aucun') },
    ],
  },
]);

/** Frais hors formule (au-delà des franchises), affichés sous le comparatif. */
export const FRAIS_HORS_FORMULE = gelerProfond(DONNEES_PRODUITS.fraisHorsFormule);

/* -----------------------------------------------------------------------------
   Livret GMB (VIT-11)
   -------------------------------------------------------------------------- */
/** Plafonds de l'épargne réglementée (data/rates.json) : stables, fixés par la loi */
export const REGLEMENTES = gelerProfond(DONNEES_TAUX.reglementes);

export const LIVRET = Object.freeze({
  ...DONNEES_TAUX.livret,
  tauxMax: Math.max(...FORMULES.map((f) => f.tauxLivret)),
});

/* -----------------------------------------------------------------------------
   Prêt personnel (VIT-15) — grille publiée, contrôlée par le taux d'usure
   -------------------------------------------------------------------------- */
export const CREDIT = gelerProfond(DONNEES_TAUX.credit);

/** Taux débiteur de la grille pour une durée (et un objet) donnés. */
export function grilleCredit(dureeMois, objet = 'tous') {
  const ligne = CREDIT.grille.find((g) => (g.objet === objet || g.objet === 'tous') && dureeMois >= g.dureeMin && dureeMois <= g.dureeMax);
  return ligne ? ligne.tauxDebiteur : null;
}

/* -----------------------------------------------------------------------------
   International et change (VIT-14)
   Taux de référence publiés par la Banque centrale européenne chaque jour ouvré,
   chargés en direct (service public Frankfurter, données de la BCE) et gardés
   6 heures sur l'appareil. Le franc CFA (XOF) a une parité fixe et officielle avec
   l'euro (1 € = 655,957 F CFA) : la BCE ne le publie pas.
   -------------------------------------------------------------------------- */
export const INTERNATIONAL = gelerProfond(DONNEES_TAUX.international);

const SOURCES_TAUX = [
  (codes) => `https://api.frankfurter.dev/v1/latest?base=EUR&symbols=${codes}`,
  (codes) => `https://api.frankfurter.app/latest?from=EUR&to=${codes}`,
];
const CLE_TAUX = 'gmb-taux-bce';

/** Taux de référence de la BCE du dernier jour ouvré : { date, taux: { USD: 1.1x, … } }. */
export async function tauxBCE() {
  try {
    const garde = JSON.parse(localStorage.getItem(CLE_TAUX) || 'null');
    if (garde && Date.now() - garde.lu < 6 * 3600 * 1000) return garde.valeur;
  } catch { /* stockage indisponible : lecture en direct */ }
  const codes = INTERNATIONAL.devises.filter((d) => !d.fixe).map((d) => d.code).join(',');
  let derniereErreur = null;
  for (const source of SOURCES_TAUX) {
    const abandon = new AbortController();
    const minuteur = setTimeout(() => abandon.abort(), 8000);
    try {
      const reponse = await fetch(source(codes), { headers: { Accept: 'application/json' }, signal: abandon.signal });
      if (!reponse.ok) throw new Error(`HTTP ${reponse.status}`);
      const json = await reponse.json();
      if (!json?.rates || !json?.date) throw new Error('réponse inattendue');
      const valeur = { date: json.date, taux: { ...json.rates, XOF: 655.957 } };
      try { localStorage.setItem(CLE_TAUX, JSON.stringify({ lu: Date.now(), valeur })); } catch { /* rien */ }
      return valeur;
    } catch (erreur) {
      derniereErreur = erreur;
    } finally {
      clearTimeout(minuteur);
    }
  }
  throw new Error(`Taux de la BCE indisponibles (${derniereErreur?.message || 'erreur'})`);
}

/** Frais d'un retrait hors zone euro, compte tenu de la franchise restante. */
export function fraisRetrait(montant, codeFormule, dejaRetire = 0) {
  const f = formule(codeFormule);
  const reste = Math.max(0, (f?.retraitsHorsZone ?? 0) - dejaRetire);
  const horsFranchise = Math.max(0, montant - reste);
  const frais = horsFranchise > 0 ? Math.max(INTERNATIONAL.fraisRetraitMinimum, (horsFranchise * INTERNATIONAL.fraisRetrait) / 100) : 0;
  return { dansFranchise: montant - horsFranchise, horsFranchise, frais: Math.round(frais * 100) / 100 };
}

/** Frais d'une conversion : 0,5 % au-delà de la franchise, +1 % le week-end. */
export function fraisChange(montant, codeFormule, { dejaConverti = 0, weekend = false } = {}) {
  const f = formule(codeFormule);
  const franchise = f?.changeSansFrais;
  const dansFranchise = franchise == null ? montant : Math.min(montant, Math.max(0, franchise - dejaConverti));
  const horsFranchise = montant - dansFranchise;
  const frais = (horsFranchise * INTERNATIONAL.fraisChange) / 100 + (weekend ? (montant * INTERNATIONAL.majorationWeekend) / 100 : 0);
  return { dansFranchise, horsFranchise, frais: Math.round(frais * 100) / 100 };
}

/* -----------------------------------------------------------------------------
   Formules Pro et Business (prix HT par mois) — VIT-20, VIT-22, VIT-23
   -------------------------------------------------------------------------- */
export const FORMULES_PRO = gelerProfond(DONNEES_PRODUITS.formulesPro);

/** Prix HT de chaque opération SEPA au-delà du forfait. */
export const OPERATION_SUPPLEMENTAIRE_HT = gelerProfond(DONNEES_PRODUITS.operationSupplementaireHT);

/** Besoins du simulateur VIT-23 : niveau minimal de formule requis. */
export const BESOINS_PRO = gelerProfond(DONNEES_PRODUITS.besoinsPro);

export function formulePro(code) {
  return FORMULES_PRO.find((f) => f.code === code) || null;
}

/** Coût mensuel HT de chaque formule et recommandation de la moins chère (VIT-23). */
export function coutsPro({ utilisateurs = 1, operations = 0, besoin = 'aucun' } = {}) {
  const niveauMin = (BESOINS_PRO.find((b) => b.code === besoin) || BESOINS_PRO[0]).niveauMin;
  const lignes = FORMULES_PRO.map((f) => {
    const adaptee = utilisateurs <= f.utilisateurs && f.niveau >= niveauMin;
    const supplement = Math.max(0, operations - f.operationsIncluses) * OPERATION_SUPPLEMENTAIRE_HT;
    const total = Math.round((f.prixHT + supplement) * 100) / 100;
    let raison = '';
    if (utilisateurs > f.utilisateurs) raison = `${f.utilisateursLibelle} utilisateur${f.utilisateurs > 1 ? 's' : ''} au plus`;
    else if (f.niveau < niveauMin) raison = 'Fonction requise non incluse';
    return { code: f.code, nom: f.nom, adaptee, supplement: Math.round(supplement * 100) / 100, total, raison };
  });
  const adaptees = lignes.filter((l) => l.adaptee);
  const recommandee = adaptees.reduce((min, l) => (!min || l.total < min.total ? l : min), null);
  return { lignes, recommandee };
}

/* -----------------------------------------------------------------------------
   Réforme de la facturation électronique (VIT-21, PRO-02)
   -------------------------------------------------------------------------- */
export const FACTURATION = gelerProfond(DONNEES_PRODUITS.facturation);

/* -----------------------------------------------------------------------------
   Offre Jeunes (VIT-30, JEU-04)
   -------------------------------------------------------------------------- */
export const JEUNES = gelerProfond(DONNEES_PRODUITS.jeunes);

/* -----------------------------------------------------------------------------
   Calendrier des services à venir (feuille de route, phase 4)
   -------------------------------------------------------------------------- */
export const CALENDRIER = gelerProfond(DONNEES_PRODUITS.calendrier);

/* -----------------------------------------------------------------------------
   Mentions réutilisées
   -------------------------------------------------------------------------- */
export const MENTIONS = gelerProfond(DONNEES_PRODUITS.mentions);

export const CATALOGUE = Object.freeze({
  DATE_EFFET, FORMULES, COMPARATIF, FRAIS_HORS_FORMULE, LIVRET, CREDIT, INTERNATIONAL, CALENDRIER, MENTIONS, MOIS_PAYES_PAR_AN,
  FORMULES_PRO, OPERATION_SUPPLEMENTAIRE_HT, BESOINS_PRO, FACTURATION, JEUNES,
});
