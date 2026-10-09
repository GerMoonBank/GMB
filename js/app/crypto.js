/* =============================================================================
   GerMoonBank (GMB) · js/app/crypto.js — Crypto-actifs
   Les pages crypto-actifs de l'Espace client renvoient vers la page Placements
   (simulateur, épargne, guides des crypto-actifs).
   ========================================================================== */
import { demarrerPage, page } from './app.js';

const versPlacements = () => { location.replace(page('investissement/index.html')); };
demarrerPage({ crypto: versPlacements, 'crypto-actif': versPlacements, 'crypto-acheter': versPlacements, 'crypto-vendre': versPlacements, 'crypto-staking': versPlacements, 'crypto-historique': versPlacements });
