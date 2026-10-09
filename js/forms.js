/* =============================================================================
   GerMoonBank (GMB) · js/forms.js
   Formulaires : simulateurs, comparateur de change, recherche d’aide — version 3
   -----------------------------------------------------------------------------
   Simulateurs de Livret, de prêt personnel et de coûts Pro ; comparateur de
   change sur les taux de la BCE du jour ; recherche du centre d'aide. Les
   calculs utilisent le catalogue de js/core.js (données de data/).
   ========================================================================== */

import {
  BESOINS_PRO, CREDIT, FORMULES, INTERNATIONAL, LIVRET, REGLEMENTES,
  annoncer, antiRebond, chemin, coutCredit, coutsPro, echapperHtml,
  formaterDate, formaterMontant, formaterNombre, formaterTaux, formule, formulePro,
  fraisChange, fraisRetrait, grilleCredit, icone, interetsLivret, lienOuverture,
  mouvementReduit, tauxBCE,
} from './core.js';
import { avecDelai } from './donnees.js';

const normaliser = (texte) => String(texte).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '');

/** Recherche dans les questions de la page, suggestions dès la troisième lettre. */

function formaterDevise(valeur, code) {
  const decimales = ['JPY', 'XOF'].includes(code) ? 0 : 2;
  return new Intl.NumberFormat('fr-FR', { style: 'currency', currency: code, minimumFractionDigits: decimales, maximumFractionDigits: decimales }).format(valeur);
}

function brancherComparateurChange(formulaire) {
  const champ = formulaire.querySelector('[name="change-montant"]');
  const deja = formulaire.querySelector('[name="change-deja"]');
  const devise = formulaire.querySelector('[name="change-devise"]');
  const ecrire = (nom, texte) => formulaire.querySelectorAll(`[data-sortie="${nom}"]`).forEach((el) => { el.textContent = texte; });
  const annoncer = antiRebond((texte) => ecrire('annonce', texte), 700);
  const lire = (el) => Number(String(el?.value ?? '0').replace(/\s/g, '').replace(',', '.'));
  devise.innerHTML = INTERNATIONAL.devises.map((d) => `<option value="${d.code}">${d.nom} (${d.code})</option>`).join('');
  let taux = null;
  const ecrireDate = (texte) => document.querySelectorAll('[data-catalogue="date-taux-change"]').forEach((el) => { el.textContent = texte; });

  function calculer() {
    const montant = lire(champ);
    const erreur = formulaire.querySelector('[data-erreur="montant"]');
    const valide = Number.isFinite(montant) && montant > 0 && montant <= 1000000;
    erreur.hidden = valide;
    erreur.querySelector('[data-texte]').textContent = valide ? '' : 'Saisissez un montant en euros, supérieur à 0.';
    champ.setAttribute('aria-invalid', String(!valide));
    formulaire.dataset.valide = String(valide);
    if (!valide) return;
    const d = INTERNATIONAL.devises.find((x) => x.code === devise.value) || INTERNATIONAL.devises[0];
    const t = d.fixe ? d.taux : taux?.taux?.[d.code];
    if (!t) {
      ['recu', 'dans-franchise', 'hors-franchise', 'frais', 'ecart', 'total'].forEach((n) => ecrire(n, '—'));
      ecrire('taux-bce', taux === null ? 'Chargement du taux du jour…' : 'Taux de la BCE indisponible pour le moment. Réessayez plus tard.');
      return;
    }
    const code = formulaire.querySelector('input[name="change-formule"]:checked')?.value || 'orbit';
    const weekend = formulaire.querySelector('input[name="change-moment"]:checked')?.value === 'weekend';
    const r = fraisChange(montant, code, { dejaConverti: Math.max(0, lire(deja) || 0), weekend });
    const ecart = (r.frais / montant) * 100;
    ecrire('recu', formaterDevise(montant * t, d.code));
    ecrire('taux-bce', `1 € = ${formaterNombre(t, d.decimalesTaux)} ${d.code}${d.fixe ? ' (parité fixe)' : ''}`);
    ecrire('dans-franchise', formaterMontant(r.dansFranchise));
    ecrire('hors-franchise', formaterMontant(r.horsFranchise));
    ecrire('frais', formaterMontant(r.frais));
    ecrire('ecart', formaterTaux(ecart, 2));
    ecrire('total', formaterMontant(montant + r.frais));
    annoncer(`Vous recevez ${formaterDevise(montant * t, d.code)}. Frais ${formaterMontant(r.frais)}, soit un écart de ${formaterTaux(ecart, 2)} avec le taux de référence de la BCE.`);
  }
  formulaire.addEventListener('input', calculer);
  formulaire.addEventListener('change', calculer);
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
  tauxBCE()
    .then((r) => { taux = r; ecrireDate(formaterDate(`${r.date}T12:00:00`, 'court')); calculer(); })
    .catch(() => { taux = false; ecrireDate('indisponible'); calculer(); });
}

function brancherSimulateurPro(formulaire) {
  const utilisateurs = formulaire.querySelector('[name="pro-utilisateurs"]');
  const operations = formulaire.querySelector('[name="pro-operations"]');
  const besoin = formulaire.querySelector('[name="pro-besoin"]');
  const tableau = formulaire.querySelector('[data-sortie-tableau]');
  const ecrire = (nom, texte) => formulaire.querySelectorAll(`[data-sortie="${nom}"]`).forEach((el) => { el.textContent = texte; });
  const annoncer = antiRebond((texte) => ecrire('annonce', texte), 700);
  besoin.innerHTML = BESOINS_PRO.map((b) => `<option value="${b.code}">${b.libelle}</option>`).join('');

  const erreur = (nom, champ, message) => {
    const el = formulaire.querySelector(`[data-erreur="${nom}"]`);
    el.hidden = !message;
    el.querySelector('[data-texte]').textContent = message || '';
    champ.setAttribute('aria-invalid', String(Boolean(message)));
  };

  function calculer() {
    const u = Number(utilisateurs.value);
    const o = Number(operations.value);
    const uValide = Number.isInteger(u) && u >= 1 && u <= 10000;
    const oValide = Number.isInteger(o) && o >= 0 && o <= 1000000;
    erreur('utilisateurs', utilisateurs, uValide ? '' : 'Saisissez un nombre entier d’utilisateurs, au moins 1.');
    erreur('operations', operations, oValide ? '' : 'Saisissez un nombre entier d’opérations, 0 ou plus.');
    formulaire.dataset.valide = String(uValide && oValide);
    if (!uValide || !oValide) return;
    const { lignes, recommandee } = coutsPro({ utilisateurs: u, operations: o, besoin: besoin.value });
    ecrire('recommandee', recommandee ? recommandee.nom : 'Sur devis');
    ecrire('cout', recommandee ? formaterMontant(recommandee.total) : '—');
    const lien = formulaire.querySelector('[data-sortie="lien"]');
    if (lien && recommandee) lien.href = lienOuverture({ segment: formulePro(recommandee.code).segment, formule: recommandee.code });
    tableau.innerHTML = `<table class="gmb-tableau"><caption class="gmb-visuellement-masque">Coût mensuel hors taxes de chaque formule</caption>
      <thead><tr><th scope="col">Formule</th><th scope="col" class="gmb-nombre">Coût HT par mois</th></tr></thead>
      <tbody>${lignes.map((l) => `<tr${recommandee && l.code === recommandee.code ? ' data-mis-en-avant' : ''}><th scope="row">${l.nom}</th>
        <td class="gmb-nombre">${l.adaptee ? `${formaterMontant(l.total)}${l.supplement ? `<span class="gmb-comparatif__prix">dont ${formaterMontant(l.supplement)} d’opérations</span>` : ''}` : `<span class="gmb-comparatif__prix" style="margin:0">${l.raison}</span>`}</td></tr>`).join('')}</tbody></table>`;
    annoncer(recommandee ? `Formule la moins chère : ${recommandee.nom}, ${formaterMontant(recommandee.total)} hors taxes par mois.` : 'Aucune formule standard ne convient : contactez-nous pour un devis.');
  }
  formulaire.addEventListener('input', calculer);
  formulaire.addEventListener('change', calculer);
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
}

function brancherSimulateurLivret(formulaire) {
  const curseur = formulaire.querySelector('[name="sim-montant"], #sim-montant');
  const duree = formulaire.querySelector('[name="sim-duree"]');
  const sortie = (nom) => formulaire.querySelector(`[data-sortie="${nom}"]`);
  const ecrire = (nom, texte) => {
    formulaire.querySelectorAll(`[data-sortie="${nom}"]`).forEach((el) => {
      el.textContent = texte;
    });
  };
  const annoncer = antiRebond((texte) => ecrire('annonce', texte), 600);

  function majCurseur(el) {
    const progression = ((Number(el.value) - Number(el.min)) / (Number(el.max) - Number(el.min))) * 100;
    el.style.setProperty('--valeur', `${progression}%`);
  }

  function mettreAJour() {
    const montant = Number(curseur.value);
    const code = formulaire.querySelector('input[name="sim-formule"]:checked')?.value || 'zenith';
    const taux = formule(code).tauxLivret;
    const mois = duree ? Number(duree.value) : 12;
    const jours = Math.round((mois / 12) * LIVRET.baseJours);
    const resultat = interetsLivret(montant, taux, jours);
    const montantTexte = formaterMontant(montant, { decimales: 0 });

    majCurseur(curseur);
    curseur.setAttribute('aria-valuetext', montantTexte);
    if (duree) {
      majCurseur(duree);
      duree.setAttribute('aria-valuetext', `${mois} mois`);
    }
    ecrire('montant', montantTexte);
    ecrire('duree', `${mois} mois`);
    ecrire('jour', formaterMontant(resultat.parJour));
    ecrire('annee', formaterMontant(resultat.parAn));
    ecrire('periode', formaterMontant(resultat.surPeriode));
    ecrire('total', formaterMontant(montant + resultat.surPeriode));
    ecrire('taux', formaterTaux(taux));
    const lien = sortie('lien');
    if (lien) lien.href = lienOuverture({ formule: code });
    annoncer(`${montantTexte} placés au taux de ${formaterTaux(taux)} : environ ${formaterMontant(resultat.parJour)} par jour, ${formaterMontant(resultat.surPeriode)} sur ${mois} mois.`);
  }

  formulaire.addEventListener('input', mettreAJour);
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  mettreAJour();
}

function brancherSimulateurCredit(formulaire) {
  const curseur = formulaire.querySelector('[name="credit-montant-curseur"]');
  const champMontant = formulaire.querySelector('[name="credit-montant"]');
  const champDuree = formulaire.querySelector('[name="credit-duree"]');
  const choixDuree = formulaire.querySelectorAll('input[name="credit-duree-choix"]');
  const objet = formulaire.querySelector('[name="credit-objet"]');
  const sortie = (nom) => formulaire.querySelector(`[data-sortie="${nom}"]`);
  const ecrire = (nom, texte) => {
    formulaire.querySelectorAll(`[data-sortie="${nom}"]`).forEach((el) => {
      el.textContent = texte;
    });
  };
  const erreur = (nom, message) => {
    const el = formulaire.querySelector(`[data-erreur="${nom}"]`);
    const champ = nom === 'montant' ? champMontant : champDuree;
    if (!el) return;
    el.hidden = !message;
    el.querySelector('[data-texte]').textContent = message || '';
    champ.setAttribute('aria-invalid', message ? 'true' : 'false');
  };
  const annoncer = antiRebond((texte) => ecrire('annonce', texte), 700);

  const lireNombre = (champ) => Number(String(champ.value).replace(/\s/g, '').replace(',', '.'));

  function majCurseur() {
    const progression = ((Number(curseur.value) - CREDIT.montantMin) / (CREDIT.montantMax - CREDIT.montantMin)) * 100;
    curseur.style.setProperty('--valeur', `${progression}%`);
    curseur.setAttribute('aria-valuetext', formaterMontant(Number(curseur.value), { decimales: 0 }));
  }

  function calculer() {
    const montant = lireNombre(champMontant);
    const duree = lireNombre(champDuree);
    let valide = true;

    if (!Number.isFinite(montant) || montant < CREDIT.montantMin || montant > CREDIT.montantMax) {
      erreur('montant', `Saisissez un montant entre ${formaterMontant(CREDIT.montantMin, { decimales: 0 })} et ${formaterMontant(CREDIT.montantMax, { decimales: 0 })}.`);
      valide = false;
    } else erreur('montant', '');

    if (!Number.isInteger(duree) || duree < CREDIT.dureeMin || duree > CREDIT.dureeMax) {
      erreur('duree', `Saisissez une durée entre ${CREDIT.dureeMin} et ${CREDIT.dureeMax} mois, en nombre entier.`);
      valide = false;
    } else erreur('duree', '');

    choixDuree.forEach((radio) => {
      radio.checked = Number(radio.value) === duree;
    });
    formulaire.dataset.valide = String(valide);
    if (!valide) return;

    const taux = grilleCredit(duree, objet?.value);
    const c = coutCredit(montant, taux, duree);
    ecrire('mensualite', formaterMontant(c.mensualite));
    ecrire('duree', `${duree} mois`);
    ecrire('taux', formaterTaux(taux));
    ecrire('taeg', formaterTaux(c.taeg));
    ecrire('cout', formaterMontant(c.cout));
    ecrire('du', formaterMontant(c.montantDu));
    ecrire('frais', formaterMontant(CREDIT.fraisDossier));
    ecrire('montant', formaterMontant(montant));
    const lien = sortie('lien');
    if (lien) {
      const parametres = new URLSearchParams({ segment: 'particuliers', produit: 'pret_personnel', montant: String(montant), duree: String(duree) });
      if (objet?.value) parametres.set('objet', objet.value);
      lien.href = `${chemin('public/inscription/index.html')}?${parametres}`;
    }
    annoncer(`${formaterMontant(montant)} sur ${duree} mois : ${duree} mensualités de ${formaterMontant(c.mensualite)}, TAEG fixe ${formaterTaux(c.taeg)}, coût total ${formaterMontant(c.cout)}.`);
  }

  curseur.addEventListener('input', () => {
    champMontant.value = curseur.value;
    majCurseur();
    calculer();
  });

  champMontant.addEventListener('input', () => {
    const montant = lireNombre(champMontant);
    if (Number.isFinite(montant)) {
      curseur.value = String(Math.min(CREDIT.montantMax, Math.max(CREDIT.montantMin, montant)));
      majCurseur();
    }
    calculer();
  });

  champMontant.addEventListener('blur', () => {
    const montant = lireNombre(champMontant);
    if (Number.isFinite(montant) && montant > 0) champMontant.value = String(Math.round(montant * 100) / 100);
  });

  champDuree.addEventListener('input', calculer);
  choixDuree.forEach((radio) => radio.addEventListener('change', () => {
    champDuree.value = radio.value;
    calculer();
  }));
  objet?.addEventListener('change', calculer);
  formulaire.addEventListener('submit', (e) => e.preventDefault());

  majCurseur();
  calculer();
}

function brancherRechercheAide(bloc) {
  const champ = bloc.querySelector('input[type="search"]');
  const liste = bloc.querySelector('.gmb-recherche-aide__resultats');
  const annonce = bloc.querySelector('[data-annonce-recherche]');
  const articles = [...document.querySelectorAll('details.gmb-accordeon[id]')].map((d) => ({
    id: d.id,
    titre: d.querySelector('summary').textContent.trim(),
    rubrique: d.closest('section[id]')?.querySelector('h3')?.textContent.trim() || '',
    texte: normaliser(d.textContent),
  }));
  const ouvrir = (id) => {
    const cible = document.getElementById(id);
    if (!cible) return;
    cible.open = true;
    cible.scrollIntoView({ behavior: 'smooth', block: 'center' });
    cible.querySelector('summary').focus({ preventScroll: true });
  };
  const chercher = antiRebond(() => {
    const requete = normaliser(champ.value.trim());
    if (requete.length < 3) {
      liste.hidden = true;
      liste.innerHTML = '';
      annonce.textContent = '';
      return;
    }
    const mots = requete.split(/\s+/).filter(Boolean);
    const trouves = articles.filter((a) => mots.every((m) => a.texte.includes(m))).slice(0, 6);
    liste.innerHTML = trouves.length
      ? trouves.map((a) => `<li><a href="#${a.id}" data-article="${a.id}"><span class="gmb-recherche-aide__rubrique">${echapperHtml(a.rubrique)}</span>${echapperHtml(a.titre)}</a></li>`).join('')
      : '<li class="gmb-recherche-aide__vide">Aucune réponse trouvée. Essayez un autre mot, ou contactez-nous depuis votre espace.</li>';
    liste.hidden = false;
    annonce.textContent = trouves.length ? `${trouves.length} réponse${trouves.length > 1 ? 's' : ''} trouvée${trouves.length > 1 ? 's' : ''}.` : 'Aucune réponse trouvée.';
  }, 150);
  champ.addEventListener('input', chercher);
  liste.addEventListener('click', (e) => {
    const lien = e.target.closest('[data-article]');
    if (!lien) return;
    e.preventDefault();
    ouvrir(lien.dataset.article);
  });
  if (location.hash) ouvrir(location.hash.slice(1));
}

/* -----------------------------------------------------------------------------
   Comparateur de comptes : coût réel de chaque formule selon vos usages
   (abonnement, frais de retrait et de change hors franchise, intérêts du Livret)
   -------------------------------------------------------------------------- */
function brancherComparateurComptes(formulaire) {
  const zone = formulaire.querySelector('[data-resultats-comptes]');
  const recommandation = formulaire.querySelector('[data-recommandation-compte]');
  const valeur = (nom) => {
    const n = Number(String(formulaire.elements[nom]?.value ?? '').replace(/\s/g, '').replace(',', '.'));
    return Number.isFinite(n) && n > 0 ? n : 0;
  };
  function calculer() {
    const retraits = valeur('retraits');
    const devises = valeur('devises');
    const epargne = Math.min(valeur('epargne'), LIVRET.plafond);
    const weekend = Boolean(formulaire.elements.weekend?.checked);
    const lignes = FORMULES.map((f) => {
      const frais = fraisRetrait(retraits, f.code).frais + fraisChange(devises, f.code, { weekend }).frais;
      const interets = Math.round((interetsLivret(epargne, f.tauxLivret || 0, 365).parAn / 12) * 100) / 100;
      return { f, frais, interets, net: Math.round((f.prix + frais - interets) * 100) / 100 };
    });
    const meilleure = lignes.reduce((a, b) => (b.net < a.net ? b : a));
    zone.innerHTML = `<table class="gmb-tableau"><caption>Coût mensuel estimé selon vos usages</caption>
      <thead><tr><th scope="col">Formule</th><th scope="col" class="gmb-nombre">Coût net</th><th scope="col" class="gmb-nombre">Abonnement</th><th scope="col" class="gmb-nombre">Frais d’usage</th><th scope="col" class="gmb-nombre">Intérêts du Livret</th></tr></thead>
      <tbody>${lignes.map((l) => `<tr><th scope="row">${echapperHtml(l.f.nom)}${l === meilleure ? ' <span class="gmb-badge gmb-badge--succes">Le plus avantageux</span>' : ''}</th>
        <td class="gmb-nombre"><strong>${formaterMontant(l.net)}</strong></td><td class="gmb-nombre">${formaterMontant(l.f.prix)}</td><td class="gmb-nombre">${formaterMontant(l.frais)}</td>
        <td class="gmb-nombre">${l.interets ? `− ${formaterMontant(l.interets)}` : formaterMontant(0)}</td></tr>`).join('')}</tbody></table>`;
    recommandation.textContent = meilleure.net < 0
      ? `Pour vos usages, la formule ${meilleure.f.nom} est la plus avantageuse : ses intérêts dépassent son coût de ${formaterMontant(-meilleure.net)} par mois.`
      : `Pour vos usages, la formule ${meilleure.f.nom} est la plus avantageuse : ${formaterMontant(meilleure.net)} par mois, intérêts du Livret déduits.`;
  }
  formulaire.addEventListener('input', antiRebond(calculer, 150));
  formulaire.addEventListener('change', calculer);
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
}

/* -----------------------------------------------------------------------------
   Simulateur d'épargne : versements et intérêts du Livret GMB, calculés jour
   par jour comme dans la base (intérêt du jour arrondi au centime, ajouté au solde)
   -------------------------------------------------------------------------- */
export function simulerLivret({ initial = 0, mensuel = 0, annees = 1, taux = 0, debut = new Date() }) {
  const plafond = LIVRET.plafond;
  const centimes = (x) => Math.round(x * 100 + 1e-7) / 100;
  let solde = centimes(Math.min(Math.max(initial, 0), plafond));
  let verse = solde;
  let interets = 0;
  const jour = new Date(Date.UTC(debut.getFullYear(), debut.getMonth(), debut.getDate()));
  const fin = new Date(jour); fin.setUTCFullYear(fin.getUTCFullYear() + annees);
  const parAnnee = [];
  let limite = new Date(jour); limite.setUTCFullYear(limite.getUTCFullYear() + 1);
  for (const d = new Date(jour); d < fin; d.setUTCDate(d.getUTCDate() + 1)) {
    if (d > jour && d.getUTCDate() === 1 && mensuel > 0 && solde < plafond) {
      const v = centimes(Math.min(mensuel, plafond - solde));
      solde = centimes(solde + v); verse = centimes(verse + v);
    }
    const gain = centimes((solde * taux) / 100 / 365);
    solde = centimes(solde + gain); interets = centimes(interets + gain);
    const lendemain = new Date(d); lendemain.setUTCDate(d.getUTCDate() + 1);
    if (lendemain >= limite || lendemain >= fin) {
      parAnnee.push({ annee: parAnnee.length + 1, verse, interets, solde });
      limite.setUTCFullYear(limite.getUTCFullYear() + 1);
    }
  }
  return { verse, interets, solde, parAnnee };
}

function brancherSimulateurEpargne(formulaire) {
  const choix = formulaire.querySelector('[name="formule"]');
  choix.innerHTML = FORMULES.filter((f) => f.tauxLivret).map((f) => `<option value="${f.code}">${echapperHtml(f.nom)} · ${formaterTaux(f.tauxLivret)}</option>`).join('');
  choix.value = FORMULES.some((f) => f.code === 'orbit') ? 'orbit' : choix.value;
  const zone = formulaire.querySelector('[data-resultats-epargne]');
  const synthese = formulaire.querySelector('[data-synthese-epargne]');
  const valeur = (nom) => { const n = Number(String(formulaire.elements[nom]?.value ?? '').replace(/\s/g, '').replace(',', '.')); return Number.isFinite(n) && n > 0 ? n : 0; };
  function calculer() {
    const f = FORMULES.find((x) => x.code === choix.value) || FORMULES[0];
    const annees = Math.min(10, Math.max(1, Math.round(valeur('annees')) || 1));
    const r = simulerLivret({ initial: valeur('initial'), mensuel: valeur('mensuel'), annees, taux: f.tauxLivret });
    synthese.textContent = `Au bout de ${annees} an${annees > 1 ? 's' : ''} : ${formaterMontant(r.solde)}, dont ${formaterMontant(r.interets)} d’intérêts bruts pour ${formaterMontant(r.verse)} versés.`;
    zone.innerHTML = `<table class="gmb-tableau"><caption>Évolution année par année (formule ${echapperHtml(f.nom)})</caption>
      <thead><tr><th scope="col">Année</th><th scope="col" class="gmb-nombre">Solde</th><th scope="col" class="gmb-nombre">Versé</th><th scope="col" class="gmb-nombre">Intérêts</th></tr></thead>
      <tbody>${r.parAnnee.map((a) => `<tr><th scope="row">${a.annee}</th><td class="gmb-nombre"><strong>${formaterMontant(a.solde)}</strong></td><td class="gmb-nombre">${formaterMontant(a.verse)}</td><td class="gmb-nombre">${formaterMontant(a.interets)}</td></tr>`).join('')}</tbody></table>`;
  }
  formulaire.addEventListener('input', antiRebond(calculer, 200));
  formulaire.addEventListener('change', calculer);
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
}

/* -----------------------------------------------------------------------------
   Comparateur de livrets : Livret GMB (imposable) face au Livret A et au LDDS
   (exonérés, plafonnés). Le taux réglementé et le taux d'imposition sont saisis
   par la personne : ils changent, aucun chiffre n'est écrit en dur.
   -------------------------------------------------------------------------- */
function brancherComparateurLivrets(formulaire) {
  const choix = formulaire.querySelector('[name="formule"]');
  choix.innerHTML = FORMULES.filter((f) => f.tauxLivret).map((f) => `<option value="${f.code}">${echapperHtml(f.nom)} · ${formaterTaux(f.tauxLivret)}</option>`).join('');
  choix.value = FORMULES.some((f) => f.code === 'orbit') ? 'orbit' : choix.value;
  const zone = formulaire.querySelector('[data-resultats-livrets]');
  const message = formulaire.querySelector('[data-message-livrets]');
  const nombre = (nom) => { const brut = String(formulaire.elements[nom]?.value ?? '').trim(); if (!brut) return null; const n = Number(brut.replace(/\s/g, '').replace(',', '.')); return Number.isFinite(n) && n >= 0 ? n : null; };
  function calculer() {
    const montant = nombre('montant') || 0;
    const f = FORMULES.find((x) => x.code === choix.value) || FORMULES[0];
    const tauxA = nombre('tauxA');
    const impot = nombre('impot');
    const gmbBase = Math.min(montant, LIVRET.plafond);
    const gmbBrut = simulerLivret({ initial: gmbBase, annees: 1, taux: f.tauxLivret }).interets;
    const lignes = [{ nom: `Livret GMB (${f.nom})`, base: gmbBase, brut: gmbBrut, net: impot === null ? null : Math.round(gmbBrut * (100 - impot)) / 100, note: 'imposable' }];
    if (tauxA !== null) {
      for (const [nom, plafond] of [['Livret A', REGLEMENTES.livretA.plafond], ['LDDS', REGLEMENTES.ldds.plafond]]) {
        const base = Math.min(montant, plafond);
        const brut = Math.round(base * tauxA) / 100;
        lignes.push({ nom, base, brut, net: brut, note: 'exonéré' });
      }
    }
    zone.innerHTML = `<table class="gmb-tableau"><caption>Intérêts sur un an, pour ${formaterMontant(montant)} placés</caption>
      <thead><tr><th scope="col">Livret</th><th scope="col" class="gmb-nombre">Intérêts nets</th><th scope="col" class="gmb-nombre">Intérêts bruts</th><th scope="col" class="gmb-nombre">Somme placée</th><th scope="col">Impôt</th></tr></thead>
      <tbody>${lignes.map((l) => `<tr><th scope="row">${echapperHtml(l.nom)}</th><td class="gmb-nombre"><strong>${l.net === null ? '—' : formaterMontant(l.net)}</strong></td><td class="gmb-nombre">${formaterMontant(l.brut)}</td><td class="gmb-nombre">${formaterMontant(l.base)}</td><td>${l.note}</td></tr>`).join('')}</tbody></table>`;
    const manque = [];
    if (tauxA === null) manque.push('le taux du Livret A en vigueur');
    if (impot === null) manque.push('votre taux d’imposition des intérêts');
    const plafonne = lignes.filter((l) => l.base < montant).map((l) => l.nom);
    message.textContent = (manque.length ? `Indiquez ${manque.join(' et ')} pour compléter la comparaison. ` : '')
      + (plafonne.length ? `Au-delà de son plafond, la somme n’est pas placée sur : ${plafonne.join(', ')}.` : '');
  }
  formulaire.addEventListener('input', antiRebond(calculer, 200));
  formulaire.addEventListener('change', calculer);
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
}

/* -----------------------------------------------------------------------------
   Crédit amortissable à taux fixe : mensualité hors assurance
   -------------------------------------------------------------------------- */
export function mensualitePret(capital, tauxAnnuel, mois) {
  if (!(capital > 0) || !(mois > 0)) return 0;
  const t = tauxAnnuel / 100 / 12;
  return t === 0 ? capital / mois : (capital * t) / (1 - (1 + t) ** -mois);
}

const lireNombre = (formulaire, nom) => {
  const brut = String(formulaire.elements[nom]?.value ?? '').trim();
  if (!brut) return null;
  const n = Number(brut.replace(/\s/g, '').replace(',', '.'));
  return Number.isFinite(n) && n >= 0 ? n : null;
};
const arrondi = (x) => Math.round(x * 100) / 100;

/* Simulateur de crédit immobilier : le taux est saisi par la personne */
function brancherSimulateurImmobilier(formulaire) {
  const synthese = formulaire.querySelector('[data-synthese-immobilier]');
  const zone = formulaire.querySelector('[data-resultats-immobilier]');
  function calculer() {
    const v = (n) => lireNombre(formulaire, n) ?? 0;
    const taux = lireNombre(formulaire, 'taux');
    const annees = Math.round(v('duree'));
    const capital = Math.max(0, v('prix') + v('frais') - v('apport'));
    if (taux === null || !annees || !capital) {
      synthese.textContent = taux === null ? 'Indiquez le taux nominal proposé par votre banque.' : 'Indiquez le prix, la durée et votre apport.';
      zone.innerHTML = '';
      return;
    }
    const mois = annees * 12;
    const mensualite = arrondi(mensualitePret(capital, taux, mois));
    const assurance = arrondi((capital * v('assurance')) / 100 / 12);
    const interets = arrondi(mensualite * mois - capital);
    const coutAssurance = arrondi(assurance * mois);
    const revenus = v('revenus');
    const endettement = revenus ? ((mensualite + assurance + v('charges')) / revenus) * 100 : null;
    synthese.textContent = `Mensualité : ${formaterMontant(arrondi(mensualite + assurance))} assurance comprise, pendant ${annees} ans.`
      + (endettement === null ? '' : ` Taux d’endettement : ${formaterTaux(endettement, 1)}${endettement > 35 ? ', au-delà du repère de 35 %.' : '.'}`)
      + (annees > 25 ? ' Une durée de plus de 25 ans dépasse le repère du Haut Conseil de stabilité financière.' : '');
    const lignes = [['Montant emprunté', capital], ['Mensualité hors assurance', mensualite], ['Assurance par mois', assurance],
      ['Coût des intérêts', interets], ['Coût de l’assurance', coutAssurance], ['Coût total du crédit', arrondi(interets + coutAssurance)]];
    zone.innerHTML = `<table class="gmb-tableau"><caption>Détail de votre crédit</caption><tbody>${lignes.map(([l, m]) => `<tr><th scope="row">${l}</th><td class="gmb-nombre">${formaterMontant(m)}</td></tr>`).join('')}</tbody></table>`;
  }
  formulaire.addEventListener('input', antiRebond(calculer, 200));
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
}

/* Capacité d'emprunt : 35 % des revenus, assurance comprise, moins les crédits en cours */
function brancherCapaciteEmprunt(formulaire) {
  const synthese = formulaire.querySelector('[data-synthese-capacite]');
  function calculer() {
    const v = (n) => lireNombre(formulaire, n) ?? 0;
    const taux = lireNombre(formulaire, 'taux');
    const annees = Math.round(v('duree'));
    const disponible = arrondi(Math.max(0, v('revenus') * 0.35 - v('charges')));
    if (taux === null || !annees) {
      synthese.textContent = `Mensualité maximale : ${formaterMontant(disponible)}. Indiquez le taux proposé et la durée pour connaître le montant empruntable.`;
      return;
    }
    const parEuro = mensualitePret(1, taux, annees * 12) + v('assurance') / 100 / 12;
    const capital = parEuro > 0 ? Math.floor(disponible / parEuro) : 0;
    synthese.textContent = `Mensualité maximale : ${formaterMontant(disponible)} assurance comprise. Vous pourriez emprunter environ ${formaterMontant(capital, { decimales: 0 })} sur ${annees} ans.`;
  }
  formulaire.addEventListener('input', antiRebond(calculer, 200));
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
}

/* -----------------------------------------------------------------------------
   Simulateur boursier : rendement annuel supposé (positif ou négatif), capitalisé
   chaque mois, frais annuels déduits. Une hypothèse, jamais une prévision.
   -------------------------------------------------------------------------- */
export function simulerPlacement({ initial = 0, mensuel = 0, annees = 1, rendement = 0, frais = 0 }) {
  const taux = (1 + (rendement - frais) / 100) ** (1 / 12) - 1;
  let valeur = initial;
  let verse = initial;
  const parAnnee = [];
  for (let mois = 1; mois <= annees * 12; mois += 1) {
    valeur = valeur * (1 + taux) + mensuel;
    verse += mensuel;
    if (mois % 12 === 0) parAnnee.push({ annee: mois / 12, verse, valeur: Math.round(valeur * 100) / 100 });
  }
  return { verse, valeur: Math.round(valeur * 100) / 100, parAnnee };
}

function brancherSimulateurBoursier(formulaire) {
  const synthese = formulaire.querySelector('[data-synthese-boursier]');
  const zone = formulaire.querySelector('[data-resultats-boursier]');
  const nombre = (nom, negatif = false) => {
    const brut = String(formulaire.elements[nom]?.value ?? '').trim().replace(/\s/g, '').replace(',', '.').replace('−', '-');
    if (!brut) return null;
    const n = Number(brut);
    return Number.isFinite(n) && (negatif || n >= 0) ? n : null;
  };
  function calculer() {
    const rendement = nombre('rendement', true);
    const annees = Math.min(40, Math.round(nombre('annees') || 0));
    if (rendement === null || !annees) {
      synthese.textContent = 'Indiquez une durée et le rendement annuel que vous souhaitez tester.';
      zone.innerHTML = '';
      return;
    }
    const r = simulerPlacement({ initial: nombre('initial') || 0, mensuel: nombre('mensuel') || 0, annees, rendement, frais: nombre('frais') || 0 });
    const ecart = Math.round((r.valeur - r.verse) * 100) / 100;
    synthese.textContent = `Avec ${formaterTaux(rendement)} par an, ${formaterMontant(r.verse)} versés deviendraient ${formaterMontant(r.valeur)} en ${annees} an${annees > 1 ? 's' : ''} : ${ecart >= 0 ? 'un gain' : 'une perte'} de ${formaterMontant(Math.abs(ecart))}.`;
    zone.innerHTML = `<table class="gmb-tableau"><caption>Évolution année par année</caption><thead><tr><th scope="col">Année</th><th scope="col" class="gmb-nombre">Valeur</th><th scope="col" class="gmb-nombre">Versé</th></tr></thead>
      <tbody>${r.parAnnee.map((a) => `<tr><th scope="row">${a.annee}</th><td class="gmb-nombre"><strong>${formaterMontant(a.valeur)}</strong></td><td class="gmb-nombre">${formaterMontant(a.verse)}</td></tr>`).join('')}</tbody></table>`;
  }
  formulaire.addEventListener('input', antiRebond(calculer, 200));
  formulaire.addEventListener('submit', (e) => e.preventDefault());
  calculer();
}

/* =============================================================================
   DÉMARRAGE : chaque formulaire présent dans la page est branché
   ========================================================================== */
function demarrerFormulaires() {
  document.querySelectorAll('[data-simulateur="change"]').forEach(brancherComparateurChange);
  document.querySelectorAll('[data-simulateur="pro"]').forEach(brancherSimulateurPro);
  document.querySelectorAll('[data-simulateur="livret"]').forEach(brancherSimulateurLivret);
  document.querySelectorAll('[data-simulateur="credit"]').forEach(brancherSimulateurCredit);
  document.querySelectorAll('[data-recherche-aide]').forEach(brancherRechercheAide);
  document.querySelectorAll('[data-simulateur="comptes"]').forEach(brancherComparateurComptes);
  document.querySelectorAll('[data-simulateur="epargne"]').forEach(brancherSimulateurEpargne);
  document.querySelectorAll('[data-simulateur="livrets"]').forEach(brancherComparateurLivrets);
  document.querySelectorAll('[data-simulateur="immobilier"]').forEach(brancherSimulateurImmobilier);
  document.querySelectorAll('[data-simulateur="capacite"]').forEach(brancherCapaciteEmprunt);
  document.querySelectorAll('[data-simulateur="boursier"]').forEach(brancherSimulateurBoursier);
}

if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', demarrerFormulaires, { once: true });
else demarrerFormulaires();

/* =============================================================================
   OUTILS DE FORMULAIRE (inscription et authentification)
   ========================================================================== */
const MOTS_DE_PASSE_DIVULGUES = new Set(['motdepasse123', 'motdepasse1234', 'azertyuiop12', 'azertyuiop123', '123456789012', '1234567890123',
  'password1234', 'password12345', 'qwertyuiop12', 'iloveyou1234', 'soleil123456', 'bonjour12345', 'motdepassefort', 'abcdefghijkl']);

/** Analyse d'un mot de passe : 12 caractères au moins, sans l'adresse e-mail, absent des listes connues. */
export function analyserMotDePasse(motDePasse, email = '') {
  const v = String(motDePasse || '');
  const bas = v.toLowerCase();
  const adresse = String(email || '').toLowerCase().trim();
  const local = adresse.split('@')[0] || '';
  const longueur = v.length >= 12;
  const sansEmail = !adresse || (!bas.includes(adresse) && !(local.length >= 3 && bas.includes(local)));
  const connu = MOTS_DE_PASSE_DIVULGUES.has(bas);
  let points = 0;
  if (v.length >= 12) points += 1;
  if (v.length >= 16) points += 1;
  if (/[a-z]/.test(v) && /[A-Z]/.test(v)) points += 0.5;
  if (/\d/.test(v)) points += 0.5;
  if (/[^A-Za-z0-9]/.test(v)) points += 0.5;
  if (new Set(v).size >= 10) points += 0.5;
  let niveau = 0;
  if (v) niveau = connu || !longueur ? 1 : Math.min(4, Math.max(2, Math.round(points)));
  return { longueur, sansEmail, connu, niveau, valide: longueur && sansEmail && !connu };
}

async function empreinteTexte(algorithme, texte) {
  const tampon = await crypto.subtle.digest(algorithme, new TextEncoder().encode(texte));
  return [...new Uint8Array(tampon)].map((o) => o.toString(16).padStart(2, '0')).join('');
}

/** Vérification anonymisée dans les bases de mots de passe divulgués : seuls les
 *  5 premiers caractères de l'empreinte SHA-1 sont envoyés. Renvoie true, false ou null. */
export async function motDePasseDivulgue(motDePasse) {
  if (MOTS_DE_PASSE_DIVULGUES.has(String(motDePasse).toLowerCase())) return true;
  try {
    const e = (await empreinteTexte('SHA-1', motDePasse)).toUpperCase();
    const reponse = await avecDelai(fetch(`https://api.pwnedpasswords.com/range/${e.slice(0, 5)}`, { headers: { 'Add-Padding': 'true' } }), 4000);
    if (!reponse.ok) return null;
    const suffixe = e.slice(5);
    return (await reponse.text()).split('\n').some((ligne) => {
      const [s, n] = ligne.trim().split(':');
      return s === suffixe && Number(n) > 0;
    });
  } catch {
    return null;
  }
}

/** Jauge, règles et bouton « afficher » d'un champ de mot de passe. */
export function brancherMotDePasse({ champ, champEmail, jauge, controles, bouton }) {
  const maj = () => {
    const a = analyserMotDePasse(champ.value, champEmail?.value);
    if (jauge) {
      jauge.dataset.niveau = String(a.niveau);
      jauge.setAttribute('aria-label', ['Mot de passe vide', 'Mot de passe trop faible', 'Mot de passe moyen', 'Mot de passe robuste', 'Mot de passe très robuste'][a.niveau]);
    }
    if (controles) {
      const etats = { longueur: a.longueur, email: a.sansEmail, connu: !a.connu };
      controles.querySelectorAll('[data-regle]').forEach((li) => {
        const ok = etats[li.dataset.regle];
        li.dataset.ok = champ.value ? String(ok) : '';
        const ic = li.querySelector('.gmb-icone');
        if (ic) ic.outerHTML = icone(champ.value ? (ok ? 'check' : 'croix') : 'info', { taille: 16 });
      });
    }
    return a;
  };
  champ.addEventListener('input', maj);
  champEmail?.addEventListener('input', maj);
  bouton?.addEventListener('click', () => {
    const visible = champ.type === 'text';
    champ.type = visible ? 'password' : 'text';
    bouton.setAttribute('aria-pressed', String(!visible));
    bouton.setAttribute('aria-label', visible ? 'Afficher le mot de passe' : 'Masquer le mot de passe');
  });
  maj();
  return maj;
}

/* Pièces justificatives : PDF, JPG, PNG, HEIC ; 10 Mo au plus */
export const TAILLE_MAX_PIECE = 10 * 1024 * 1024;
const EXTENSIONS = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic', 'image/heif': 'heic' };
export function extensionFichier(fichier) {
  return EXTENSIONS[fichier.type] || String(fichier.name.split('.').pop() || '').toLowerCase().replace('jpeg', 'jpg').replace('heif', 'heic');
}
export function controlerFichier(fichier) {
  if (!fichier) return 'Choisissez un fichier.';
  if (!['pdf', 'jpg', 'png', 'heic'].includes(extensionFichier(fichier))) return 'Ce format n’est pas accepté : déposez un PDF, un JPG, un PNG ou un HEIC.';
  if (fichier.size === 0) return 'Ce fichier est vide : choisissez-en un autre.';
  if (fichier.size > TAILLE_MAX_PIECE) return 'Ce fichier dépasse 10 Mo : réduisez sa taille ou prenez une nouvelle photo.';
  return null;
}
export function justificatifTropAncien(dateIso, mois = 3) {
  const d = new Date(`${dateIso}T12:00:00`);
  if (Number.isNaN(d.getTime())) return true;
  const limite = new Date();
  limite.setMonth(limite.getMonth() - mois);
  return d < limite || d > new Date(Date.now() + 864e5);
}
export async function empreinteFichier(fichier) {
  const tampon = await crypto.subtle.digest('SHA-256', await fichier.arrayBuffer());
  return [...new Uint8Array(tampon)].map((o) => o.toString(16).padStart(2, '0')).join('');
}

/* Interface */
export function masquerEmail(email) {
  const [local, domaine] = String(email || '').split('@');
  if (!domaine) return email || '';
  return `${local.slice(0, 1)}${'•'.repeat(Math.max(3, Math.min(8, local.length - 1)))}@${domaine}`;
}
export function occupe(bouton, actif) {
  if (!bouton) return;
  bouton.setAttribute('aria-busy', String(actif));
  bouton.disabled = actif;
}
export function afficherMessage(bloc, texte, type = 'erreur') {
  if (!bloc) return;
  if (!texte) { bloc.hidden = true; return; }
  bloc.className = `gmb-message-formulaire${type === 'erreur' ? '' : ` gmb-message-formulaire--${type}`}`;
  bloc.innerHTML = `${icone(type === 'succes' ? 'check' : type === 'info' ? 'info' : 'alerte')}<p>${echapperHtml(texte)}</p>`;
  bloc.setAttribute('role', type === 'erreur' ? 'alert' : 'status');
  bloc.hidden = false;
}
export async function copier(texte, bouton) {
  try {
    await navigator.clipboard.writeText(texte);
  } catch {
    const zone = document.createElement('textarea');
    zone.value = texte; zone.setAttribute('readonly', ''); zone.style.position = 'fixed'; zone.style.opacity = '0';
    document.body.append(zone); zone.select(); document.execCommand('copy'); zone.remove();
  }
  if (bouton) {
    const libelle = bouton.textContent;
    bouton.textContent = 'Copié';
    setTimeout(() => { bouton.textContent = libelle; }, 1800);
  }
  annoncer('Copié dans le presse-papiers.');
}
export function defilerVers(element) {
  element?.scrollIntoView({ behavior: mouvementReduit() ? 'auto' : 'smooth', block: 'start' });
}
/** Affiche (ou efface) l'erreur d'un champ ; renvoie true si le champ est valide. */
export function erreurChamp(champ, texte) {
  if (!champ) return !texte;
  const bloc = document.getElementById(`${champ.id}-erreur`);
  champ.setAttribute('aria-invalid', texte ? 'true' : 'false');
  if (bloc) { bloc.textContent = texte || ''; bloc.hidden = !texte; }
  return !texte;
}
export function age(dateIso) {
  const n = new Date(`${dateIso}T12:00:00`);
  if (Number.isNaN(n.getTime())) return -1;
  const a = new Date();
  let ans = a.getFullYear() - n.getFullYear();
  if (a.getMonth() < n.getMonth() || (a.getMonth() === n.getMonth() && a.getDate() < n.getDate())) ans -= 1;
  return ans;
}
export function normaliserTelephone(texte) {
  const v = String(texte || '').replace(/[\s.()-]/g, '');
  if (/^0[1-9]\d{8}$/.test(v)) return `+33${v.slice(1)}`;
  if (/^\+\d{8,15}$/.test(v)) return v;
  if (/^00\d{8,15}$/.test(v)) return `+${v.slice(2)}`;
  return null;
}
