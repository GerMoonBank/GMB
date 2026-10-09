/* =============================================================================
   GerMoonBank (GMB) · js/app/invest.js — Placements
   Page Placements (simulateur, épargne, guides) ; le simulateur calcule une
   projection hypothétique, frais déduits. Les anciennes pages d'ordres, de
   positions et de crypto-actifs renvoient vers la page Placements.
   ========================================================================== */
import { ouvrirEspace, demarrerPage, $, e, page, executer, tableau } from './app.js';
import { ErreurGmb } from '../donnees.js';
import { formaterMontant } from '../core.js';

const lecture = async () => { await ouvrirEspace('placements'); };
const versPlacements = () => { location.replace(page('investissement/index.html')); };
const nombre = (v) => Number(String(v).replace(/\s/g, '').replace(',', '.'));

/** Capital après n mois : capitalisation mensuelle, versements en fin de mois. */
export function projeter(initial, mensuel, annees, rendementPct, fraisPct) {
  const annuel = (1 + rendementPct / 100) * (1 - fraisPct / 100) - 1;
  const r = Math.pow(1 + annuel, 1 / 12) - 1;
  const capital = (mois) => (r === 0 ? initial + mensuel * mois : initial * Math.pow(1 + r, mois) + mensuel * ((Math.pow(1 + r, mois) - 1) / r));
  return { final: capital(annees * 12), verse: initial + mensuel * annees * 12, parAn: Array.from({ length: annees }, (_, k) => ({ annee: k + 1, verse: initial + mensuel * (k + 1) * 12, capital: capital((k + 1) * 12) })) };
}

async function simulateur() {
  await ouvrirEspace('placements');
  const form = $('[data-form="simulation"]');
  form.addEventListener('submit', (x) => {
    x.preventDefault();
    executer(form.querySelector('[type=submit]'), async () => {
      const [initial, mensuel, duree, rendement, frais] = ['initial', 'mensuel', 'duree', 'rendement', 'frais'].map((k) => nombre(form.elements[k].value));
      if (!(initial >= 0 && initial <= 10_000_000) || !(mensuel >= 0 && mensuel <= 100_000) || !(initial > 0 || mensuel > 0)) throw new ErreurGmb('Indiquez un montant de départ ou un versement mensuel.');
      if (!(Number.isInteger(duree) && duree >= 1 && duree <= 40)) throw new ErreurGmb('Indiquez une durée de 1 à 40 ans.');
      if (!(rendement >= -20 && rendement <= 20)) throw new ErreurGmb('Indiquez un rendement entre -20 et 20 %.');
      if (!(frais >= 0 && frais <= 5)) throw new ErreurGmb('Indiquez des frais entre 0 et 5 %.');
      const avec = projeter(initial, mensuel, duree, rendement, frais); const sans = projeter(initial, mensuel, duree, rendement, 0);
      const etapes = avec.parAn.filter((a) => a.annee % 5 === 0 || a.annee === duree);
      $('[data-resultat]').innerHTML = `<dl class="app-recap"><div><dt>Total versé</dt><dd>${e(formaterMontant(avec.verse))}</dd></div><div><dt>Capital estimé après ${duree} an${duree > 1 ? 's' : ''}</dt><dd><strong>${e(formaterMontant(avec.final))}</strong></dd></div>
        <div><dt>Gain ou perte estimé</dt><dd>${e(formaterMontant(avec.final - avec.verse))}</dd></div><div><dt>Coût estimé des frais</dt><dd>${e(formaterMontant(sans.final - avec.final))}</dd></div></dl>
        ${tableau('Évolution estimée', ['Année', 'Total versé', 'Capital estimé'], etapes.map((a) => [e(a.annee), e(formaterMontant(a.verse)), e(formaterMontant(a.capital))]))}
        <p class="gmb-mention-obligatoire">Projection hypothétique, avec un rendement constant que vous avez choisi. En réalité, les marchés varient et le capital investi n’est pas garanti.</p>`;
    });
  });
}

demarrerPage({ investissement: lecture, 'simulateur-placement': simulateur, 'position-detail': versPlacements, 'ordre-achat': versPlacements, 'ordre-vente': versPlacements,
  'carnet-ordres': versPlacements, 'historique-ordres': versPlacements, performances: versPlacements, 'robo-advisor': versPlacements, reequilibrage: versPlacements,
  dici: versPlacements, ifu: versPlacements });
