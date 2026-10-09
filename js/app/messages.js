/* =============================================================================
   GerMoonBank (GMB) · js/app/messages.js — Messages et conseiller (lot E2b)
   Messagerie avec le service clients, réclamations (délais légaux), rendez-vous
   par téléphone ou vidéo, discussion instantanée. Le « conseiller » est le
   service clients GerMoonBank : aucun conseiller nommé n'est attribué.
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, e, date, parametre, page, badge, tableau, executer, message } from './app.js';
import { lire, appeler, ErreurGmb, oublierContexte } from '../donnees.js';
import { icone } from '../core.js';

const SUJET_CHAT = 'Discussion instantanée';
const HORAIRES = 'du lundi au vendredi, de 9 h à 18 h (heure de Paris)';
const STATUTS_FIL = { ouvert: ['En attente de réponse', 'neutre'], en_attente_client: ['Réponse reçue', 'succes'], clos: ['Clos', 'neutre'] };
const STATUTS_RECLAMATION = { recue: ['Reçue', 'neutre'], en_cours: ['En cours de traitement', 'neutre'], repondue: ['Répondue', 'succes'], close: ['Close', 'neutre'] };
const STATUTS_RDV = { demande: ['Demandé', 'neutre'], confirme: ['Confirmé', 'succes'], annule: ['Annulé', 'neutre'], termine: ['Terminé', 'neutre'] };
const CATEGORIES = [['compte', 'Mon compte'], ['paiement', 'Un paiement ou un virement'], ['carte', 'Ma carte'], ['credit', 'Mon crédit'], ['autre', 'Un autre sujet']];
const AUTEURS = { client: 'Vous', conseiller: 'Service clients', assistant: 'Assistant', systeme: 'GerMoonBank' };
const heure = (d) => new Date(d).toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
const bulles = (liste) => (liste.length ? `<ol class="app-fil app-fil--messages">${liste.map((m) => `<li class="app-fil__message app-fil__message--${e(m.auteur)}"><p>${e(m.contenu)}</p><small>${e(AUTEURS[m.auteur] || m.auteur)} · ${date(m.created_at, 'long')} à ${heure(m.created_at)}</small></li>`).join('')}</ol>` : '<p class="app-vide">Aucun message pour le moment.</p>');

/** Une date-heure saisie « à l'heure de Paris » (AAAA-MM-JJTHH:MM) convertie en instant ISO. */
function parisVersIso(valeur) {
  const [j, h] = String(valeur).split('T');
  if (!j || !h) return null;
  const [a, mo, d] = j.split('-').map(Number); const [hh, mi] = h.split(':').map(Number);
  const brut = new Date(Date.UTC(a, mo - 1, d, hh, mi));
  const decalage = (instant) => {
    const t = new Intl.DateTimeFormat('en-US', { timeZone: 'Europe/Paris', timeZoneName: 'shortOffset' }).formatToParts(instant).find((x) => x.type === 'timeZoneName')?.value || 'GMT+1';
    const m = t.match(/GMT([+-]\d+)(?::(\d+))?/); return m ? Number(m[1]) * 60 + Math.sign(Number(m[1])) * Number(m[2] || 0) : 60;
  };
  return new Date(brut.getTime() - decalage(brut) * 60_000).toISOString();
}

/** Rafraîchit une vue tant que la page est visible. */
function surveiller(rendre, secondes) {
  let minuteur = setInterval(() => { if (document.visibilityState === 'visible') rendre().catch(() => {}); }, secondes * 1000);
  addEventListener('pagehide', () => clearInterval(minuteur), { once: true });
}

/* Messages : conversations et réclamations ----------------------------------- */
async function messagesIndex() {
  await ouvrirEspace('messages');
  const [fils, reclamations] = await Promise.all([lire('fils_messagerie', { ordre: 'updated_at', croissant: false }), lire('reclamations', { ordre: 'created_at', croissant: false })]);
  const recus = fils.length ? await lire('messages', { colonnes: 'fil_id, auteur, lu_le', dans: { fil_id: fils.map((f) => f.id) } }) : [];
  const nonLus = (id) => recus.filter((m) => m.fil_id === id && m.auteur !== 'client' && !m.lu_le).length;
  $('[data-fils]').innerHTML = fils.length ? `<ul class="app-lignes">${fils.map((f) => {
    const n = nonLus(f.id); const adresse = f.sujet === SUJET_CHAT ? page('conseiller/chat.html') : page('messages/conversation.html', `?fil=${f.id}`);
    return `<li><a href="${adresse}"><strong>${e(f.sujet)}</strong></a> ${badge(...(STATUTS_FIL[f.statut] || [f.statut, 'neutre']))}${n ? ` ${badge(`${n} non lu${n > 1 ? 's' : ''}`, 'succes')}` : ''} <small>${date(f.updated_at || f.created_at, 'long')}</small></li>`;
  }).join('')}</ul>` : '<p class="app-vide">Aucune conversation. Écrivez-nous : nous répondons ' + HORAIRES + '.</p>';
  $('[data-reclamations]').innerHTML = tableau('Vos réclamations', ['Référence', 'Objet', 'Statut', 'Réponse au plus tard'], reclamations.map((r) => [e(r.reference), e(r.objet),
    badge(...(STATUTS_RECLAMATION[r.statut] || [r.statut, 'neutre'])), r.repondue_le ? `Répondue le ${date(r.repondue_le, 'long')}` : date(r.reponse_avant, 'long')]), 'Aucune réclamation.');
  const repondues = reclamations.filter((r) => r.reponse);
  $('[data-reponses]').innerHTML = repondues.map((r) => `<article class="gmb-carte gmb-pile gmb-pile--serree"><h3 class="gmb-section__titre gmb-section__titre--moyen">Réponse à ${e(r.reference)}</h3><p>${e(r.reponse)}</p>${r.mediateur_info ? `<p class="gmb-mention-obligatoire">${e(r.mediateur_info)}</p>` : ''}</article>`).join('');
}

/* Nouveau message ou réclamation --------------------------------------------- */
async function nouveau() {
  await ouvrirEspace('messages');
  const form = $('[data-form="message"]');
  form.elements.categorie.innerHTML = CATEGORIES.map(([v, l]) => `<option value="${v}">${e(l)}</option>`).join('');
  const adapter = () => { const rec = form.elements.type.value === 'reclamation'; $('[data-si="question"]').hidden = rec; $('[data-si="reclamation"]').hidden = !rec; };
  if (parametre('type') === 'reclamation') form.elements.type.value = 'reclamation';
  form.addEventListener('change', adapter); adapter();
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const contenu = form.elements.contenu.value.trim();
      if (contenu.length < 2) throw new ErreurGmb('Écrivez votre message.');
      if (form.elements.type.value === 'reclamation') {
        const objet = form.elements.objet.value.trim();
        if (objet.length < 3) throw new ErreurGmb('Indiquez l’objet de votre réclamation.');
        const r = await appeler('gmb_reclamation_creer', { p_objet: objet, p_description: contenu, p_categorie: form.elements.categorie.value });
        form.hidden = true;
        $('[data-resultat]').innerHTML = `<div class="gmb-carte gmb-pile gmb-pile--serree"><h2 class="gmb-section__titre gmb-section__titre--moyen">Réclamation ${e(r.reference)} enregistrée</h2>
          <dl class="app-recap"><div><dt>Accusé de réception au plus tard le</dt><dd>${date(r.accuse_avant, 'long')}</dd></div><div><dt>Réponse au plus tard le</dt><dd>${date(r.reponse_avant, 'long')}</dd></div></dl>
          <p><a href="${page('messages/index.html')}">Suivre vos réclamations</a></p></div>`;
        return;
      }
      const sujet = form.elements.sujet.value.trim();
      const fil = await appeler('gmb_message_envoyer', { p_contenu: contenu, p_sujet: sujet });
      location.href = page('messages/conversation.html', `?fil=${fil}&envoye=1`);
    });
  });
}

/* Conversation ---------------------------------------------------------------- */
async function conversation() {
  await ouvrirEspace('messages');
  const id = parametre('fil');
  const zone = $('[data-conversation]'); const form = $('[data-form="reponse"]');
  if (parametre('envoye')) message('Message envoyé : nous vous répondons ' + HORAIRES + '.', 'succes');
  let dernier = 0;
  const rendre = async () => {
    const fil = await lire('fils_messagerie', { egal: { id }, unique: true });
    if (!fil) { zone.innerHTML = `<p class="app-vide">Conversation introuvable.</p><p><a href="${page('messages/index.html')}">Vos messages</a></p>`; form.hidden = true; return; }
    const liste = await lire('messages', { egal: { fil_id: id }, ordre: 'created_at', croissant: true });
    $('[data-sujet]').innerHTML = `${e(fil.sujet)} ${badge(...(STATUTS_FIL[fil.statut] || [fil.statut, 'neutre']))}`;
    if (liste.length !== dernier) { zone.innerHTML = bulles(liste); dernier = liste.length; zone.lastElementChild?.lastElementChild?.scrollIntoView?.({ block: 'nearest' }); }
    $('[data-clore]').hidden = fil.statut === 'clos';
    if (liste.some((m) => m.auteur !== 'client' && !m.lu_le)) await appeler('gmb_messages_lus', { p_fil: id });
  };
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const contenu = form.elements.contenu.value.trim();
      if (contenu.length < 2) throw new ErreurGmb('Écrivez votre message.');
      await appeler('gmb_message_envoyer', { p_contenu: contenu, p_fil: id });
      form.reset(); await rendre();
    }, 'Message envoyé.');
  });
  $('[data-clore]').addEventListener('click', (x) => executer(x.currentTarget, async () => { await appeler('gmb_fil_clore', { p_fil: id }); await rendre(); }, 'Conversation close. Un nouveau message la rouvrira.'));
  await rendre();
  surveiller(rendre, 15);
}

/* Conseiller : le service clients ---------------------------------------------- */
async function conseiller() {
  await ouvrirEspace('messages');
  const rdv = (await lire('rendez_vous_clients', { ordre: 'debut', croissant: true })).filter((r) => ['demande', 'confirme'].includes(r.statut) && new Date(r.debut) > new Date());
  $('[data-prochain]').innerHTML = rdv.length ? `<p>${icone('info')} Prochain rendez-vous : <strong>${date(rdv[0].debut, 'long')} à ${heure(rdv[0].debut)}</strong> (${rdv[0].canal === 'video' ? 'vidéo' : 'téléphone'}) · ${badge(...STATUTS_RDV[rdv[0].statut])}</p>` : '<p class="app-vide">Aucun rendez-vous prévu.</p>';
}

/* Rendez-vous ------------------------------------------------------------------- */
async function rendezVous() {
  await ouvrirEspace('messages');
  const form = $('[data-form="rdv"]');
  const rendre = async () => {
    const liste = await lire('rendez_vous_clients', { ordre: 'debut', croissant: false });
    $('[data-rdv]').innerHTML = tableau('Vos rendez-vous', ['Date', 'Canal', 'Objet', 'Statut', ''], liste.map((r) => [`${date(r.debut, 'long')} à ${heure(r.debut)}`, e(r.canal === 'video' ? 'Vidéo' : 'Téléphone'), e(r.motif),
      badge(...(STATUTS_RDV[r.statut] || [r.statut, 'neutre'])), ['demande', 'confirme'].includes(r.statut) && new Date(r.debut) > new Date() ? `<button type="button" class="gmb-bouton gmb-bouton--fantome gmb-bouton--petit" data-annuler="${r.id}">Annuler</button>` : '']), 'Aucun rendez-vous.');
  };
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const debut = parisVersIso(form.elements.quand.value);
      if (!debut) throw new ErreurGmb('Choisissez la date et l’heure.');
      const motif = form.elements.motif.value.trim();
      if (motif.length < 3) throw new ErreurGmb('Indiquez l’objet du rendez-vous.');
      await appeler('gmb_rdv_demander', { p_debut: debut, p_canal: form.elements.canal.value, p_motif: motif });
      form.reset(); await rendre();
    }, 'Rendez-vous demandé : vous serez prévenu dès sa confirmation.');
  });
  $('[data-rdv]').addEventListener('click', (x) => {
    const b = x.target.closest('[data-annuler]');
    if (b) executer(b, async () => { await appeler('gmb_rdv_annuler', { p_id: b.dataset.annuler }); await rendre(); }, 'Rendez-vous annulé.');
  });
  await rendre();
}

/* Discussion instantanée ------------------------------------------------------------ */
async function chat() {
  await ouvrirEspace('messages');
  const zone = $('[data-chat]'); const form = $('[data-form="chat"]');
  let fil = null; let dernier = -1;
  const rendre = async () => {
    const fils = await lire('fils_messagerie', { egal: { sujet: SUJET_CHAT }, ordre: 'updated_at', croissant: false });
    fil = fils.find((f) => f.statut !== 'clos') || null;
    const liste = fil ? await lire('messages', { egal: { fil_id: fil.id }, ordre: 'created_at', croissant: true }) : [];
    if (liste.length !== dernier) { zone.innerHTML = liste.length ? bulles(liste) : '<p class="app-vide">Écrivez votre question : un conseiller vous répond ' + HORAIRES + '. En dehors de ces horaires, votre message est traité dès la réouverture.</p>'; dernier = liste.length; }
    if (fil && liste.some((m) => m.auteur !== 'client' && !m.lu_le)) await appeler('gmb_messages_lus', { p_fil: fil.id });
  };
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const contenu = form.elements.contenu.value.trim();
      if (contenu.length < 2) throw new ErreurGmb('Écrivez votre message.');
      const nouveauFil = !fil;
      await appeler('gmb_message_envoyer', fil ? { p_contenu: contenu, p_fil: fil.id } : { p_contenu: contenu, p_sujet: SUJET_CHAT });
      // Un fil créé après le chargement de la page : la liste des fils mémorisée est renouvelée
      if (nouveauFil) oublierContexte();
      form.reset(); await rendre();
    });
  });
  await rendre();
  surveiller(rendre, 4);
}

demarrerPage({ messages: messagesIndex, 'nouveau-message': nouveau, conversation, conseiller, 'rendez-vous': rendezVous, chat });
