/* =============================================================================
   GerMoonBank (GMB) · js/charts.js
   Graphiques : état des services et disponibilité sur 90 jours — version 3
   -----------------------------------------------------------------------------
   Lit en direct l'état des services et les incidents (tables statut_services
   et incidents, par js/donnees.js) et dessine les barres de disponibilité. En
   cas d'échec de lecture, un message honnête remplace toute donnée.
   ========================================================================== */

import {
  echapperHtml, formaterDateRelative, icone,
} from './core.js';
import {
  avecDelai, lire,
} from './donnees.js';

const ETATS_SERVICE = {
  operationnel: { libelle: 'Opérationnel', badge: 'gmb-badge--succes' },
  degrade: { libelle: 'Dégradé', badge: 'gmb-badge--alerte' },
  panne: { libelle: 'Panne', badge: 'gmb-badge--danger' },
  maintenance: { libelle: 'Maintenance', badge: 'gmb-badge--info' },
};

async function rendreEtatServices(bloc) {
  const liste = bloc.querySelector('[data-etat-liste]');
  const global = bloc.querySelector('[data-etat-global]');
  const zoneIncidents = bloc.querySelector('[data-etat-incidents]');
  const historique = bloc.querySelector('[data-etat-historique]');
  const source = bloc.querySelector('[data-etat-source]');
  let services = [];
  let incidents = [];
  try {
    [services, incidents] = await avecDelai(Promise.all([
      lire('statut_services', { colonnes: 'service, libelle, etat, message, maj_le', ordre: 'libelle', croissant: true }),
      lire('incidents', { colonnes: 'titre, description, classification, services, detecte_le, statut, resolu_le', ordre: 'detecte_le', limite: 50 }),
    ]));
  } catch {
    // Lecture impossible : aucune donnée inventée, un message honnête
    liste.innerHTML = '';
    zoneIncidents.innerHTML = '';
    historique.innerHTML = '';
    global.className = 'gmb-encadre gmb-encadre--neutre';
    global.innerHTML = `${icone('info')}<p><strong>État des services momentanément indisponible.</strong> Réessayez dans un instant.</p>`;
    source.textContent = '';
    return;
  }
  if (!services.length) {
    global.className = 'gmb-encadre gmb-encadre--neutre';
    global.innerHTML = `${icone('info')}<p><strong>Aucun service n’est encore suivi.</strong></p>`;
  }
  liste.innerHTML = services.map((s) => {
    const e = ETATS_SERVICE[s.etat] || ETATS_SERVICE.operationnel;
    return `<li><span class="gmb-etat-liste__nom">${echapperHtml(s.libelle)}${s.message ? `<span class="gmb-etat-liste__message">${echapperHtml(s.message)}</span>` : ''}</span><span class="gmb-badge ${e.badge}">${e.libelle}</span></li>`;
  }).join('');
  const enCours = incidents.filter((x) => ['ouvert', 'en_cours'].includes(x.statut));
  const touche = services.filter((s) => s.etat !== 'operationnel');
  if (services.length) global.className = `gmb-encadre ${touche.length || enCours.length ? 'gmb-encadre--alerte' : 'gmb-encadre--succes'}`;
  if (services.length) global.innerHTML = `${icone(touche.length || enCours.length ? 'alerte' : 'check')}<p><strong>${touche.length || enCours.length ? 'Certains services sont perturbés.' : 'Tous les services fonctionnent normalement.'}</strong></p>`;
  zoneIncidents.innerHTML = enCours.length
    ? `<ul class="gmb-documents">${enCours.map((x) => `<li><span data-icone="alerte">${icone('alerte')}</span><span class="gmb-documents__nom">${echapperHtml(x.titre)}<span class="gmb-documents__detail">Détecté ${formaterDateRelative(x.detecte_le).toLowerCase()}${x.description ? ` · ${echapperHtml(x.description)}` : ''}</span></span><span class="gmb-badge gmb-badge--alerte">En cours</span></li>`).join('')}</ul>`
    : '<p class="gmb-section__intro">Aucun incident en cours.</p>';
  const jours = [];
  const aujourdHui = new Date();
  for (let n = 89; n >= 0; n -= 1) {
    const jour = new Date(aujourdHui.getTime() - n * 864e5).toISOString().slice(0, 10);
    const incident = incidents.find((x) => String(x.detecte_le).slice(0, 10) === jour);
    jours.push({ jour, incident });
  }
  historique.innerHTML = `<div class="gmb-etat-historique__barres" role="img" aria-label="${jours.filter((j) => j.incident).length ? `${jours.filter((j) => j.incident).length} jour(s) avec incident sur 90` : 'Aucun incident sur les 90 derniers jours'}">${jours.map((j) => `<span class="gmb-etat-historique__jour${j.incident ? ' gmb-etat-historique__jour--incident' : ''}" title="${j.jour}${j.incident ? ` : ${echapperHtml(j.incident.titre)}` : ' : aucun incident'}"></span>`).join('')}</div><div class="gmb-simulateur__bornes"><span>Il y a 90 jours</span><span>Aujourd’hui</span></div>`;
  source.textContent = `Données lues en direct, mises à jour ${formaterDateRelative(new Date()).toLowerCase()}.`;
}

function demarrerGraphiques() {
  document.querySelectorAll('[data-etat-services]').forEach(rendreEtatServices);
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrerGraphiques, { once: true });
else demarrerGraphiques();
