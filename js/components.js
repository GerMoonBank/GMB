/* =============================================================================
   GerMoonBank (GMB) · js/components.js
   Composants et rendus des pages publiques — version 3
   -----------------------------------------------------------------------------
   En-tête <gm-header> (données dans nav.js) et pied de page <gm-footer> ;
   rendus branchés sur le catalogue (formules, comparatifs, tableaux, galerie
   de cartes, Pro, Business, Jeunes) ; documents tarifaires ; enregistrement du
   service worker. Chargé par toutes les pages publiques.
   ========================================================================== */

import {
  CALENDRIER, COMPARATIF, CONFIG, CREDIT, DATE_EFFET, FACTURATION,
  FORMULES, FORMULES_PRO, FRAIS_HORS_FORMULE, INTERNATIONAL, JEUNES, LIVRET,
  MENTIONS, OPERATION_SUPPLEMENTAIRE_HT, bloquerDefilement, chemin, consentement, coutCredit,
  echapperHtml, formaterDate, formaterMontant, formaterNombre, formaterTaux, formule,
  formulePro, fraisRetrait, grilleCredit, icone, idUnique, interetsLivret,
  lienOuverture, logoSVG, luneSVG, mouvementReduit, notifier, parImage,
  prixAnnuel, stockage,
  initialiserTheme,
} from './core.js';
import {
  ACCES, CLE_BANNIERE_APP, ECRAN_BUREAU, LIENS_SECONDAIRES, LIENS_SIMPLES, NAVIGATION,
  NIVEAUX_BANDEAU,
} from './nav.js';
import { client as clientDonnees } from './donnees.js';

// Pages de connexion de l'Espace client : leur apparence (« Nuit » par défaut, ou celle choisie par le client) est posée dans la page
if (!document.body?.classList.contains('auth-client')) initialiserTheme();

/* Lien reçu par e-mail (confirmation d'adresse, connexion, mot de passe) arrivé sur une page qui
   n'ouvre pas de session : c'est le cas quand Supabase renvoie vers l'accueil du site. La page
   prévue prend le relais, avec les mêmes informations (elles restent après le signe #). */
(() => {
  const h = location.hash;
  if (!/(?:^#|&)(?:access_token|error_description)=/.test(h)) return;
  if (/\/(?:auth|bo|app|public\/inscription)\//.test(location.pathname)) return;
  const type = new URLSearchParams(h.slice(1)).get('type');
  const cible = type === 'recovery' ? 'auth/mot-de-passe-oublie.html' : type === 'signup' ? 'public/inscription/index.html?confirmation=1' : 'auth/mon-dossier.html';
  location.replace(chemin(cible) + h);
})();

/* =============================================================================
   1. EN-TÊTE <gm-header>
   ========================================================================== */
class GmHeader extends HTMLElement {
  connectedCallback() {
    if (this.dataset.monte) return;
    this.dataset.monte = 'true';
    this.ids = { menu: idUnique('gmb-menu'), segments: idUnique('gmb-seg') };
    this.innerHTML = this.gabarit();
    this.entete = this.querySelector('.gmb-entete');
    this.voile = this.querySelector('.gmb-voile');
    this.menu = this.querySelector('.gmb-menu-mobile');
    this.burger = this.querySelector('[data-action="ouvrir-menu"]');
    this.megaOuvert = null;
    this.brancher();
  }

  disconnectedCallback() {
    this.nettoyages?.forEach((nettoyer) => nettoyer());
  }

  /* ---------------------------------------------------------------------------
     Gabarits
     ------------------------------------------------------------------------ */
  attr(nom, defaut = '') {
    return this.getAttribute(nom) ?? defaut;
  }

  courant(page) {
    return page && page === this.attr('page') ? ' aria-current="page"' : '';
  }

  gabarit() {
    const surSombre = this.hasAttribute('sur-sombre');
    const themeEntete = surSombre ? ' data-transparent="true" data-theme="sombre"' : '';
    return `${this.gabaritBanniereApp()}${this.gabaritBandeau()}
<header class="gmb-entete" data-etat="haut"${themeEntete}>
  <div class="gmb-conteneur gmb-entete__barre">
    <a class="gmb-entete__logo" href="${chemin('')}" aria-label="GerMoonBank, accueil"${this.courant('accueil')}>${logoSVG({ decoratif: true })}</a>
    <nav class="gmb-entete__nav" aria-label="Navigation principale">
      <ul class="gmb-entete__liens">
        ${NAVIGATION.map((segment) => this.gabaritEntreeNav(segment)).join('')}
        ${LIENS_SIMPLES.map((lien) => `<li><a class="gmb-entete__lien" href="${chemin(lien.href)}"${this.courant(lien.page)}>${lien.libelle}</a></li>`).join('')}
      </ul>
    </nav>
    <div class="gmb-entete__actions">
      <a class="gmb-icone-bouton" href="${chemin('public/societe/accessibilite.html')}" aria-label="Accessibilité" title="Accessibilité">${icone('accessibilite', { taille: 22 })}</a>
      <a class="gmb-entete__suivre" href="${chemin(ACCES.suivre)}" aria-label="Suivre mon dossier">${icone('dossier')}<span class="gmb-entete__suivre-texte">Suivre mon dossier</span></a>
      <a class="gmb-bouton gmb-bouton--contour gmb-bouton--petit gmb-entete__espace" href="${chemin(ACCES.espaceClient)}" aria-label="Espace client">${icone('cadenas', { taille: 18 })}<span class="gmb-entete__texte-large">Espace client</span></a>
      <a class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" href="${this.lienOuvrir()}">Ouvrir un compte</a>
    </div>
    <div class="gmb-entete__mobile">
      <a class="gmb-icone-bouton" href="${chemin(ACCES.espaceClient)}" aria-label="Espace client">${icone('cadenas', { taille: 22 })}</a>
      <button type="button" class="gmb-icone-bouton" data-action="ouvrir-menu" aria-expanded="false" aria-controls="${this.ids.menu}" aria-label="Ouvrir le menu">
        <span class="gmb-burger" aria-hidden="true"><span></span><span></span><span></span></span>
      </button>
    </div>
  </div>
</header>
<div class="gmb-voile gmb-voile--sous-entete" data-visible="false" aria-hidden="true"></div>
${this.gabaritMenuMobile()}`;
  }

  lienOuvrir() {
    const segment = this.attr('segment', 'particuliers');
    return lienOuverture({ segment: segment === 'jeunes' ? 'particuliers' : segment });
  }

  gabaritEntreeNav(segment) {
    const pageActive = segment.colonnes.some((c) => c.liens.some((l) => l.page === this.attr('page')));
    if (segment.href) {
      return `<li><a class="gmb-entete__lien" href="${chemin(segment.href)}"${this.courant(segment.page)}>${segment.libelle}</a></li>`;
    }
    const idPanneau = `${this.ids.menu}-${segment.cle}`;
    return `<li data-segment="${segment.cle}">
      <button type="button" class="gmb-entete__lien" aria-expanded="false" aria-controls="${idPanneau}"${pageActive ? ' aria-current="page"' : ''}>${segment.libelle}${icone('chevronBas', { taille: 16, classe: 'gmb-entete__chevron' })}</button>
      <div class="gmb-mega" id="${idPanneau}" data-ouvert="false">
        <div class="gmb-conteneur gmb-mega__contenu">
          ${segment.colonnes.map((colonne) => `<div>
            <p class="gmb-mega__titre">${colonne.titre}</p>
            <ul class="gmb-mega__liste">
              ${colonne.liens.map((lien) => `<li><a class="gmb-mega__lien" href="${chemin(lien.href)}"${this.courant(lien.page)}>
                <span class="gmb-mega__icone">${icone(lien.icone)}</span>
                <span class="gmb-mega__lien-titre">${lien.titre}</span>
                <span class="gmb-mega__lien-texte">${lien.texte}</span></a></li>`).join('')}
            </ul></div>`).join('')}
          ${segment.colonnes.length < 3 ? '<div aria-hidden="true"></div>'.repeat(3 - segment.colonnes.length) : ''}
          ${segment.carte ? `<div class="gmb-mega__carte" data-theme="sombre">
            <p class="gmb-badge gmb-badge--marque">${segment.carte.surtitre}</p>
            <p class="gmb-mega__carte-titre">${segment.carte.titre}</p>
            <p class="gmb-mega__carte-texte">${segment.carte.texte}</p>
            <a class="gmb-lien-fleche" href="${chemin(segment.carte.lien.href)}">${segment.carte.lien.libelle}${icone('flecheDroite', { taille: 18 })}</a>
          </div>` : ''}
        </div>
      </div>
    </li>`;
  }

  gabaritMenuMobile() {
    const actif = NAVIGATION.some((s) => s.cle === this.attr('segment')) ? this.attr('segment') : 'particuliers';
    const onglets = NAVIGATION.map((segment) => {
      const choisi = segment.cle === actif;
      return `<button type="button" role="tab" class="gmb-menu-mobile__segment" id="${this.ids.segments}-onglet-${segment.cle}"
        aria-selected="${choisi}" aria-controls="${this.ids.segments}-${segment.cle}" tabindex="${choisi ? 0 : -1}" data-segment="${segment.cle}">${segment.libelle}</button>`;
    }).join('');
    const panneaux = NAVIGATION.map((segment) => `<div class="gmb-menu-mobile__panneau" role="tabpanel" id="${this.ids.segments}-${segment.cle}"
      aria-labelledby="${this.ids.segments}-onglet-${segment.cle}"${segment.cle === actif ? '' : ' hidden'}>
      ${segment.colonnes.map((colonne, rang) => `<details class="gmb-menu-mobile__rubrique"${rang === 0 ? ' open' : ''}>
        <summary>${colonne.titre}</summary>
        <ul class="gmb-menu-mobile__sous-liens">
          ${colonne.liens.map((lien) => `<li><a href="${chemin(lien.href)}"${this.courant(lien.page)}>${lien.titre}</a></li>`).join('')}
        </ul>
      </details>`).join('')}
    </div>`).join('');

    return `<dialog class="gmb-menu-mobile" id="${this.ids.menu}" aria-label="Menu" data-ouvert="false">
  <div class="gmb-menu-mobile__haut">
    <a class="gmb-entete__logo" href="${chemin('')}" aria-label="GerMoonBank, accueil">${logoSVG({ decoratif: true })}</a>
    <button type="button" class="gmb-icone-bouton" data-action="fermer-menu" aria-label="Fermer le menu">${icone('croix', { taille: 24 })}</button>
  </div>
  <div class="gmb-menu-mobile__segments" role="tablist" aria-label="Choisir un univers">${onglets}</div>
  <div class="gmb-menu-mobile__corps">
    <a class="gmb-menu-mobile__decouvrir" href="${chemin('public/societe/a-propos.html')}">Découvrir GerMoonBank${icone('flecheDroite', { taille: 20 })}</a>
    ${panneaux}
    <details class="gmb-menu-mobile__rubrique">
      <summary>Tarifs et aide</summary>
      <ul class="gmb-menu-mobile__sous-liens">
        ${LIENS_SIMPLES.map((lien) => `<li><a href="${chemin(lien.href)}"${this.courant(lien.page)}>${lien.libelle}</a></li>`).join('')}
      </ul>
    </details>
    <ul class="gmb-menu-mobile__secondaire">
      ${LIENS_SECONDAIRES.map((lien) => `<li><a href="${chemin(lien.href)}">${icone(lien.icone)}${lien.libelle}</a></li>`).join('')}
    </ul>
    <a class="gmb-menu-mobile__suivre" href="${chemin(ACCES.suivre)}">
      <span class="gmb-rangee gmb-rangee--serree">${icone('dossier')}Suivre mon dossier</span>${icone('chevronDroite')}
    </a>
  </div>
  <div class="gmb-menu-mobile__actions">
    <a class="gmb-bouton gmb-bouton--principal" href="${this.lienOuvrir()}">Ouvrir un compte</a>
    <a class="gmb-bouton gmb-bouton--secondaire" href="${chemin(ACCES.espaceClient)}">Espace client</a>
  </div>
</dialog>`;
  }

  gabaritBanniereApp() {
    if (this.hasAttribute('sans-banniere-app') || stockage.lire(CLE_BANNIERE_APP)) return '';
    return `<div class="gmb-banniere-app" role="region" aria-label="Application mobile">
  <span class="gmb-banniere-app__icone">${logoSVG({ variante: 'icone', decoratif: true })}</span>
  <span class="gmb-banniere-app__texte">
    <span class="gmb-banniere-app__nom">${CONFIG.nom}</span>
    <span class="gmb-banniere-app__detail">Application gratuite</span>
  </span>
  <a class="gmb-bouton gmb-bouton--principal gmb-bouton--petit" href="${chemin('#application')}">Obtenir</a>
  <button type="button" class="gmb-icone-bouton" data-action="fermer-banniere-app" aria-label="Fermer la bannière de l’application">${icone('croix', { taille: 18 })}</button>
</div>`;
  }

  gabaritBandeau() {
    const niveau = this.attr('bandeau-niveau');
    const texte = this.attr('bandeau-texte');
    if (!NIVEAUX_BANDEAU.includes(niveau) || !texte) return '';
    const id = this.attr('bandeau-id', `${niveau}-${texte.length}`);
    if (niveau !== 'incident' && stockage.lire(`gmb-bandeau-${id}`)) return '';
    const lien = this.attr('bandeau-lien');
    const libelle = this.attr('bandeau-libelle', 'En savoir plus');
    const role = niveau === 'incident' || niveau === 'alerte' ? 'role="alert"' : 'role="region" aria-label="Information"';
    return `<div class="gmb-bandeau gmb-bandeau--${niveau}" ${role} data-bandeau="${echapperHtml(id)}">
  <span>${echapperHtml(texte)}</span>${lien ? ` <a href="${chemin(lien)}">${echapperHtml(libelle)}</a>` : ''}
  ${niveau === 'incident' ? '' : `<button type="button" class="gmb-bandeau__fermer" data-action="fermer-bandeau" aria-label="Fermer ce message">${icone('croix', { taille: 18 })}</button>`}
</div>`;
  }

  /* ---------------------------------------------------------------------------
     Comportements
     ------------------------------------------------------------------------ */
  brancher() {
    this.nettoyages = [];
    const ecouter = (cible, type, fonction, options) => {
      cible.addEventListener(type, fonction, options);
      this.nettoyages.push(() => cible.removeEventListener(type, fonction, options));
    };

    // Clics délégués
    ecouter(this, 'click', (evenement) => {
      const cible = evenement.target.closest('[data-action], .gmb-entete__liens > li > button, a[href]');
      if (!cible) return;
      const action = cible.dataset.action;
      if (action === 'ouvrir-menu') this.ouvrirMenu();
      else if (action === 'fermer-menu') this.fermerMenu();
      else if (action === 'fermer-banniere-app') this.fermerBanniereApp(cible);
      else if (action === 'fermer-bandeau') this.fermerBandeau(cible);
      else if (cible.matches('.gmb-entete__liens > li > button')) this.basculerMega(cible);
      else if (cible.matches('a[href]')) {
        // Un lien d'ancre dans la page : on referme les menus avant de défiler
        this.fermerMega();
        if (this.menu.open) this.fermerMenu({ rendreFocus: false });
      }
    });

    // Méga-menu : survol à la souris avec un court délai d'intention
    this.querySelectorAll('.gmb-entete__liens > li[data-segment]').forEach((entree) => {
      const bouton = entree.querySelector('button');
      let minuteur;
      ecouter(entree, 'pointerenter', (e) => {
        if (e.pointerType !== 'mouse') return;
        clearTimeout(minuteur);
        minuteur = setTimeout(() => this.ouvrirMega(bouton, { parSurvol: true }), this.megaOuvert ? 0 : 140);
      });
      ecouter(entree, 'pointerleave', (e) => {
        if (e.pointerType !== 'mouse') return;
        clearTimeout(minuteur);
        minuteur = setTimeout(() => {
          if (this.megaOuvert === bouton && this.megaParSurvol) this.fermerMega();
        }, 220);
      });
      // Clavier : le menu se referme quand le focus quitte l'entrée
      ecouter(entree, 'focusout', (e) => {
        if (this.megaOuvert === bouton && !entree.contains(e.relatedTarget)) this.fermerMega();
      });
    });

    ecouter(this.voile, 'click', () => this.fermerMega());

    ecouter(document, 'keydown', (e) => {
      if (e.key === 'Escape' && this.megaOuvert) {
        const bouton = this.megaOuvert;
        this.fermerMega();
        bouton.focus();
      }
    });

    ecouter(document, 'pointerdown', (e) => {
      if (this.megaOuvert && !this.entete.contains(e.target)) this.fermerMega();
    });

    // Menu mobile : Échap anime la fermeture au lieu de couper net
    ecouter(this.menu, 'cancel', (e) => {
      e.preventDefault();
      this.fermerMenu();
    });

    // Onglets de segment : flèches, Début, Fin (activation automatique)
    const liste = this.menu.querySelector('[role="tablist"]');
    ecouter(liste, 'click', (e) => {
      const onglet = e.target.closest('[role="tab"]');
      if (onglet) this.choisirSegment(onglet.dataset.segment);
    });
    ecouter(liste, 'keydown', (e) => {
      const onglets = [...liste.querySelectorAll('[role="tab"]')];
      const rang = onglets.indexOf(document.activeElement);
      if (rang < 0) return;
      const cibles = { ArrowRight: rang + 1, ArrowLeft: rang - 1, Home: 0, End: onglets.length - 1 };
      if (!(e.key in cibles)) return;
      e.preventDefault();
      const suivant = onglets[(cibles[e.key] + onglets.length) % onglets.length];
      this.choisirSegment(suivant.dataset.segment);
      suivant.focus();
    });

    // État de défilement : ombre, et passage du sombre au clair si sur-sombre
    const majDefilement = parImage(() => this.majEtat());
    ecouter(window, 'scroll', majDefilement, { passive: true });
    this.majEtat();

    // Changement de taille d'écran : on ferme ce qui n'existe plus
    const requete = matchMedia(ECRAN_BUREAU);
    ecouter(requete, 'change', (e) => {
      if (e.matches && this.menu.open) this.fermerMenu({ rendreFocus: false, immediat: true });
      if (!e.matches) this.fermerMega();
    });
  }

  majEtat() {
    const defile = window.scrollY > 8;
    this.entete.dataset.etat = defile ? 'defile' : 'haut';
    if (this.hasAttribute('sur-sombre')) {
      if (defile) delete this.entete.dataset.theme;
      else this.entete.dataset.theme = 'sombre';
    }
  }

  /* Méga-menu ---------------------------------------------------------------- */
  basculerMega(bouton) {
    if (this.megaOuvert === bouton) {
      // Ouvert au survol puis cliqué : on le garde ouvert
      if (this.megaParSurvol) this.megaParSurvol = false;
      else this.fermerMega();
      return;
    }
    this.ouvrirMega(bouton);
  }

  ouvrirMega(bouton, { parSurvol = false } = {}) {
    if (this.megaOuvert === bouton) return;
    this.fermerMega();
    const panneau = document.getElementById(bouton.getAttribute('aria-controls'));
    bouton.setAttribute('aria-expanded', 'true');
    panneau.dataset.ouvert = 'true';
    this.voile.dataset.visible = 'true';
    this.megaOuvert = bouton;
    this.megaParSurvol = parSurvol;
  }

  fermerMega() {
    if (!this.megaOuvert) return;
    const panneau = document.getElementById(this.megaOuvert.getAttribute('aria-controls'));
    this.megaOuvert.setAttribute('aria-expanded', 'false');
    panneau.dataset.ouvert = 'false';
    this.voile.dataset.visible = 'false';
    this.megaOuvert = null;
    this.megaParSurvol = false;
  }

  /* Menu mobile -------------------------------------------------------------- */
  ouvrirMenu() {
    if (this.menu.open) return;
    this.fermerMega();
    this.menu.showModal();
    bloquerDefilement(true);
    this.burger.setAttribute('aria-expanded', 'true');
    requestAnimationFrame(() => {
      this.menu.dataset.ouvert = 'true';
      this.menu.querySelector('[role="tab"][aria-selected="true"]')?.focus();
    });
  }

  fermerMenu({ rendreFocus = true, immediat = false } = {}) {
    if (!this.menu.open) return;
    this.menu.dataset.ouvert = 'false';
    this.burger.setAttribute('aria-expanded', 'false');
    const terminer = () => {
      this.menu.close();
      bloquerDefilement(false);
      if (rendreFocus) this.burger.focus();
    };
    if (immediat || mouvementReduit()) terminer();
    else setTimeout(terminer, 330);
  }

  choisirSegment(cle) {
    this.menu.querySelectorAll('[role="tab"]').forEach((onglet) => {
      const choisi = onglet.dataset.segment === cle;
      onglet.setAttribute('aria-selected', String(choisi));
      onglet.tabIndex = choisi ? 0 : -1;
      document.getElementById(onglet.getAttribute('aria-controls')).hidden = !choisi;
    });
  }

  /* Bannières ---------------------------------------------------------------- */
  fermerBanniereApp(bouton) {
    stockage.ecrire(CLE_BANNIERE_APP, true, CONFIG.durees.banniereApp);
    bouton.closest('.gmb-banniere-app')?.remove();
  }

  fermerBandeau(bouton) {
    const bandeau = bouton.closest('[data-bandeau]');
    stockage.ecrire(`gmb-bandeau-${bandeau.dataset.bandeau}`, true, CONFIG.durees.bandeau);
    bandeau.remove();
    this.querySelector('.gmb-entete__logo')?.focus();
  }
}

if (!customElements.get('gm-header')) customElements.define('gm-header', GmHeader);

/* =============================================================================
   2. PIED DE PAGE <gm-footer>
   ========================================================================== */
const COLONNES = [
  {
    titre: 'Particuliers',
    liens: [
      ['Compte et carte', 'public/particuliers/compte-courant.html'],
      ['Épargne et Livret GMB', 'public/epargne/index.html'],
      ['Crédits', 'public/credit/pret-personnel.html'],
      ['International et change', 'public/cartes/frais-etranger.html'],
      ['Assurances', 'public/cartes/assurances.html'],
      ['Tarifs', 'public/tarifs/particuliers.html'],
    ],
  },
  {
    titre: 'Pro et Business',
    liens: [
      ['Compte Pro', 'public/business/compte-pro.html'],
      ['Facturation électronique', 'public/business/facturation.html'],
      ['Compte Business', 'public/business/'],
      ['Tarifs Pro et Business', 'public/tarifs/business.html'],
      ['Portail développeurs', 'public/business/api-developpeurs.html'],
    ],
  },
  {
    titre: 'GerMoonBank',
    liens: [
      ['À propos et engagements', 'public/societe/a-propos.html'],
      ['Sécurité et fraude', 'public/societe/securite.html'],
      ['Jeunes et parents', 'public/kids-teens/'],
      ['État des services', 'public/aide/etat-des-services.html'],
    ],
  },
  {
    titre: 'Aide et légal',
    liens: [
      ['Centre d’aide', 'public/aide/'],
      ['Contact et réclamations', 'public/legal/mediation.html'],
      ['Suivre mon dossier', 'auth/mon-dossier.html'],
      ['Espace client', 'auth/connexion.html'],
      ['Conditions et documents', 'public/legal/mentions-legales.html'],
    ],
  },
];

const LIENS_LEGAUX = [
  ['Mentions légales', 'public/legal/mentions-legales.html'],
  ['Confidentialité', 'public/legal/rgpd.html'],
  ['Accessibilité', 'public/societe/accessibilite.html'],
];

/** Réseaux sociaux : [nom, adresse]. Laisser l'adresse vide masque le réseau. */
const RESEAUX = [
  ['LinkedIn', ''],
  ['Instagram', ''],
];

class GmFooter extends HTMLElement {
  connectedCallback() {
    if (this.dataset.monte) return;
    this.dataset.monte = 'true';
    this.idDialogue = idUnique('gmb-cookies');
    this.innerHTML = this.gabarit();
    this.dialogue = this.querySelector('.gmb-dialogue');
    this.bandeau = this.querySelector('.gmb-cookies');
    this.brancher();
    if (!consentement.aDecide()) this.bandeau.hidden = false;
  }

  gabarit() {
    const annee = new Date().getFullYear();
    const reseaux = RESEAUX.filter(([, url]) => url);
    return `<footer class="gmb-pied" data-theme="sombre">
  <div class="gmb-conteneur">
    <div class="gmb-pied__haut">
      <div>
        <a class="gmb-pied__logo" href="${chemin('')}" aria-label="GerMoonBank, accueil">${logoSVG({ decoratif: true })}</a>
        <p class="gmb-pied__accroche">La banque qui veille sur votre argent, jour et nuit.</p>
      </div>
      <p class="gmb-pied__applis">${icone('smartphone')}<span>Application web : depuis votre navigateur, ajoutez GerMoonBank à l’écran d’accueil de votre téléphone.</span></p>
    </div>

    <nav class="gmb-pied__colonnes" aria-label="Plan du site">
      ${COLONNES.map((colonne) => `<section>
        <h2 class="gmb-pied__titre">${colonne.titre}</h2>
        <ul class="gmb-pied__liens">
          ${colonne.liens.map(([libelle, href]) => `<li><a href="${chemin(href)}">${libelle}</a></li>`).join('')}
        </ul>
      </section>`).join('')}
    </nav>

    <div class="gmb-pied__mentions">
      <p class="gmb-pied__statut"><strong>Statut.</strong> GerMoonBank est édité par The Hub of Inspiration of Soccer (HubISoccer). GerMoonBank n’est ni un établissement de crédit, ni un établissement de paiement, ni un établissement de monnaie électronique agréé par l’ACPR.</p>
      <p>GerMoonBank est une marque de The Hub of Inspiration of Soccer (RCCM RB/ABC/24 A 111814). Les services bancaires et de paiement seront fournis par un établissement partenaire agréé, dont l’identité et les agréments figureront ici avant tout lancement commercial.</p>
      <p>Les sommes déposées ne bénéficient pas de la garantie des dépôts (FGDR). Un crédit vous engage et doit être remboursé. Vérifiez vos capacités de remboursement avant de vous engager.</p>
    </div>

    <div class="gmb-pied__bas">
      <ul class="gmb-pied__legal">
        ${LIENS_LEGAUX.map(([libelle, href]) => `<li><a href="${chemin(href)}">${libelle}</a></li>`).join('')}
        <li><button type="button" class="gmb-lien-bouton gmb-pied__cookies" data-action="reglages-cookies">Gérer les cookies</button></li>
      </ul>
      <div class="gmb-pied__langues" role="group" aria-label="Langue du site">
        <a class="gmb-pied__langue" href="#" lang="fr" aria-current="true" data-langue="fr">Français</a>
        <a class="gmb-pied__langue" href="#" lang="en" hreflang="en" data-langue="en">English</a>
      </div>
      ${reseaux.length ? `<div class="gmb-pied__reseaux">${reseaux.map(([nom, url]) => `<a href="${url}" rel="noopener" aria-label="GerMoonBank sur ${nom}">${icone('globe')}</a>`).join('')}</div>` : ''}
      <p>© ${annee} GerMoonBank</p>
    </div>
  </div>
</footer>

<section class="gmb-cookies" aria-labelledby="${this.idDialogue}-titre-bandeau" hidden>
  <h2 class="gmb-cookies__titre" id="${this.idDialogue}-titre-bandeau">Vos choix sur les cookies</h2>
  <p class="gmb-cookies__texte">Ce site utilise uniquement les cookies nécessaires à son fonctionnement. Avec votre accord, nous mesurerons aussi l’audience de nos pages pour les améliorer. Vous pouvez changer d’avis à tout moment avec le lien « Gérer les cookies », en bas de chaque page.</p>
  <div class="gmb-cookies__actions">
    <button type="button" class="gmb-bouton gmb-bouton--secondaire" data-choix="refuser">Refuser tout</button>
    <button type="button" class="gmb-bouton gmb-bouton--secondaire" data-choix="personnaliser">Personnaliser</button>
    <button type="button" class="gmb-bouton gmb-bouton--secondaire" data-choix="accepter">Accepter tout</button>
  </div>
</section>

<dialog class="gmb-dialogue" aria-labelledby="${this.idDialogue}-titre">
  <form method="dialog" class="gmb-dialogue__formulaire">
    <div class="gmb-dialogue__entete">
      <h2 class="gmb-dialogue__titre" id="${this.idDialogue}-titre">Personnaliser les cookies</h2>
      <button type="button" class="gmb-icone-bouton" data-action="fermer-dialogue" aria-label="Fermer sans enregistrer">${icone('croix', { taille: 22 })}</button>
    </div>
    <div class="gmb-dialogue__corps">
      <div class="gmb-reglage">
        <div><p class="gmb-reglage__titre">Cookies nécessaires</p>
          <p class="gmb-reglage__texte">Mémorisent vos choix (bandeaux fermés, cookies). Ils ne peuvent pas être désactivés.</p></div>
        <input class="gmb-interrupteur" type="checkbox" role="switch" checked disabled aria-label="Cookies nécessaires, toujours actifs">
      </div>
      <div class="gmb-reglage">
        <div><p class="gmb-reglage__titre" id="${this.idDialogue}-mesure">Mesure d’audience</p>
          <p class="gmb-reglage__texte">Statistiques de visite anonymes pour améliorer nos pages.</p></div>
        <input class="gmb-interrupteur" type="checkbox" role="switch" name="mesure" aria-labelledby="${this.idDialogue}-mesure">
      </div>
      <div class="gmb-reglage">
        <div><p class="gmb-reglage__titre" id="${this.idDialogue}-tiers">Contenus de services tiers</p>
          <p class="gmb-reglage__texte">Vidéos et cartes intégrées, qui peuvent déposer leurs propres cookies.</p></div>
        <input class="gmb-interrupteur" type="checkbox" role="switch" name="tiers" aria-labelledby="${this.idDialogue}-tiers">
      </div>
    </div>
    <div class="gmb-dialogue__pied">
      <button type="button" class="gmb-bouton gmb-bouton--secondaire" data-choix="refuser">Tout refuser</button>
      <button type="button" class="gmb-bouton gmb-bouton--principal" data-choix="enregistrer">Enregistrer mes choix</button>
    </div>
  </form>
</dialog>`;
  }

  brancher() {
    this.addEventListener('click', (evenement) => {
      const cible = evenement.target.closest('[data-choix], [data-action], [data-langue]');
      if (!cible) return;

      if (cible.dataset.langue) {
        evenement.preventDefault();
        if (cible.dataset.langue === 'en') {
          notifier('This page is not available in English yet. You are viewing the French version.', { type: 'info' });
        }
        return;
      }

      const action = cible.dataset.action;
      if (action === 'reglages-cookies') this.ouvrirReglages();
      else if (action === 'fermer-dialogue') this.dialogue.close();

      const choix = cible.dataset.choix;
      if (choix === 'accepter') this.enregistrer({ mesure: true, tiers: true });
      else if (choix === 'refuser') this.enregistrer({ mesure: false, tiers: false });
      else if (choix === 'personnaliser') this.ouvrirReglages();
      else if (choix === 'enregistrer') {
        const formulaire = this.dialogue.querySelector('form');
        this.enregistrer({ mesure: formulaire.elements.mesure.checked, tiers: formulaire.elements.tiers.checked });
      }
    });

    document.addEventListener('gmb:cookies-reglages', () => this.ouvrirReglages());
  }

  ouvrirReglages() {
    const actuel = consentement.lire() || { mesure: false, tiers: false };
    const formulaire = this.dialogue.querySelector('form');
    formulaire.elements.mesure.checked = actuel.mesure;
    formulaire.elements.tiers.checked = actuel.tiers;
    if (!this.dialogue.open) this.dialogue.showModal();
  }

  enregistrer(choix) {
    consentement.enregistrer(choix);
    const avaitBandeau = !this.bandeau.hidden;
    this.bandeau.hidden = true;
    if (this.dialogue.open) this.dialogue.close();
    if (avaitBandeau || choix) {
      notifier('Vos choix sur les cookies sont enregistrés pour 6 mois.', { type: 'succes', duree: 4000 });
    }
  }
}

if (!customElements.get('gm-footer')) customElements.define('gm-footer', GmFooter);

/* =============================================================================
   1. DÉCORS
   ========================================================================== */
export function decorer(racine = document) {
  racine.querySelectorAll('[data-icone]').forEach((el) => {
    el.innerHTML = icone(el.dataset.icone);
  });
  racine.querySelectorAll('[data-icone-avant]').forEach((el) => {
    el.insertAdjacentHTML('afterbegin', icone(el.dataset.iconeAvant));
  });
  racine.querySelectorAll('[data-icone-onglet]').forEach((el) => {
    el.insertAdjacentHTML('afterbegin', icone(el.dataset.iconeOnglet, { taille: 18 }));
  });
  racine.querySelectorAll('[data-icones]').forEach((el) => {
    el.innerHTML = el.dataset.icones.split(' ').map((nom) => icone(nom, { taille: 16 })).join('');
  });
  racine.querySelectorAll('[data-coche]').forEach((el) => {
    el.insertAdjacentHTML('afterbegin', icone('check'));
    el.removeAttribute('data-coche');
  });
  racine.querySelectorAll('[data-lune]').forEach((el) => {
    el.innerHTML = luneSVG(Number(el.dataset.lune), { taille: Number(el.dataset.taille) || 30, classe: 'gmb-lune--halo' });
  });
  racine.querySelectorAll('[data-logo-icone]').forEach((el) => {
    el.innerHTML = logoSVG({ variante: 'icone', decoratif: true });
  });
}

/* =============================================================================
   2. CHIFFRES LIÉS AU CATALOGUE
   ========================================================================== */
export function formaterPrix(valeur) {
  return Number.isInteger(valeur) ? formaterMontant(valeur, { decimales: 0 }) : formaterMontant(valeur);
}

export function exempleCredit() {
  const { montant, duree } = CREDIT.exemple;
  const taux = grilleCredit(duree);
  const c = coutCredit(montant, taux, duree);
  return {
    montant: formaterMontant(montant, { decimales: 0 }),
    duree: `${duree} mois`,
    nombre: String(duree),
    taux: formaterTaux(taux),
    taeg: formaterTaux(c.taeg),
    mensualite: formaterMontant(c.mensualite),
    du: formaterMontant(c.montantDu),
    cout: formaterMontant(c.cout),
    frais: formaterMontant(CREDIT.fraisDossier, { decimales: 0 }),
  };
}

function valeurCatalogue(cle) {
  const [type, argument] = cle.split(':');
  const f = argument ? formule(argument) : null;
  switch (type) {
    case 'taux-livret': return f ? formaterTaux(f.tauxLivret) : null;
    case 'taux-livret-max': return formaterTaux(LIVRET.tauxMax);
    case 'prix': return f ? formaterPrix(f.prix) : null;
    case 'prix-annuel': return f ? formaterPrix(prixAnnuel(argument)) : null;
    case 'date-effet': return formaterDate(DATE_EFFET, 'court');
    case 'mention': return MENTIONS[argument] ?? null;
    case 'livret-minimum': return formaterMontant(LIVRET.versementMinimal, { decimales: 0 });
    case 'livret-plafond': return formaterMontant(LIVRET.plafond, { decimales: 0 });
    case 'credit-exemple': return exempleCredit()[argument] ?? null;
    case 'credit-minimum': return formaterMontant(CREDIT.montantMin, { decimales: 0 });
    case 'credit-maximum': return formaterMontant(CREDIT.montantMax, { decimales: 0 });
    case 'credit-retractation': return `${CREDIT.delaiRetractation} jours`;
    case 'calendrier': return CALENDRIER[argument] ?? null;
    case 'frais-change': return formaterTaux(INTERNATIONAL.fraisChange, 1);
    case 'majoration-weekend': return formaterTaux(INTERNATIONAL.majorationWeekend, 0);
    case 'frais-retrait': return `${formaterTaux(INTERNATIONAL.fraisRetrait, 0)} (minimum ${formaterMontant(INTERNATIONAL.fraisRetraitMinimum, { decimales: 0 })})`;
    case 'date-taux-change': return '…';
    case 'prix-pro': return formulePro(argument) ? `${formaterPrix(formulePro(argument).prixHT)} HT` : null;
    case 'operation-sup': return `${formaterMontant(OPERATION_SUPPLEMENTAIRE_HT)} HT`;
    case 'reforme': return FACTURATION[argument] ?? null;
    case 'facture': {
      const e = FACTURATION.exemple;
      const tva = (e.montantHT * e.tauxTVA) / 100;
      const valeurs = {
        numero: e.numero, client: e.client, ht: formaterMontant(e.montantHT), tva: formaterMontant(tva), ttc: formaterMontant(e.montantHT + tva),
        'taux-tva': formaterTaux(e.tauxTVA, 0), provision: formaterMontant((e.montantHT * FACTURATION.tauxProvision) / 100),
        'taux-provision': formaterTaux(FACTURATION.tauxProvision, 0),
      };
      return valeurs[argument] ?? null;
    }
    case 'jeunes': {
      const valeurs = {
        age: `${JEUNES.ageMin} à ${JEUNES.ageMax} ans`, 'age-min': `${JEUNES.ageMin} ans`,
        poche: formaterMontant(JEUNES.argentDePoche, { decimales: 0 }), plafond: formaterMontant(JEUNES.plafondHebdo, { decimales: 0 }),
        bloquees: JEUNES.categoriesBloquees.join(', ').toLowerCase().replace(/^./, (c) => c.toUpperCase()),
      };
      return valeurs[argument] ?? null;
    }
    case 'taux-livret-liste':
      return FORMULES.map((x) => `${x.nom} ${formaterTaux(x.tauxLivret)}`).join(' · ');
    default: return null;
  }
}

export function lierCatalogue(racine = document) {
  racine.querySelectorAll('[data-catalogue]').forEach((el) => {
    const valeur = valeurCatalogue(el.dataset.catalogue);
    if (valeur != null) el.textContent = valeur;
  });
}

/* =============================================================================
   3. CARTES DE FORMULES
   data-formules : liste (accueil) ; data-formules="tarifs" : avec prix annuel
   ========================================================================== */
const lienFormule = (code) => lienOuverture({ formule: code }).replace(/&/g, '&amp;');

function carteFormule(f, { periode = 'mois' } = {}) {
  const annuel = periode === 'an';
  const prix = annuel ? prixAnnuel(f.code) : f.prix;
  const equivalent = annuel && f.prix > 0
    ? `<p class="gmb-formule__equivalent">soit ${formaterMontant(prix / 12)} par mois, deux mois offerts</p>` : '';
  const misEnAvant = Boolean(f.badge);
  return `<article class="gmb-formule${misEnAvant ? ' gmb-formule--mise-en-avant' : ''}" data-formule="${f.code}">
    <div class="gmb-formule__entete"><h3 class="gmb-formule__nom">${f.nom}</h3>${misEnAvant ? `<span class="gmb-badge gmb-badge--marque">${f.badge}</span>` : ''}</div>
    <p class="gmb-formule__prix gmb-montant">${formaterPrix(prix)}<span class="gmb-formule__periode"> par ${annuel ? 'an' : 'mois'}</span></p>
    ${equivalent}
    <p class="gmb-formule__resume">${f.accroche}</p>
    <ul class="gmb-formule__liste">${f.points.map((p) => `<li>${icone('check')}<span>${p}</span></li>`).join('')}</ul>
    <a class="gmb-bouton ${misEnAvant ? 'gmb-bouton--principal' : 'gmb-bouton--secondaire'} gmb-bouton--bloc" href="${lienFormule(f.code)}">Choisir ${f.nom}</a>
  </article>`;
}

function rendreFormules(conteneur) {
  const periode = conteneur.dataset.periode || 'mois';
  conteneur.innerHTML = FORMULES.map((f) => carteFormule(f, { periode })).join('');
}

/* =============================================================================
   4. COMPARATIF DES TARIFS (VIT-17)
   ========================================================================== */
function celluleValeur(valeur) {
  if (valeur === true) return `<td class="gmb-comparatif__oui">${icone('check', { titre: 'Inclus' })}</td>`;
  if (valeur === false) return '<td class="gmb-comparatif__non"><span aria-hidden="true">—</span><span class="gmb-visuellement-masque">Non inclus</span></td>';
  return `<td>${echapperHtml(valeur)}</td>`;
}

function rendreComparatif(conteneur) {
  const entete = `<thead><tr><th scope="col"><span class="gmb-visuellement-masque">Service</span></th>${FORMULES.map((f) => `<th scope="col">${f.nom}<span class="gmb-comparatif__prix" data-prix-entete="${f.code}">${formaterPrix(f.prix)} par mois</span></th>`).join('')}</tr></thead>`;
  const corps = COMPARATIF.map((groupe) => `<tbody>
      <tr class="gmb-comparatif__groupe"><th scope="colgroup" colspan="${FORMULES.length + 1}">${groupe.groupe}</th></tr>
      ${groupe.lignes.map((ligne) => `<tr><th scope="row">${ligne.libelle}</th>${ligne.valeurs.map(celluleValeur).join('')}</tr>`).join('')}
    </tbody>`).join('');
  conteneur.innerHTML = `<table class="gmb-comparatif"><caption class="gmb-visuellement-masque">Comparatif détaillé des cinq formules Particuliers</caption>${entete}${corps}</table>`;
}

function rendreFrais(conteneur) {
  conteneur.innerHTML = FRAIS_HORS_FORMULE.map((frais) => `<div class="gmb-frais__ligne"><dt>${frais.libelle}</dt><dd>${frais.valeur}</dd></div>`).join('');
}

function brancherTarifs(racine) {
  const formules = racine.querySelector('[data-formules]');
  const choix = racine.querySelectorAll('input[name="periode"]');
  const appliquer = () => {
    const periode = racine.querySelector('input[name="periode"]:checked')?.value || 'mois';
    if (formules) {
      formules.dataset.periode = periode;
      rendreFormules(formules);
    }
    const annonce = racine.querySelector('[data-annonce-periode]');
    if (annonce && appliquer.dejaFait) annonce.textContent = periode === 'an' ? 'Prix affichés par an, deux mois offerts.' : 'Prix affichés par mois.';
    appliquer.dejaFait = true;
    document.querySelectorAll('[data-prix-entete]').forEach((el) => {
      const code = el.dataset.prixEntete;
      el.textContent = periode === 'an' ? `${formaterPrix(prixAnnuel(code))} par an` : `${formaterPrix(formule(code).prix)} par mois`;
    });
  };
  choix.forEach((radio) => radio.addEventListener('change', appliquer));
  appliquer();
}

/* =============================================================================
   4 bis. TABLEAU DES TAUX DU LIVRET ET GALERIE DES CARTES
   ========================================================================== */
function rendreTableauLivret(conteneur) {
  const montant = Number(conteneur.dataset.montant) || 10000;
  conteneur.tabIndex = 0;
  conteneur.setAttribute('role', 'region');
  conteneur.setAttribute('aria-label', 'Taux du Livret GMB par formule');
  conteneur.innerHTML = `<table class="gmb-tableau">
    <caption class="gmb-visuellement-masque">Taux du Livret GMB par formule et intérêts bruts pour ${formaterMontant(montant, { decimales: 0 })} placés un an</caption>
    <thead><tr><th scope="col">Formule</th><th scope="col">Prix par mois</th><th scope="col" class="gmb-nombre">Taux annuel brut</th><th scope="col" class="gmb-nombre">Intérêts sur un an pour ${formaterMontant(montant, { decimales: 0 })}</th></tr></thead>
    <tbody>${FORMULES.map((f) => `<tr${f.code === 'zenith' ? ' data-mis-en-avant' : ''}><th scope="row">${f.nom}</th><td>${formaterPrix(f.prix)}</td><td class="gmb-nombre">${formaterTaux(f.tauxLivret)}</td><td class="gmb-nombre">${formaterMontant(interetsLivret(montant, f.tauxLivret).parAn)}</td></tr>`).join('')}</tbody>
  </table>`;
}

const VISUELS_CARTE = { nuit: 'gmb-carte-bancaire--nuit', marque: '', metal: 'gmb-carte-bancaire--metal' };

function rendreGalerieCartes(conteneur) {
  conteneur.innerHTML = FORMULES.map((f) => `<figure>
    <div class="gmb-carte-bancaire ${VISUELS_CARTE[f.carteVisuel] || ''}" aria-hidden="true">
      <div class="gmb-carte-bancaire__haut"><span class="gmb-carte-bancaire__logo">${logoSVG({ variante: 'icone', decoratif: true })}</span><span class="gmb-carte-bancaire__formule">${f.nom.toUpperCase()}</span></div>
      <div class="gmb-carte-bancaire__bas"><span class="gmb-carte-bancaire__puce"></span><span class="gmb-carte-bancaire__numero">•••• ${['5570', '0193', '2741', '8826', '4410'][FORMULES.indexOf(f)]}</span></div>
    </div>
    <figcaption><strong>${f.nom}</strong>Carte ${f.carte.toLowerCase()} · ${formaterPrix(f.prix)} par mois</figcaption>
  </figure>`).join('');
}

/* =============================================================================
   4 ter. INTERNATIONAL ET ASSURANCES (VIT-14, VIT-16)
   ========================================================================== */
function zoneTableau(conteneur, libelle) {
  conteneur.tabIndex = 0;
  conteneur.setAttribute('role', 'region');
  conteneur.setAttribute('aria-label', libelle);
}

function rendreTableauFranchises(conteneur) {
  zoneTableau(conteneur, 'Franchises à l’étranger par formule');
  conteneur.innerHTML = `<table class="gmb-tableau">
    <caption class="gmb-visuellement-masque">Franchises incluses chaque mois, par formule</caption>
    <thead><tr><th scope="col">Formule</th><th scope="col" class="gmb-nombre">Retraits hors zone euro inclus</th><th scope="col" class="gmb-nombre">Change sans frais</th></tr></thead>
    <tbody>${FORMULES.map((f) => `<tr><th scope="row">${f.nom} <span class="gmb-comparatif__prix" style="display:inline">${formaterPrix(f.prix)} par mois</span></th>
      <td class="gmb-nombre">${formaterMontant(f.retraitsHorsZone, { decimales: 0 })} par mois</td>
      <td class="gmb-nombre">${f.changeSansFrais ? `${formaterMontant(f.changeSansFrais, { decimales: 0 })} par mois` : 'Illimité en jours ouvrés'}</td></tr>`).join('')}</tbody>
  </table>`;
}

function rendreTableauRetrait(conteneur) {
  const montant = Number(conteneur.dataset.montant) || 300;
  zoneTableau(conteneur, `Exemple de retrait de ${montant} euros selon la formule`);
  conteneur.innerHTML = `<table class="gmb-tableau">
    <caption class="gmb-visuellement-masque">Frais pour un retrait de ${formaterMontant(montant, { decimales: 0 })} hors zone euro, en début de mois</caption>
    <thead><tr><th scope="col">Formule</th><th scope="col" class="gmb-nombre">Inclus dans la franchise</th><th scope="col" class="gmb-nombre">Au-delà</th><th scope="col" class="gmb-nombre">Frais</th></tr></thead>
    <tbody>${FORMULES.map((f) => {
      const r = fraisRetrait(montant, f.code);
      return `<tr><th scope="row">${f.nom}</th><td class="gmb-nombre">${formaterMontant(r.dansFranchise)}</td><td class="gmb-nombre">${formaterMontant(r.horsFranchise)}</td><td class="gmb-nombre">${formaterMontant(r.frais)}</td></tr>`;
    }).join('')}</tbody>
  </table>`;
}

function rendreTableauAssurances(conteneur) {
  const groupe = COMPARATIF.find((g) => g.groupe === 'Assurances incluses');
  zoneTableau(conteneur, 'Garanties incluses par formule');
  conteneur.innerHTML = `<table class="gmb-tableau gmb-tableau--centre">
    <caption class="gmb-visuellement-masque">Garanties d’assurance incluses dans chaque formule</caption>
    <thead><tr><th scope="col">Garantie</th>${FORMULES.map((f) => `<th scope="col">${f.nom}</th>`).join('')}</tr></thead>
    <tbody>${groupe.lignes.map((ligne) => `<tr><th scope="row">${ligne.libelle}</th>${ligne.valeurs.map((v) => (v
      ? `<td class="gmb-comparatif__oui">${icone('check', { titre: 'Incluse' })}</td>`
      : '<td class="gmb-comparatif__non"><span aria-hidden="true">—</span><span class="gmb-visuellement-masque">Non incluse</span></td>')).join('')}</tr>`).join('')}</tbody>
  </table>`;
}

/* =============================================================================
   4 quater. PRO, BUSINESS ET JEUNES (VIT-20 à VIT-23, VIT-30)
   ========================================================================== */
function carteFormulePro(f) {
  const misEnAvant = Boolean(f.badge);
  const lien = lienOuverture({ segment: f.segment, formule: f.code }).replace(/&/g, '&amp;');
  return `<article class="gmb-formule${misEnAvant ? ' gmb-formule--mise-en-avant' : ''}" data-formule="${f.code}">
    <div class="gmb-formule__entete"><h3 class="gmb-formule__nom">${f.nom}</h3>${misEnAvant ? `<span class="gmb-badge gmb-badge--marque">${f.badge}</span>` : ''}</div>
    <p class="gmb-formule__prix gmb-montant">${formaterPrix(f.prixHT)}<span class="gmb-formule__periode"> HT par mois</span></p>
    <p class="gmb-formule__resume">${f.accroche}</p>
    <ul class="gmb-formule__liste">
      <li>${icone('utilisateur')}<span>${f.utilisateursLibelle} utilisateur${f.utilisateurs > 1 ? 's' : ''}</span></li>
      <li>${icone('carte')}<span>${f.cartesPhysiques} carte${f.cartesPhysiques > 1 ? 's' : ''} physique${f.cartesPhysiques > 1 ? 's' : ''}, ${f.cartesVirtuelles ? `${f.cartesVirtuelles} virtuelles` : 'virtuelles illimitées'}</span></li>
      <li>${icone('virement')}<span>${formaterNombre(f.operationsIncluses)} opérations SEPA par mois</span></li>
      ${f.fonctions.map((x) => `<li>${icone('check')}<span>${x}</span></li>`).join('')}
    </ul>
    <a class="gmb-bouton ${misEnAvant ? 'gmb-bouton--principal' : 'gmb-bouton--secondaire'} gmb-bouton--bloc" href="${lien}">Choisir ${f.nom}</a>
  </article>`;
}

function rendreFormulesPro(conteneur) {
  const segment = conteneur.dataset.formulesPro;
  const liste = FORMULES_PRO.filter((f) => !segment || segment === 'tous' || f.segment === segment);
  conteneur.innerHTML = liste.map(carteFormulePro).join('');
}

function rendreComparatifPro(conteneur) {
  const lignes = [
    ['Prix HT par mois', (f) => formaterPrix(f.prixHT)],
    ['Utilisateurs', (f) => f.utilisateursLibelle],
    ['Cartes physiques', (f) => String(f.cartesPhysiques)],
    ['Cartes virtuelles', (f) => (f.cartesVirtuelles ? String(f.cartesVirtuelles) : 'Illimitées')],
    ['Opérations SEPA incluses par mois', (f) => formaterNombre(f.operationsIncluses)],
    ['Opération au-delà du forfait', () => `${formaterMontant(OPERATION_SUPPLEMENTAIRE_HT)} HT`],
    ['Fonctions clés', (f) => f.fonctions.join(', ')],
  ];
  conteneur.innerHTML = `<table class="gmb-comparatif"><caption class="gmb-visuellement-masque">Comparatif des cinq formules Pro et Business</caption>
    <thead><tr><th scope="col"><span class="gmb-visuellement-masque">Élément</span></th>${FORMULES_PRO.map((f) => `<th scope="col">${f.nom}</th>`).join('')}</tr></thead>
    <tbody>${lignes.map(([libelle, valeur]) => `<tr><th scope="row">${libelle}</th>${FORMULES_PRO.map((f) => `<td>${echapperHtml(valeur(f))}</td>`).join('')}</tr>`).join('')}</tbody>
  </table>`;
}

function rendreControlesJeunes(conteneur) {
  conteneur.tabIndex = 0;
  conteneur.setAttribute('role', 'region');
  conteneur.setAttribute('aria-label', 'Contrôles parentaux');
  conteneur.innerHTML = `<table class="gmb-tableau"><caption class="gmb-visuellement-masque">Contrôles du parent, réglage par défaut et plage de réglage</caption>
    <thead><tr><th scope="col">Contrôle</th><th scope="col">Par défaut</th><th scope="col">Réglage possible</th></tr></thead>
    <tbody>${JEUNES.controles.map((c) => `<tr><th scope="row">${c.controle}</th><td>${c.defaut}</td><td>${c.plage}</td></tr>`).join('')}</tbody></table>`;
}

/** Échéances : « En vigueur » si la date est passée, « À venir » sinon. */
function majEcheances(racine = document) {
  const aujourdHui = new Date().toISOString().slice(0, 10);
  racine.querySelectorAll('[data-echeance]').forEach((el) => {
    const passee = el.dataset.echeance <= aujourdHui;
    el.textContent = passee ? 'En vigueur' : 'À venir';
    el.className = `gmb-badge ${passee ? 'gmb-badge--succes' : 'gmb-badge--alerte'}`;
  });
}

/* =============================================================================
   4 quinquies. CENTRE D'AIDE, COOKIES, ÉTAT DES SERVICES (VIT-42, VIT-44, VIT-45)
   ========================================================================== */
/* =============================================================================
   5. SIMULATEUR DU LIVRET (VIT-01, VIT-11)
   Intérêts jour par jour, base 365 jours, bruts, hors capitalisation.
   ========================================================================== */
/* =============================================================================
   6. SIMULATEUR DE PRÊT PERSONNEL (VIT-15)
   Recalcul instantané, arrondi au centime, TAEG mis en évidence.
   ========================================================================== */
/* =============================================================================
   DÉMARRAGE
   ========================================================================== */

/* =============================================================================
   DOCUMENTS TARIFAIRES (brochure, document d’information tarifaire)
   ========================================================================== */
const e = (t) => echapperHtml(String(t ?? ''));
const prix = (v, options) => (v ? formaterMontant(v, options) : '0 €');
const cellule = (v) => (v === true ? 'Inclus' : v === false || v === null || v === undefined ? '—' : e(v));
const DATE = formaterDate(`${DATE_EFFET}T12:00:00`, 'long');
let compteur = 0;

function tableau(titre, entetes, lignes) {
  compteur += 1;
  const id = `doc-tableau-${compteur}`;
  return `<div class="gmb-tableau-zone" tabindex="0" role="region" aria-labelledby="${id}">
    <table class="gmb-tableau"><caption id="${id}">${e(titre)}</caption>
      <thead><tr>${entetes.map((t, i) => `<th scope="col"${i ? ' class="gmb-nombre"' : ''}>${e(t)}</th>`).join('')}</tr></thead>
      <tbody>${lignes.map(([libelle, ...valeurs]) => `<tr><th scope="row">${e(libelle)}</th>${valeurs.map((v) => `<td class="gmb-nombre">${v}</td>`).join('')}</tr>`).join('')}</tbody>
    </table></div>`;
}

function section(titre, contenu, id) {
  return `<section class="gmb-pile gmb-pile--moyenne doc-section" aria-labelledby="${id}"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="${id}">${e(titre)}</h2>${contenu}</section>`;
}

const fraisHorsFormule = (motif) => FRAIS_HORS_FORMULE.find((x) => motif.test(x.libelle))?.valeur || '—';
const valeurComparatif = (libelle, code) => {
  const index = FORMULES.findIndex((f) => f.code === code);
  for (const g of COMPARATIF) {
    const ligne = g.lignes.find((l) => l.libelle === libelle);
    if (ligne) return ligne.valeurs[index];
  }
  return undefined;
};

/* -----------------------------------------------------------------------------
   Brochure tarifaire : toutes les conditions et tous les frais
   -------------------------------------------------------------------------- */
function brochure() {
  const noms = FORMULES.map((f) => f.nom);
  const parties = [];
  parties.push(section('Formules Particuliers', tableau('Prix des formules, toutes taxes comprises', ['Formule', 'Par mois', 'Par an'],
    FORMULES.map((f) => [f.nom, prix(f.prix), prix(prixAnnuel(f.code))])), 'b-formules'));
  parties.push(section('Contenu des formules', COMPARATIF.map((g) => tableau(g.groupe, ['', ...noms],
    g.lignes.map((l) => [l.libelle, ...l.valeurs.map(cellule)]))).join(''), 'b-contenu'));
  parties.push(section('Frais hors formule', tableau('Frais appliqués au-delà des services inclus', ['Service', 'Prix'],
    FRAIS_HORS_FORMULE.map((x) => [x.libelle, e(x.valeur)])), 'b-frais'));
  parties.push(section('Livret GMB', `${tableau('Taux annuel brut selon la formule', ['Formule', 'Taux annuel brut'],
    FORMULES.map((f) => [f.nom, f.tauxLivret ? formaterTaux(f.tauxLivret) : '—']))}
    <p>Versement minimal : ${prix(LIVRET.versementMinimal)}. Plafond : ${prix(LIVRET.plafond, { decimales: 0 })}. Intérêts calculés chaque jour sur ${LIVRET.baseJours} jours.</p>
    <p class="gmb-mention">${e(MENTIONS.fiscaliteLivret)}</p>`, 'b-livret'));
  parties.push(section('International et change', `${tableau('Franchises mensuelles selon la formule', ['Formule', 'Retraits hors zone euro', 'Change sans frais'],
    FORMULES.map((f) => [f.nom, f.retraitsHorsZone ? prix(f.retraitsHorsZone, { decimales: 0 }) : '—', f.changeSansFrais === null ? 'Sans limite' : f.changeSansFrais ? prix(f.changeSansFrais, { decimales: 0 }) : '—']))}
    <p>Au-delà des franchises : retrait hors zone euro ${formaterTaux(INTERNATIONAL.fraisRetrait, 0)} du montant (minimum ${prix(INTERNATIONAL.fraisRetraitMinimum)}) ; change ${formaterTaux(INTERNATIONAL.fraisChange, 1)} du montant ; majoration de ${formaterTaux(INTERNATIONAL.majorationWeekend, 0)} le week-end, marchés fermés. Taux de référence : celui publié par la Banque centrale européenne.</p>`, 'b-international'));
  const objet = (code) => CREDIT.objets.find((o) => o.code === code)?.libelle || 'Tous projets';
  parties.push(section('Prêt personnel', `${tableau('Taux débiteurs fixes', ['Durée', 'Objet', 'Taux débiteur fixe'],
    CREDIT.grille.map((g) => [`De ${g.dureeMin} à ${g.dureeMax} mois`, e(g.objet === 'tous' ? 'Tous projets' : objet(g.objet)), formaterTaux(g.tauxDebiteur)]))}
    <p>Montant de ${prix(CREDIT.montantMin, { decimales: 0 })} à ${prix(CREDIT.montantMax, { decimales: 0 })}, sur ${CREDIT.dureeMin} à ${CREDIT.dureeMax} mois. Frais de dossier : 0 €. Assurance emprunteur facultative.</p>
    <p class="gmb-mention-obligatoire">${e(MENTIONS.credit)}</p>`, 'b-credit'));
  parties.push(section('Formules Pro et Business', `${tableau('Prix hors taxes', ['Formule', 'Par mois HT', 'Utilisateurs', 'Opérations incluses'],
    FORMULES_PRO.map((f) => [f.nom, prix(f.prixHT), e(f.utilisateursLibelle), e(new Intl.NumberFormat('fr-FR').format(f.operationsIncluses))]))}
    <p>Opération SEPA au-delà des opérations incluses : ${prix(OPERATION_SUPPLEMENTAIRE_HT)} HT.</p>`, 'b-pro'));
  parties.push(section('Garantie des dépôts', `<p>${e(MENTIONS.garantieDepots)}</p>`, 'b-garantie'));
  return parties.join('');
}

/* -----------------------------------------------------------------------------
   Document d'information tarifaire (format européen) : une formule à la fois
   -------------------------------------------------------------------------- */
function dit(code) {
  const f = formule(code) || FORMULES[0];
  const decouvert = valeurComparatif('Découvert autorisé', f.code) ?? 'Non proposé';
  const inclus = COMPARATIF.flatMap((g) => g.lignes.map((l) => ({ libelle: l.libelle, valeur: l.valeurs[FORMULES.indexOf(f)] })))
    .filter((x) => x.valeur && x.valeur !== '—' && !/^non/i.test(String(x.valeur)));
  const ligne = (service, frais) => `<tr><th scope="row">${e(service)}</th><td class="gmb-nombre">${frais}</td></tr>`;
  const bloc = (titre, lignes) => `<tr class="doc-dit__groupe"><th scope="rowgroup" colspan="2">${e(titre)}</th></tr>${lignes.join('')}`;
  return `<header class="gmb-pile gmb-pile--serree">
      <p><strong>Nom du prestataire du compte :</strong> GerMoonBank, service édité par The Hub of Inspiration of Soccer (HubISoccer)</p>
      <p><strong>Nom du compte :</strong> Compte courant, formule ${e(f.nom)}</p>
      <p><strong>Date :</strong> ${e(DATE)}</p>
    </header>
    <ul class="gmb-coches gmb-coches--colonne">
      <li><span>${icone('info')}</span><span>Le présent document vous informe des frais liés à l’utilisation des principaux services liés au compte de paiement. Il vous aidera à comparer ces frais avec ceux d’autres comptes.</span></li>
      <li><span>${icone('info')}</span><span>Des frais peuvent également s’appliquer pour l’utilisation de services liés au compte qui ne sont pas mentionnés ici. Vous trouverez toutes les informations dans la <a href="${chemin('public/tarifs/grille-tarifaire.html')}">brochure tarifaire</a>.</span></li>
    </ul>
    <div class="gmb-tableau-zone" tabindex="0" role="region" aria-labelledby="dit-titre-tableau">
      <table class="gmb-tableau doc-dit"><caption id="dit-titre-tableau">Frais de la formule ${e(f.nom)}</caption>
        <thead><tr><th scope="col">Service</th><th scope="col">Frais</th></tr></thead>
        <tbody>
          ${bloc('Services généraux liés au compte', [
            ligne('Tenue du compte', `${prix(f.prix)} par mois`),
            ligne('Frais annuels totaux de tenue du compte', prix(Math.round(f.prix * 12 * 100) / 100)),
            ...(f.prix ? [ligne('Option de paiement annuel', `${prix(prixAnnuel(f.code))} par an`)] : []),
          ])}
          ${bloc('Paiements (à l’exclusion des cartes)', [
            ligne('Virement SEPA, y compris instantané', e(fraisHorsFormule(/^Virement SEPA/))),
          ])}
          ${bloc('Cartes et espèces', [
            ligne('Fourniture d’une carte de débit', `${e(f.carte)}, incluse dans la formule`),
            ligne('Retrait d’espèces hors zone euro', f.retraitsHorsZone ? `Gratuit jusqu’à ${prix(f.retraitsHorsZone, { decimales: 0 })} par mois, puis ${e(fraisHorsFormule(/^Retrait/))}` : e(fraisHorsFormule(/^Retrait/))),
            ligne('Paiement par carte dans une autre devise', f.changeSansFrais === null ? 'Sans frais de change' : f.changeSansFrais ? `Sans frais jusqu’à ${prix(f.changeSansFrais, { decimales: 0 })} par mois, puis ${e(fraisHorsFormule(/^Opération de change/))}` : e(fraisHorsFormule(/^Opération de change/))),
          ])}
          ${bloc('Découvert et services connexes', [ligne('Découvert autorisé', cellule(decouvert))])}
        </tbody>
      </table>
    </div>
    <section class="gmb-pile gmb-pile--serree" aria-labelledby="dit-groupes">
      <h2 class="gmb-section__titre gmb-section__titre--moyen" id="dit-groupes">Informations sur les services groupés</h2>
      <p>La formule ${e(f.nom)} (${prix(f.prix)} par mois) comprend :</p>
      <ul class="gmb-coches gmb-coches--colonne">${inclus.map((x) => `<li><span>${icone('check')}</span><span>${e(x.libelle)}${x.valeur === true ? '' : ` : ${e(x.valeur)}`}</span></li>`).join('')}</ul>
    </section>`;
}

/* -----------------------------------------------------------------------------
   Démarrage
   -------------------------------------------------------------------------- */
function demarrerDocuments() {
  const zone = document.querySelector('[data-document]');
  if (zone?.dataset.document === 'brochure') {
    zone.innerHTML = brochure();
  } else if (zone?.dataset.document === 'dit') {
    const choix = document.querySelector('[data-choix-formule]');
    choix.innerHTML = FORMULES.map((f) => `<option value="${f.code}">${e(f.nom)} · ${prix(f.prix)} par mois</option>`).join('');
    const parametre = new URLSearchParams(location.search).get('formule');
    if (FORMULES.some((f) => f.code === parametre)) choix.value = parametre;
    const rendre = () => {
      zone.innerHTML = dit(choix.value);
      history.replaceState(null, '', `?formule=${choix.value}`);
    };
    choix.addEventListener('change', rendre);
    rendre();
  }
  document.querySelectorAll('[data-imprimer]').forEach((b) => b.addEventListener('click', () => window.print()));
  document.querySelectorAll('[data-date-effet]').forEach((el) => { el.textContent = DATE; });
}

/* =============================================================================
   DÉMARRAGE DE LA PAGE
   ========================================================================== */
function demarrerPage() {
  decorer();
  lierCatalogue();
  document.querySelectorAll('[data-formules]').forEach(rendreFormules);
  document.querySelectorAll('[data-comparatif]').forEach(rendreComparatif);
  document.querySelectorAll('[data-frais]').forEach(rendreFrais);
  document.querySelectorAll('[data-tableau-livret]').forEach(rendreTableauLivret);
  document.querySelectorAll('[data-galerie-cartes]').forEach(rendreGalerieCartes);
  document.querySelectorAll('[data-tableau-franchises]').forEach(rendreTableauFranchises);
  document.querySelectorAll('[data-tableau-retrait]').forEach(rendreTableauRetrait);
  document.querySelectorAll('[data-tableau-assurances]').forEach(rendreTableauAssurances);
  document.querySelectorAll('[data-formules-pro]').forEach(rendreFormulesPro);
  document.querySelectorAll('[data-comparatif-pro]').forEach(rendreComparatifPro);
  document.querySelectorAll('[data-tableau-controles-jeunes]').forEach(rendreControlesJeunes);
  document.querySelectorAll('[data-tarifs]').forEach(brancherTarifs);
  majEcheances();
  document.querySelectorAll('[data-reglages-cookies]').forEach((b) => b.addEventListener('click', () => consentement.ouvrirReglages()));
  document.querySelectorAll('[data-nombre]').forEach((el) => {
    el.textContent = formaterNombre(Number(el.dataset.nombre));
  });
  demarrerDocuments();
}

/* Mode hors ligne : le service worker garde une copie des pages et des ressources */
function enregistrerServiceWorker() {
  const local = ['localhost', '127.0.0.1'].includes(location.hostname);
  if (!('serviceWorker' in navigator) || (location.protocol !== 'https:' && !local)) return;
  navigator.serviceWorker.register(chemin('sw.js'), { scope: chemin('') }).catch(() => {});
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrerPage, { once: true });
else demarrerPage();
enregistrerServiceWorker();

/* =============================================================================
   EN-TÊTE ET PIED DU TUNNEL <gm-entete-souscription> <gm-pied-souscription>
   Ouverture de compte, demande de prêt et Espace Mon Dossier.
   ========================================================================== */
class GmEnteteSouscription extends HTMLElement {
  connectedCallback() {
    if (this.dataset.pret) return;
    this.dataset.pret = '1';
    this.innerHTML = `<header class="gmb-entete-tunnel">
      <div class="gmb-conteneur gmb-entete-tunnel__barre">
        <a class="gmb-entete-tunnel__logo" href="${chemin('')}" aria-label="GerMoonBank, accueil">${logoSVG({ decoratif: true })}</a>
        <div class="gmb-rangee gmb-rangee--serree">
          <a class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" href="${chemin('public/aide/index.html')}">Aide</a>
          <button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-action="quitter" hidden>Enregistrer et quitter</button>
        </div>
      </div>
    </header>`;
    const bouton = this.querySelector('[data-action="quitter"]');
    clientDonnees().then((c) => c.auth.getSession()).then(({ data }) => { if (data?.session) bouton.hidden = false; }).catch(() => {});
    bouton.addEventListener('click', async () => {
      try { await (await clientDonnees()).auth.signOut({ scope: 'local' }); } catch { /* déconnexion locale malgré tout */ }
      location.href = chemin('public/inscription/index.html?raison=enregistre');
    });
  }
}
class GmPiedSouscription extends HTMLElement {
  connectedCallback() {
    if (this.dataset.pret) return;
    this.dataset.pret = '1';
    this.innerHTML = `<footer class="gmb-pied-tunnel"><div class="gmb-conteneur gmb-pile gmb-pile--serree">
      <p><strong>Statut.</strong> GerMoonBank n’est pas un établissement agréé par l’ACPR : les sommes versées ne bénéficient pas de la garantie des dépôts (FGDR).</p>
      <p>GerMoonBank est édité par The Hub of Inspiration of Soccer (HubISoccer), RCCM RB/ABC/24 A 111814, Bénin. Vos données sont hébergées dans l’Union européenne.</p>
      <p><a href="${chemin('public/legal/cgu.html')}">Conditions générales</a> · <a href="${chemin('public/legal/rgpd.html')}">Confidentialité</a> · <a href="${chemin('public/legal/mentions-legales.html')}">Mentions légales</a></p>
    </div></footer>`;
  }
}
if (!customElements.get('gm-entete-souscription')) customElements.define('gm-entete-souscription', GmEnteteSouscription);
if (!customElements.get('gm-pied-souscription')) customElements.define('gm-pied-souscription', GmPiedSouscription);
