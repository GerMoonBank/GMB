/* =============================================================================
   GerMoonBank (GMB) · js/catalogue.js
   Relais de transition — version 3
   -----------------------------------------------------------------------------
   Le catalogue vit désormais dans data/products.json et data/rates.json, et
   ses calculs dans js/core.js. Ce relais garde les anciennes pages en état de
   marche pendant leur migration ; il sera supprimé avec la dernière d'entre elles.
   ========================================================================== */
export {
  DATE_EFFET,
  FORMULES,
  MOIS_PAYES_PAR_AN,
  formule,
  prixAnnuel,
  COMPARATIF,
  FRAIS_HORS_FORMULE,
  LIVRET,
  CREDIT,
  grilleCredit,
  INTERNATIONAL,
  tauxBCE,
  fraisRetrait,
  fraisChange,
  FORMULES_PRO,
  OPERATION_SUPPLEMENTAIRE_HT,
  BESOINS_PRO,
  formulePro,
  coutsPro,
  FACTURATION,
  JEUNES,
  CALENDRIER,
  MENTIONS,
  CATALOGUE,
} from './core.js';
