/* =============================================================================
   GerMoonBank (GMB) · js/animations.js
   Animations discrètes — version 3
   -----------------------------------------------------------------------------
   - [data-animer] : glissement léger à l'entrée dans l'écran. Le contenu reste
     toujours visible et lisible : seule sa position varie, jamais son opacité.
   - [data-compteur-anime="12480.36"] : nombre qui monte jusqu'à sa valeur à
     l'entrée dans l'écran (data-format="montant" pour un montant en euros,
     data-format="taux" pour un pourcentage). Le texte initial est la valeur
     finale : sans JavaScript, la bonne valeur s'affiche.
   - [data-animation-continue] : animation CSS (lune, halo) mise en pause hors
     de l'écran, pour économiser la batterie.
   Rien ne bouge si la personne a demandé à réduire les animations.
   ========================================================================== */

import { mouvementReduit, formaterMontant, formaterNombre, formaterTaux } from './core.js';

const reduit = () => (typeof mouvementReduit === 'function' ? mouvementReduit() : Boolean(mouvementReduit));

function formater(valeur, format, decimales) {
  if (format === 'montant') return formaterMontant(valeur, { decimales });
  if (format === 'taux') return formaterTaux(valeur, decimales);
  return formaterNombre(valeur, decimales);
}

function animerCompteur(element) {
  const cible = Number(element.dataset.compteurAnime);
  if (!Number.isFinite(cible)) return;
  const format = element.dataset.format || 'nombre';
  const decimales = Number(element.dataset.decimales ?? (format === 'nombre' ? 0 : 2));
  const final = formater(cible, format, decimales);
  if (reduit()) {
    element.textContent = final;
    return;
  }
  const duree = 900;
  const debut = performance.now();
  const etape = (maintenant) => {
    const t = Math.min(1, (maintenant - debut) / duree);
    const facteur = 1 - (1 - t) ** 3;
    element.textContent = t < 1 ? formater(cible * facteur, format, decimales) : final;
    if (t < 1) requestAnimationFrame(etape);
  };
  element.setAttribute('aria-label', final); // les lecteurs d'écran lisent directement la valeur finale
  requestAnimationFrame(etape);
}

function demarrerAnimations() {
  const elements = [...document.querySelectorAll('[data-animer], [data-compteur-anime], [data-animation-continue]')];
  if (!elements.length) return;
  if (!('IntersectionObserver' in window)) return;
  document.documentElement.classList.toggle('gmb-animations-actives', !reduit());

  const observateur = new IntersectionObserver((entrees) => {
    entrees.forEach(({ target, isIntersecting }) => {
      if (target.hasAttribute('data-animation-continue')) {
        target.classList.toggle('gmb-anime-pause', !isIntersecting);
        return;
      }
      if (!isIntersecting) return;
      if (target.hasAttribute('data-animer')) target.classList.add('est-visible');
      if (target.hasAttribute('data-compteur-anime')) animerCompteur(target);
      observateur.unobserve(target);
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.1 });

  elements.forEach((el) => observateur.observe(el));
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrerAnimations, { once: true });
else demarrerAnimations();
