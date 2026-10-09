/* =============================================================================
   GerMoonBank (GMB) · js/app/accounts.js — Comptes et cartes
   Comptes : liste par famille, relevé d'identité bancaire (IBAN attribué au
   compte, ou coordonnées de réception), épargne détenue, prélèvements.
   Cartes (lot E3b) : vos cartes en visuel, commande d'une carte physique ou
   virtuelle confirmée par le code secret, activation à réception, gel,
   utilisations, plafonds, étranger, opposition.
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, $$, e, date, page, parametre, montant, badge, tableau, demander, executer, message, authentifier, refusSca,
  iconeEc, pastille, visuelCarte, trierComptes, TYPES_COMPTE, ligneCompte, numeroLisible } from './app.js';
import { lire, appeler, modifier, ErreurGmb } from '../donnees.js';
import { copier } from '../forms.js';
import { formaterMontant } from '../core.js';

const GROUPES = [['Comptes de paiement', ['courant', 'pro', 'business', 'jeune']], ['Épargne', ['livret', 'coffre']], ['Autres comptes', ['devise', 'titres', 'crypto']]];
const lireComptes = (ctx, colonnes = 'id, type, libelle, numero, iban, bic, solde, taux, statut, ouvert_le') => (ctx.comptes.length ? lire('comptes', { colonnes, dans: { id: ctx.comptes }, ordre: 'created_at', croissant: true }) : []);
const nomCompte = (k) => k.libelle || TYPES_COMPTE[k.type] || 'Compte';

async function comptes() {
  const ctx = await ouvrirEspace('comptes');
  const rendre = async () => {
    const liste = await lireComptes(ctx);
    const actifs = liste.filter((c) => c.statut === 'actif');
    $('[data-total]').innerHTML = `<p class="app-compte-entete__nom">Solde global</p><p class="app-solde">${montant(actifs.reduce((t, c) => t + Number(c.solde || 0), 0))}</p>
      <span class="app-compte-entete__numero">${actifs.length} compte${actifs.length > 1 ? 's' : ''} actif${actifs.length > 1 ? 's' : ''}</span>`;
    // Une famille de comptes par bloc : nom, numéro, solde ; le statut n'apparaît que s'il n'est pas « actif »
    $('[data-comptes]').innerHTML = GROUPES.map(([titre, types]) => {
      const k = liste.filter((c) => types.includes(c.type));
      const total = k.filter((c) => c.statut === 'actif').reduce((t, c) => t + Number(c.solde || 0), 0);
      return k.length ? `<section class="app-bloc" aria-label="${e(titre)}"><div class="app-bloc__entete"><h2 class="app-bloc__titre">${e(titre)}</h2><span class="app-bloc__total">${montant(total)}</span></div>
        <ul class="app-groupe">${k.map((c) => ligneCompte(c)).join('')}</ul></section>` : '';
    }).join('') || '<p class="app-vide">Aucun compte.</p>';
  };
  document.addEventListener('gmb:discret', () => rendre());
  await rendre();
}

async function epargneComptes() {
  const ctx = await ouvrirEspace('comptes');
  const rendre = async () => {
    const liste = (await lireComptes(ctx)).filter((c) => ['livret', 'coffre'].includes(c.type));
    $('[data-epargne]').innerHTML = liste.length ? `<ul class="app-groupe">${liste.map((c) => ligneCompte(c)).join('')}</ul>`
      : '<p class="app-vide">Vous ne détenez pas encore de compte d’épargne. Le Livret GerMoon+ est inclus dans les formules Orbit, Éclipse et Zénith.</p>';
  };
  document.addEventListener('gmb:discret', () => rendre());
  await rendre();
}

/* -----------------------------------------------------------------------------
   Relevé d'identité bancaire : l'IBAN du compte quand l'établissement teneur du
   compte l'a attribué ; sinon, le numéro de compte et le compte de réception.
   -------------------------------------------------------------------------- */
async function rib() {
  const ctx = await ouvrirEspace('comptes');
  const [liste, banque] = await Promise.all([lireComptes(ctx), lire('parametres_banque', { colonnes: 'cle, valeur', dans: { cle: ['collecte_titulaire', 'collecte_iban', 'collecte_bic', 'collecte_banque'] } })]);
  const p = Object.fromEntries(banque.map((x) => [x.cle, x.valeur]));
  const paiement = trierComptes(liste.filter((c) => ['courant', 'pro', 'business', 'jeune', 'livret'].includes(c.type) && c.statut === 'actif'));
  if (!paiement.length) { $('[data-coordonnees]').innerHTML = '<p class="app-vide">Aucun compte actif.</p>'; return; }
  let compteId = paiement.some((k) => k.id === parametre('id')) ? parametre('id') : (paiement.find((k) => k.iban) || paiement[0]).id;
  const choix = $('[data-choix-compte]');
  choix.innerHTML = paiement.length > 1 ? `<nav class="app-sous-nav" aria-label="Choisir le compte"><ul>${paiement.map((k) => `<li><a href="${page('comptes/rib.html', `?id=${k.id}`)}" data-compte="${k.id}"${k.id === compteId ? ' aria-current="page"' : ''}>${e(nomCompte(k))}</a></li>`).join('')}</ul></nav>` : '';
  choix.addEventListener('click', (x) => {
    const a = x.target.closest('[data-compte]');
    if (!a) return;
    x.preventDefault(); compteId = a.dataset.compte; history.replaceState(null, '', a.href);
    $$('[data-compte]', choix).forEach((y) => (y === a ? y.setAttribute('aria-current', 'page') : y.removeAttribute('aria-current')));
    rendre();
  });
  const ligneCopie = (libelle, valeur, cle) => `<div><dt>${e(libelle)}</dt><dd><code data-valeur="${cle}">${e(valeur)}</code> <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-copier="${cle}">Copier</button></dd></div>`;
  const rendre = () => {
    const k = paiement.find((x) => x.id === compteId);
    const zone = $('[data-coordonnees]');
    if (k.iban) {
      const texte = `Titulaire : ${ctx.nom}\nIBAN : ${numeroLisible(k.iban)}${k.bic ? `\nBIC : ${k.bic}` : ''}`;
      zone.innerHTML = `<article class="app-document app-rib" aria-labelledby="t-rib"><header class="app-document__entete"><p><strong>GerMoonBank</strong></p><h2 id="t-rib">Relevé d’identité bancaire</h2><p>${e(nomCompte(k))} · n° ${e(numeroLisible(k.numero))}</p></header>
          <dl class="app-recap"><div><dt>Titulaire du compte</dt><dd>${e(ctx.nom)}</dd></div>${ligneCopie('IBAN', numeroLisible(k.iban), 'iban')}${k.bic ? ligneCopie('BIC', k.bic, 'bic') : ''}</dl></article>
        <div class="gmb-rangee app-document__actions"><button type="button" class="gmb-bouton gmb-bouton--principal" data-partager>${'share' in navigator ? 'Partager mon RIB' : 'Copier mon RIB'}</button><button type="button" class="gmb-bouton gmb-bouton--secondaire" data-imprimer>Imprimer ou enregistrer en PDF</button></div>`;
      $('[data-partager]').addEventListener('click', async (x) => {
        if ('share' in navigator) { try { await navigator.share({ title: 'Mon RIB GerMoonBank', text: texte }); return; } catch { /* partage annulé */ return; } }
        copier(texte, x.currentTarget);
      });
      $('[data-imprimer]').addEventListener('click', () => window.print());
    } else {
      zone.innerHTML = `<section class="gmb-carte gmb-pile gmb-pile--serree" aria-labelledby="t-interne"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-interne">Depuis un compte GerMoonBank</h2>
          <p>Communiquez votre numéro de compte : le virement est crédité immédiatement.</p><dl class="app-recap">${ligneCopie('Numéro de compte', k.numero, 'numero')}<div><dt>Titulaire</dt><dd>${e(ctx.nom)}</dd></div></dl></section>
        <section class="gmb-carte gmb-pile gmb-pile--serree" aria-labelledby="t-externe"><h2 class="gmb-section__titre gmb-section__titre--moyen" id="t-externe">Depuis une autre banque</h2>
          ${p.collecte_iban ? `<p>Faites envoyer le virement aux coordonnées ci-dessous, avec votre numéro de compte en référence : la somme est créditée sur votre compte dès sa réception.</p>
          <dl class="app-recap"><div><dt>Bénéficiaire</dt><dd>${e(p.collecte_titulaire || '—')}</dd></div>${ligneCopie('IBAN', numeroLisible(p.collecte_iban), 'iban')}
            ${p.collecte_bic ? ligneCopie('BIC', p.collecte_bic, 'bic') : ''}${p.collecte_banque ? `<div><dt>Banque</dt><dd>${e(p.collecte_banque)}</dd></div>` : ''}${ligneCopie('Référence (obligatoire)', k.numero, 'reference')}</dl>`
          : '<p>Les coordonnées de réception seront affichées ici. En attendant, écrivez à votre conseiller depuis la rubrique Messages.</p>'}</section>`;
    }
    $$('[data-copier]', zone).forEach((b) => b.addEventListener('click', () => copier($(`[data-valeur="${b.dataset.copier}"]`, zone).textContent.replace(/\s/g, ''), b)));
  };
  rendre();
}

/* Prélèvements SEPA : mandats signés auprès des créanciers, autorisés ou bloqués, révocables */
async function prelevements() {
  const ctx = await ouvrirEspace('comptes');
  const rendre = async () => {
    const [liste, mandats] = await Promise.all([lireComptes(ctx, 'id, type, libelle, numero, iban, statut'),
      ctx.comptes.length ? lire('mandats_prelevement', { dans: { compte_id: ctx.comptes }, ordre: 'created_at', croissant: false }).catch(() => []) : []]);
    const avecIban = liste.some((k) => k.iban && k.statut === 'actif');
    const zone = $('[data-mandats]');
    zone.innerHTML = mandats.length ? `<ul class="app-groupe">${mandats.map((m) => `<li><div class="app-ligne">${pastille('repeter', m.statut !== 'actif' ? 'ardoise' : m.liste === 'bloque' ? 'rose' : 'violet')}
        <span class="app-ligne__corps"><span class="app-ligne__titre">${e(m.creancier_nom)} ${m.statut === 'revoque' ? badge('Révoqué', 'neutre') : m.liste === 'bloque' ? badge('Bloqué', 'danger') : ''}</span>
        <span class="app-ligne__detail">RUM ${e(m.rum)} · ICS ${e(m.ics)}${m.plafond ? ` · plafond ${e(formaterMontant(m.plafond))}` : ''}</span></span>
        ${m.statut === 'actif' ? `<span class="gmb-rangee"><button type="button" class="gmb-bouton gmb-bouton--secondaire gmb-bouton--petit" data-mandat="${m.id}" data-action="${m.liste === 'bloque' ? 'autoriser' : 'bloquer'}">${m.liste === 'bloque' ? 'Autoriser' : 'Bloquer'}</button>
          <button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--danger gmb-bouton--petit" data-mandat="${m.id}" data-action="revoquer">Révoquer</button></span>` : ''}</div></li>`).join('')}</ul>`
      : `<div class="app-carte-scene">${pastille('repeter', 'violet', 'grande')}<h2 class="app-carte-scene__titre">Aucun prélèvement</h2>
          <p class="app-carte-scene__texte">${avecIban ? 'Pour mettre en place un prélèvement, communiquez votre RIB au créancier : son mandat apparaîtra ici, et vous pourrez le bloquer ou le révoquer à tout moment.'
            : 'Les prélèvements SEPA se mettent en place avec l’IBAN de votre compte. Vos factures se règlent en attendant par virement.'}</p>
          <p class="gmb-rangee"><a class="gmb-bouton gmb-bouton--secondaire" href="${page(avecIban ? 'comptes/rib.html' : 'comptes/virements.html')}">${avecIban ? 'Voir mon RIB' : 'Faire un virement'}</a></p></div>`;
  };
  $('[data-mandats]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-mandat]');
    if (!b) return;
    executer(b, async () => {
      const action = b.dataset.action;
      if (action === 'revoquer') {
        const ok = await demander('Révoquer ce mandat', [], { valider: 'Révoquer', danger: true, intro: 'Le créancier ne pourra plus prélever votre compte avec ce mandat. Pensez à le prévenir et à régler vos factures autrement.' });
        if (!ok) return;
        await modifier('mandats_prelevement', b.dataset.mandat, { statut: 'revoque', revoque_le: new Date().toISOString() });
      } else {
        await modifier('mandats_prelevement', b.dataset.mandat, { liste: action === 'bloquer' ? 'bloque' : 'autorise' });
      }
      await rendre();
    }, b.dataset.action === 'revoquer' ? 'Mandat révoqué.' : b.dataset.action === 'bloquer' ? 'Créancier bloqué : ses prélèvements seront refusés.' : 'Créancier autorisé.');
  });
  await rendre();
}

/* -----------------------------------------------------------------------------
   Cartes
   -------------------------------------------------------------------------- */
const REGLAGES = [['sans_contact', 'Paiement sans contact', 'sanscontact'], ['paiement_en_ligne', 'Paiements en ligne', 'globe'], ['retraits', 'Retraits aux distributeurs', 'banque'], ['etranger', 'Paiements et retraits à l’étranger', 'valise']];
const STATUTS_CARTE = { commandee: 'À activer', active: 'Active', gelee: 'Gelée', opposition: 'En opposition', expiree: 'Expirée' };
const STATUTS_COMMANDE = { demandee: 'Demande enregistrée', transmise: 'En cours d’émission', emise: 'Émise', refusee: 'Refusée', annulee: 'Annulée' };
const TYPES_CARTE = { physique: 'Carte physique', virtuelle: 'Carte virtuelle', ephemere: 'Carte éphémère' };
const COMPTES_CARTE = ['courant', 'jeune', 'pro', 'business'];
const EN_SERVICE = ['commandee', 'active', 'gelee'];
const PAYS = [['FR', 'France'], ['BE', 'Belgique'], ['LU', 'Luxembourg'], ['CH', 'Suisse'], ['MC', 'Monaco'], ['DE', 'Allemagne'], ['ES', 'Espagne'], ['IT', 'Italie'], ['PT', 'Portugal'], ['NL', 'Pays-Bas'],
  ['GB', 'Royaume-Uni'], ['BJ', 'Bénin'], ['BF', 'Burkina Faso'], ['CM', 'Cameroun'], ['CI', 'Côte d’Ivoire'], ['GA', 'Gabon'], ['ML', 'Mali'], ['NE', 'Niger'], ['SN', 'Sénégal'], ['TG', 'Togo'],
  ['MA', 'Maroc'], ['TN', 'Tunisie'], ['DZ', 'Algérie'], ['CA', 'Canada'], ['US', 'États-Unis']];

const nomCarte = (c) => `${TYPES_CARTE[c.type] || 'Carte'}${c.gamme ? ` ${c.gamme}` : ''}${c.statut !== 'commandee' && c.derniers_chiffres ? ` •••• ${c.derniers_chiffres}` : ''}`;
const ORDRE_TYPE = { physique: 0, virtuelle: 1, ephemere: 2 };
/* Cartes du client : la carte physique d'abord, puis les plus récentes */
const lireCartes = async (ctx) => (ctx.comptes.length ? (await lire('cartes', { dans: { compte_id: ctx.comptes }, ordre: 'created_at', croissant: false }))
  .sort((x, y) => (ORDRE_TYPE[x.type] ?? 3) - (ORDRE_TYPE[y.type] ?? 3)) : []);
const lireCommandes = () => lire('commandes_cartes', { ordre: 'created_at', croissant: false, limite: 30 }).catch(() => []);
const visuel = (c, ctx) => visuelCarte({ formule: c.gamme || ctx.formule, chiffres: c.derniers_chiffres, titulaire: ctx.nom, expiration: c.expiration, type: c.type === 'physique' ? 'physique' : 'virtuelle', statut: c.statut });
const badgeCarte = (c) => badge(STATUTS_CARTE[c.statut] || c.statut, c.statut === 'active' ? 'succes' : ['opposition', 'expiree'].includes(c.statut) ? 'danger' : 'neutre');
async function carteChoisie(ctx) {
  const liste = await lireCartes(ctx);
  return { liste, carte: liste.find((c) => c.id === parametre('id')) || liste.find((c) => ['active', 'gelee'].includes(c.statut)) || liste.find((c) => c.statut === 'commandee') || liste[0] };
}
/** Liste de cartes en visuel ; chaque carte ouvre sa page de réglages. */
const carrousel = (cartes, ctx) => `<ul class="app-cartes" aria-label="Vos cartes">${cartes.map((c) => `<li><a class="app-carte-lien" href="${page('cartes/detail.html', `?id=${c.id}`)}" aria-label="${e(nomCarte(c))}, ${e(STATUTS_CARTE[c.statut] || c.statut)}">${visuel(c, ctx)}
  <span class="app-carte-lien__bas"><span>${e(TYPES_CARTE[c.type] || 'Carte')}<small>${c.statut === 'commandee' ? 'À activer dès réception' : `Expire fin ${e(c.expiration)}`}</small></span>${badgeCarte(c)}</span></a></li>`).join('')}</ul>`;
/** Commandes en cours (annulables tant qu'elles ne sont pas transmises à l'émetteur). */
const blocCommandes = (commandes) => (commandes.length ? `<section class="app-bloc" aria-labelledby="t-commandes"><div class="app-bloc__entete"><h2 class="app-bloc__titre" id="t-commandes">Commandes en cours</h2></div>
  <ul class="app-groupe">${commandes.map((c) => `<li><div class="app-ligne">${pastille(c.type === 'physique' ? 'camion' : 'carte', c.type === 'physique' ? 'ambre' : 'violet')}
    <span class="app-ligne__corps"><span class="app-ligne__titre">${e(`${TYPES_CARTE[c.type]} ${c.gamme}`)}</span><span class="app-ligne__detail">${e(STATUTS_COMMANDE[c.statut])} · ${e(date(c.created_at, 'long'))}</span></span>
    ${c.statut === 'demandee' ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-annuler-commande="${c.id}">Annuler</button>` : ''}</div></li>`).join('')}</ul></section>` : '');
const sansCarte = (ctx, titre, texte, type = 'physique') => `<div class="app-carte-scene">${visuelCarte({ formule: ctx.formule, titulaire: ctx.nom, type, statut: 'apercu' })}
  <h2 class="app-carte-scene__titre">${e(titre)}</h2><p class="app-carte-scene__texte">${e(texte)}</p></div>`;
function annulationCommandes(zone, rendre) {
  zone.addEventListener('click', (x) => {
    const b = x.target.closest('[data-annuler-commande]');
    if (b) executer(b, async () => { await appeler('gmb_carte_commande_annuler', { p_commande: b.dataset.annulerCommande }); await rendre(); }, 'Commande annulée.');
  });
}

async function cartesIndex() {
  const ctx = await ouvrirEspace('cartes');
  const rendre = async () => {
    const [liste, commandes] = await Promise.all([lireCartes(ctx), lireCommandes()]);
    const enService = liste.filter((c) => EN_SERVICE.includes(c.statut));
    const enCours = commandes.filter((c) => ['demandee', 'transmise'].includes(c.statut));
    $('[data-cartes]').innerHTML = enService.length ? carrousel(enService, ctx)
      : sansCarte(ctx, enCours.length ? 'Votre carte est en préparation' : 'Votre carte GerMoonBank', enCours.length ? 'Vous serez prévenu dès son émission.' : 'Commandez votre carte physique, ou créez une carte virtuelle pour payer en ligne.');
    $('[data-commandes]').innerHTML = blocCommandes(enCours);
    const anciennes = liste.filter((c) => !EN_SERVICE.includes(c.statut));
    $('[data-anciennes]').innerHTML = anciennes.length ? `<section class="app-bloc" aria-labelledby="t-anciennes"><div class="app-bloc__entete"><h2 class="app-bloc__titre" id="t-anciennes">Cartes inactives</h2></div>
      <ul class="app-groupe">${anciennes.map((c) => `<li><a class="app-ligne app-ligne--lien" href="${page('cartes/detail.html', `?id=${c.id}`)}">${pastille('carte', 'ardoise')}<span class="app-ligne__corps"><span class="app-ligne__titre">${e(nomCarte(c))}</span><span class="app-ligne__detail">${e(STATUTS_CARTE[c.statut] || c.statut)}</span></span>${iconeEc('chevronDroite', 18)}</a></li>`).join('')}</ul></section>` : '';
  };
  annulationCommandes($('[data-commandes]'), rendre);
  await rendre();
}

async function carteDetail() {
  const ctx = await ouvrirEspace('cartes');
  const zone = $('[data-carte]');
  const rendre = async () => {
    const { carte: c } = await carteChoisie(ctx);
    if (!c) { zone.innerHTML = `${sansCarte(ctx, 'Aucune carte', 'Commandez votre carte physique, ou créez une carte virtuelle.')}<p class="gmb-rangee"><a class="gmb-bouton gmb-bouton--principal" href="${page('cartes/commande.html')}">Commander une carte</a></p>`; return; }
    const compte = await lire('comptes', { colonnes: 'id, type, libelle, numero', egal: { id: c.compte_id }, unique: true }).catch(() => null);
    const modifiable = ['active', 'gelee'].includes(c.statut);
    zone.innerHTML = `<div class="app-carte-page"><div class="app-carte-page__colonne"><div class="app-carte-scene">${visuel(c, ctx)}<p class="app-carte-scene__texte"><strong>${e(nomCarte(c))}</strong> ${badgeCarte(c)}</p></div>
      ${c.statut === 'commandee' ? `<form class="gmb-carte gmb-pile gmb-pile--moyenne" data-form="activer" novalidate><h2 class="gmb-section__titre gmb-section__titre--moyen">Activer votre carte</h2>
          <p>Dès réception, saisissez les 4 derniers chiffres imprimés sur votre carte : elle sera aussitôt utilisable.</p>
          <div class="gmb-champ"><label class="gmb-champ__libelle" for="chiffres">4 derniers chiffres de la carte</label><input class="gmb-saisie" id="chiffres" name="chiffres" type="text" inputmode="numeric" maxlength="4" autocomplete="off"><p class="gmb-champ__erreur" hidden></p></div>
          <div class="gmb-rangee"><button type="submit" class="gmb-bouton gmb-bouton--principal">Activer la carte</button></div></form>` : ''}
      ${modifiable ? `<nav class="app-carte-actions" aria-label="Gérer la carte">
          <button type="button" class="app-action" data-reglage="gelee" data-valeur="${c.statut === 'gelee' ? 'false' : 'true'}" aria-pressed="${c.statut === 'gelee'}"><span class="app-action__icone">${iconeEc('flocon', 22)}</span><span class="app-action__libelle">${c.statut === 'gelee' ? 'Dégeler' : 'Geler'}</span></button>
          <a class="app-action" href="${page('cartes/plafonds.html', `?id=${c.id}`)}"><span class="app-action__icone">${iconeEc('reglages', 22)}</span><span class="app-action__libelle">Plafonds</span></a>
          <a class="app-action" href="${page('cartes/etranger.html', `?id=${c.id}`)}"><span class="app-action__icone">${iconeEc('globe', 22)}</span><span class="app-action__libelle">Étranger</span></a>
          <a class="app-action app-action--danger" href="${page('cartes/opposition.html')}"><span class="app-action__icone">${iconeEc('alerte', 22)}</span><span class="app-action__libelle">Opposition</span></a></nav>` : ''}</div>
      <div class="app-carte-page__colonne">${modifiable ? `<section class="app-bloc" aria-labelledby="t-utilisations"><div class="app-bloc__entete"><h2 class="app-bloc__titre" id="t-utilisations">Utilisations</h2></div>
          <ul class="app-groupe">${REGLAGES.map(([cle, libelle, ic]) => `<li><div class="app-ligne">${pastille(ic, 'violet')}<span class="app-ligne__corps"><span class="app-ligne__titre" id="r-${cle}">${e(libelle)}</span></span>
            <button type="button" class="app-interrupteur" role="switch" aria-checked="${Boolean(c[cle])}" aria-labelledby="r-${cle}" data-reglage="${cle}" data-valeur="${c[cle] ? 'false' : 'true'}"></button></div></li>`).join('')}</ul></section>` : ''}
      <section class="app-bloc" aria-labelledby="t-infos"><div class="app-bloc__entete"><h2 class="app-bloc__titre" id="t-infos">Informations</h2></div>
        <dl class="app-recap"><div><dt>Type</dt><dd>${e(TYPES_CARTE[c.type] || c.type)}</dd></div><div><dt>Formule</dt><dd>${e(c.gamme || '—')}</dd></div>
          <div><dt>Titulaire</dt><dd>${e(ctx.nom)}</dd></div><div><dt>Expiration</dt><dd>${e(c.expiration || '—')}</dd></div>
          <div><dt>Compte débité</dt><dd>${e(compte ? `${nomCompte(compte)} n° ${numeroLisible(compte.numero)}` : '—')}</dd></div>
          <div><dt>Plafond de paiement</dt><dd>${e(formaterMontant(c.plafond_paiement_30j))} sur 30 jours</dd></div>
          <div><dt>Plafond de retrait</dt><dd>${e(formaterMontant(c.plafond_retrait_7j))} sur 7 jours</dd></div></dl></section></div></div>`;
    $$('[data-reglage]', zone).forEach((b) => b.addEventListener('click', () => executer(b, async () => {
      await appeler('gmb_carte_regler', { p_carte: c.id, p_reglage: b.dataset.reglage, p_valeur: b.dataset.valeur === 'true' });
      await rendre();
    }, b.dataset.reglage === 'gelee' ? (b.dataset.valeur === 'true' ? 'Carte gelée : aucun paiement ni retrait n’est accepté.' : 'Carte dégelée.') : 'Réglage enregistré.')));
    const activer = $('[data-form="activer"]', zone);
    activer?.addEventListener('submit', (x) => {
      x.preventDefault();
      executer(activer.querySelector('[type=submit]'), async () => {
        const chiffres = activer.elements.chiffres.value.trim();
        if (!/^\d{4}$/.test(chiffres)) throw new ErreurGmb('Saisissez les 4 derniers chiffres imprimés sur votre carte.');
        await appeler('gmb_carte_activer', { p_carte: c.id, p_chiffres: chiffres });
        await rendre();
      }, 'Carte activée : elle est prête à l’emploi.');
    });
  };
  await rendre();
}

/* Commande d'une carte physique ou d'une carte virtuelle, confirmée par le code secret */
async function commandeCarte() {
  const ctx = await ouvrirEspace('cartes');
  const [comptesCarte, personne, formule, cartes, commandes] = await Promise.all([
    lireComptes(ctx, 'id, type, libelle, numero, statut').then((l) => l.filter((k) => COMPTES_CARTE.includes(k.type) && k.statut === 'actif')),
    ctx.client.personne_id ? lire('personnes', { colonnes: 'adresse_ligne1, adresse_ligne2, code_postal, ville, pays', egal: { id: ctx.client.personne_id }, unique: true }).catch(() => null) : null,
    ctx.formule ? lire('formules', { colonnes: 'code, nom, carte, cartes_physiques, cartes_virtuelles', egal: { code: ctx.formule }, unique: true }).catch(() => null) : null,
    lireCartes(ctx), lireCommandes(),
  ]);
  const form = $('[data-form="commande"]');
  if (!comptesCarte.length) { form.innerHTML = '<p class="app-vide">Une carte se rattache à un compte de paiement actif : vous n’en avez pas.</p>'; return; }
  form.elements.type.value = parametre('type') === 'virtuelle' ? 'virtuelle' : 'physique';
  form.elements.compte.innerHTML = comptesCarte.map((k) => `<option value="${k.id}">${e(nomCompte(k))} · n° ${e(numeroLisible(k.numero))}</option>`).join('');
  $('[data-champ-compte]').hidden = comptesCarte.length < 2;
  form.elements.pays.innerHTML = PAYS.map(([v, t]) => `<option value="${v}">${e(t)}</option>`).join('');
  form.elements.ligne1.value = personne?.adresse_ligne1 || '';
  form.elements.ligne2.value = personne?.adresse_ligne2 || '';
  form.elements.code_postal.value = personne?.code_postal || '';
  form.elements.ville.value = personne?.ville || '';
  form.elements.pays.value = PAYS.some(([v]) => v === personne?.pays) ? personne.pays : 'FR';
  const nomFormule = formule?.nom || '';
  const restantes = (type) => {
    const max = type === 'physique' ? (formule?.cartes_physiques ?? 1) : (formule?.cartes_virtuelles ?? 1);
    const utilisees = cartes.filter((c) => c.type === type && EN_SERVICE.includes(c.statut)).length + commandes.filter((c) => c.type === type && ['demandee', 'transmise'].includes(c.statut)).length;
    return { max, reste: Math.max(0, max - utilisees) };
  };
  const majApercu = () => {
    const type = form.elements.type.value;
    const { max, reste } = restantes(type);
    $('[data-apercu]').innerHTML = visuelCarte({ formule: nomFormule || ctx.formule, titulaire: ctx.nom, type, statut: 'apercu' });
    $('[data-inclus]').textContent = nomFormule ? `${max === 1 ? `Une carte ${type}` : `${max} cartes ${type}s`} incluse${max > 1 ? 's' : ''} dans votre formule ${nomFormule}${reste < max ? ` · ${reste} disponible${reste > 1 ? 's' : ''}` : ''}` : '';
    $('[data-livraison]').hidden = type !== 'physique';
    const bouton = form.querySelector('[type=submit]');
    bouton.textContent = type === 'physique' ? 'Commander la carte' : 'Créer la carte virtuelle';
    bouton.disabled = reste === 0;
    $('[data-epuise]').hidden = reste > 0;
    $('[data-epuise]').textContent = reste > 0 ? '' : `Votre formule ${nomFormule} comprend ${max === 1 ? `une carte ${type} : elle est déjà émise ou commandée` : `${max} cartes ${type}s : elles sont toutes déjà émises ou commandées`}.`;
  };
  form.addEventListener('change', (x) => { if (x.target.name === 'type') majApercu(); });
  majApercu();
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const type = form.elements.type.value;
      const compte = comptesCarte.find((k) => k.id === form.elements.compte.value);
      const livraison = type === 'physique' ? { nom: ctx.nom, ligne1: form.elements.ligne1.value.trim(), ligne2: form.elements.ligne2.value.trim(), code_postal: form.elements.code_postal.value.trim(), ville: form.elements.ville.value.trim(), pays: form.elements.pays.value } : null;
      if (livraison && (livraison.ligne1.length < 3 || livraison.code_postal.length < 2 || livraison.ville.length < 2)) throw new ErreurGmb('Indiquez l’adresse de livraison complète : rue, code postal et ville.');
      const lignes = [['Carte', e(`${TYPES_CARTE[type]}${nomFormule ? ` ${nomFormule}` : ''}`)], ['Compte débité', e(`${nomCompte(compte)} n° ${numeroLisible(compte.numero)}`)]];
      if (livraison) lignes.push(['Livraison', e([livraison.ligne1, livraison.ligne2, `${livraison.code_postal} ${livraison.ville}`, PAYS.find(([v]) => v === livraison.pays)?.[1]].filter(Boolean).join(', '))]);
      const code = await authentifier(type === 'physique' ? 'Confirmer la commande' : 'Confirmer la création', lignes, ctx.client.identifiant);
      if (!code) return;
      const r = await appeler('gmb_carte_commander', { p_compte: compte.id, p_type: type, p_livraison: livraison, p_grille: code.grille, p_positions: code.positions });
      await refusSca(r);
      $('[data-commande]').innerHTML = `<div class="app-carte-scene">${visuelCarte({ formule: nomFormule || ctx.formule, titulaire: ctx.nom, type, statut: 'apercu' })}
        <h2 class="app-carte-scene__titre">${type === 'physique' ? 'Commande enregistrée' : 'Demande enregistrée'}</h2>
        <p class="app-carte-scene__texte">${type === 'physique' ? 'Votre carte sera fabriquée puis envoyée à l’adresse indiquée. Vous serez prévenu de son envoi ; activez-la dès réception.' : 'Votre carte virtuelle sera disponible dans la rubrique Cartes dès son émission : vous serez prévenu.'}</p>
        <p class="gmb-rangee"><a class="gmb-bouton gmb-bouton--principal" href="${page('cartes/index.html')}">Voir mes cartes</a></p></div>`;
    });
  });
}

async function cartesVirtuelles() {
  const ctx = await ouvrirEspace('cartes');
  const rendre = async () => {
    const [liste, commandes] = await Promise.all([lireCartes(ctx), lireCommandes()]);
    const virtuelles = liste.filter((c) => ['virtuelle', 'ephemere'].includes(c.type) && EN_SERVICE.includes(c.statut));
    const enCours = commandes.filter((c) => c.type === 'virtuelle' && ['demandee', 'transmise'].includes(c.statut));
    $('[data-cartes]').innerHTML = virtuelles.length ? carrousel(virtuelles, ctx)
      : sansCarte(ctx, enCours.length ? 'Votre carte virtuelle est en préparation' : 'Aucune carte virtuelle', enCours.length ? 'Vous serez prévenu dès son émission.' : 'Une carte virtuelle sert à payer en ligne en toute sécurité : ses chiffres restent dans votre application, et vous la gelez d’un geste.', 'virtuelle');
    $('[data-commandes]').innerHTML = blocCommandes(enCours);
  };
  annulationCommandes($('[data-commandes]'), rendre);
  await rendre();
}

async function plafonds() {
  const ctx = await ouvrirEspace('cartes');
  const { carte: c } = await carteChoisie(ctx);
  const form = $('[data-form="plafonds"]');
  if (!c || !['active', 'gelee'].includes(c.statut)) { $('[data-sans-carte]').innerHTML = c ? '<p class="app-vide">Cette carte ne peut pas être modifiée.</p>' : sansCarte(ctx, 'Aucune carte', 'Commandez une carte pour régler ses plafonds.'); form.hidden = true; return; }
  $('[data-sans-carte]').innerHTML = `<div class="app-carte-scene">${visuel(c, ctx)}<p class="app-carte-scene__texte"><strong>${e(nomCarte(c))}</strong></p></div>`;
  form.elements.paiement.value = String(c.plafond_paiement_30j ?? '').replace('.', ',');
  form.elements.retrait.value = String(c.plafond_retrait_7j ?? '').replace('.', ',');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const n = (v) => Number(String(v).replace(/\s/g, '').replace(',', '.'));
      const p = n(form.elements.paiement.value), r = n(form.elements.retrait.value);
      if (!(p >= 50 && p <= 10000)) throw new ErreurGmb('Le plafond de paiement va de 50 € à 10 000 € sur 30 jours.');
      if (!(r >= 20 && r <= 3000)) throw new ErreurGmb('Le plafond de retrait va de 20 € à 3 000 € sur 7 jours.');
      await appeler('gmb_carte_plafonds', { p_carte: c.id, p_paiement: p, p_retrait: r });
    }, 'Plafonds enregistrés.');
  });
}

async function carteEtranger() {
  const ctx = await ouvrirEspace('cartes');
  const rendre = async () => {
    const { carte: c } = await carteChoisie(ctx);
    const zone = $('[data-etranger]');
    if (!c || !['active', 'gelee'].includes(c.statut)) { zone.innerHTML = c ? '<p class="app-vide">Cette carte ne peut pas être modifiée.</p>' : sansCarte(ctx, 'Aucune carte', 'Commandez une carte pour l’utiliser à l’étranger.'); return; }
    zone.innerHTML = `<div class="app-carte-scene">${visuel(c, ctx)}<p class="app-carte-scene__texte"><strong>${e(nomCarte(c))}</strong></p></div>
      <ul class="app-groupe"><li><div class="app-ligne">${pastille('valise', 'ciel')}<span class="app-ligne__corps"><span class="app-ligne__titre" id="r-etranger">Paiements et retraits à l’étranger</span>
        <span class="app-ligne__detail">${c.etranger ? 'Autorisés' : 'Désactivés'}</span></span><button type="button" class="app-interrupteur" role="switch" aria-checked="${Boolean(c.etranger)}" aria-labelledby="r-etranger" data-etranger-valeur="${c.etranger ? 'false' : 'true'}"></button></div></li></ul>`;
    $('[data-etranger-valeur]', zone).addEventListener('click', (x) => executer(x.currentTarget, async () => {
      await appeler('gmb_carte_regler', { p_carte: c.id, p_reglage: 'etranger', p_valeur: x.currentTarget.dataset.etrangerValeur === 'true' });
      await rendre();
    }, 'Réglage enregistré.'));
  };
  await rendre();
}

/* Opposition définitive (perte, vol, fraude) : depuis Comptes ou Cartes */
async function oppositions(rubrique = 'comptes') {
  const ctx = await ouvrirEspace(rubrique);
  const rendre = async () => {
    const cartes = (await lireCartes(ctx)).filter((c) => c.statut !== 'expiree');
    $('[data-cartes]').innerHTML = cartes.length ? `<ul class="app-groupe">${cartes.map((c) => `<li><div class="app-ligne">${pastille('carte', c.statut === 'opposition' ? 'ardoise' : 'violet')}
        <span class="app-ligne__corps"><span class="app-ligne__titre">${e(nomCarte(c))}</span><span class="app-ligne__detail">${e(STATUTS_CARTE[c.statut] || c.statut)}${c.expiration ? ` · expire fin ${e(c.expiration)}` : ''}</span></span>
        ${EN_SERVICE.includes(c.statut) ? `<button type="button" class="gmb-bouton gmb-bouton--danger gmb-bouton--petit" data-opposition="${c.id}" data-nom="${e(nomCarte(c))}">Faire opposition</button>` : badge('En opposition', 'danger')}</div></li>`).join('')}</ul>`
      : '<p class="app-vide">Vous n’avez aucune carte.</p>';
  };
  $('[data-cartes]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-opposition]');
    if (!b) return;
    executer(b, async () => {
      const r = await demander(`Opposition : ${b.dataset.nom}`, [{ nom: 'motif', libelle: 'Motif', options: [['perte', 'Carte perdue'], ['vol', 'Carte volée'], ['fraude', 'Utilisation frauduleuse'], ['autre', 'Autre motif']] }],
        { valider: 'Confirmer l’opposition', danger: true, intro: 'L’opposition est définitive : la carte ne pourra plus jamais être utilisée. Pour un simple blocage temporaire, gelez la carte depuis la rubrique Cartes.' });
      if (!r) return;
      await appeler('gmb_carte_opposition', { p_carte: b.dataset.opposition, p_motif: r.motif });
      await rendre();
    }, 'Opposition enregistrée : la carte est définitivement bloquée. En cas de vol ou de fraude, déposez aussi plainte.');
  });
  await rendre();
}

async function statiqueCartes() { await ouvrirEspace('cartes'); }
async function statique() { await ouvrirEspace('comptes'); }
demarrerPage({
  comptes, 'epargne-comptes': epargneComptes, rib, oppositions: () => oppositions('comptes'), joint: statique, chequier: statique, prelevements,
  cartes: cartesIndex, carte: carteDetail, plafonds, virtuelles: cartesVirtuelles, 'cartes-etranger': carteEtranger, 'opposition-carte': () => oppositions('cartes'),
  'commande-carte': commandeCarte, 'assurances-carte': statiqueCartes,
});
