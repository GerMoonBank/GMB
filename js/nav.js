/* =============================================================================
   GerMoonBank (GMB) · js/nav.js
   Navigation : menus, liens, accès aux espaces — version 3
   -----------------------------------------------------------------------------
   Données de navigation de l'en-tête et du menu mobile (segments Particuliers,
   Pro, Business, Jeunes). Une seule source pour tous les liens du site : chaque
   lot de pages publiques met à jour les chemins de sa section.
   ========================================================================== */

export const NAVIGATION = [
  {
    cle: 'particuliers',
    libelle: 'Particuliers',
    colonnes: [
      {
        titre: 'Au quotidien',
        liens: [
          { titre: 'Compte et carte', texte: 'Compte courant, carte Luna à 0 €', href: 'public/particuliers/compte-courant.html', icone: 'carte', page: 'compte-courant' },
          { titre: 'International et change', texte: 'Payer et retirer à l’étranger', href: 'public/cartes/frais-etranger.html', icone: 'globe', page: 'international' },
        ],
      },
      {
        titre: 'Épargner et investir',
        liens: [
          { titre: 'Épargne et Livret GMB', texte: 'Intérêts calculés et versés chaque jour', href: 'public/epargne/index.html', icone: 'croissance', page: 'epargne' },
          { titre: 'Bourse', texte: 'Comprendre les actions et les fonds', href: 'public/investissement/bourse.html', icone: 'graphique', page: 'bourse' },
          { titre: 'GMB X', texte: 'Comprendre les crypto-actifs', href: 'public/crypto/index.html', icone: 'coffre', page: 'crypto' },
        ],
      },
      {
        titre: 'Financer et protéger',
        liens: [
          { titre: 'Crédits', texte: 'Prêt personnel et simulateur', href: 'public/credit/pret-personnel.html', icone: 'banque', page: 'credits' },
          { titre: 'Assurances', texte: 'Garanties incluses et facultatives', href: 'public/cartes/assurances.html', icone: 'bouclier', page: 'assurances' },
          { titre: 'Tarifs', texte: 'Cinq formules, sans engagement', href: 'public/tarifs/particuliers.html', icone: 'info', page: 'tarifs' },
        ],
      },
    ],
    carte: {
      surtitre: 'Livret GMB',
      titre: 'Jusqu’à 5,25 % brut par an',
      texte: 'Intérêts calculés et versés chaque jour, selon votre formule.',
      lien: { libelle: 'Voir les conditions', href: 'public/epargne/livret-germoon-plus.html#conditions' },
    },
  },
  {
    cle: 'pro',
    libelle: 'Pro',
    colonnes: [
      {
        titre: 'Indépendants',
        liens: [
          { titre: 'Compte Pro', texte: 'Ouverture en 10 minutes, facturation intégrée', href: 'public/business/compte-pro.html', icone: 'mallette', page: 'pro' },
          { titre: 'Facturation et encaissement', texte: 'Factures électroniques, liens de paiement', href: 'public/business/facturation.html', icone: 'dossier', page: 'facturation' },
        ],
      },
      {
        titre: 'Formules',
        liens: [
          { titre: 'Tarifs Pro et Business', texte: 'Pro Solo à partir de 9 € HT par mois', href: 'public/tarifs/business.html', icone: 'info', page: 'tarifs-business' },
        ],
      },
    ],
    carte: {
      surtitre: 'Facturation électronique',
      titre: 'Prêt pour la réforme de 2026',
      texte: 'Recevez et émettez vos factures électroniques depuis votre compte.',
      lien: { libelle: 'Comprendre la réforme', href: 'public/business/facturation.html' },
    },
  },
  {
    cle: 'business',
    libelle: 'Business',
    colonnes: [
      {
        titre: 'Entreprises',
        liens: [
          { titre: 'Compte Business', texte: 'Cartes d’équipe, approbations, notes de frais', href: 'public/business/', icone: 'entreprise', page: 'business' },
          { titre: 'Tarifs Pro et Business', texte: 'Business Start à partir de 29 € HT par mois', href: 'public/tarifs/business.html', icone: 'info', page: 'tarifs-business' },
        ],
      },
      {
        titre: 'Développeurs',
        liens: [
          { titre: 'Portail développeurs', texte: 'Clés API et webhooks signés', href: 'public/business/api-developpeurs.html', icone: 'serveur', page: 'developpeurs' },
        ],
      },
    ],
    carte: {
      surtitre: 'Approbations',
      titre: 'Chaque paiement validé par la bonne personne',
      texte: 'Circuits de validation à un ou plusieurs niveaux, selon le montant.',
      lien: { libelle: 'Découvrir Business', href: 'public/business/' },
    },
  },
  {
    cle: 'jeunes',
    libelle: 'Jeunes',
    href: 'public/kids-teens/',
    page: 'jeunes',
    colonnes: [
      {
        titre: 'De 10 à 17 ans',
        liens: [
          { titre: 'Le compte Jeunes', texte: 'Une carte et des objectifs d’épargne', href: 'public/kids-teens/', icone: 'sourire', page: 'jeunes' },
          { titre: 'Espace parent', texte: 'Contrôle parental en temps réel', href: 'public/kids-teens/#parents', icone: 'utilisateur', page: 'jeunes-parents' },
          { titre: 'Questions des parents', texte: 'Sécurité, plafonds, argent de poche', href: 'public/kids-teens/#questions', icone: 'aide', page: 'jeunes-questions' },
        ],
      },
    ],
  },
];

export const LIENS_SIMPLES = [
  { libelle: 'Tarifs', href: 'public/tarifs/particuliers.html', page: 'tarifs' },
  { libelle: 'Aide', href: 'public/aide/', page: 'aide' },
];

export const LIENS_SECONDAIRES = [
  { libelle: 'Sécurité', href: 'public/societe/securite.html', icone: 'bouclier' },
  { libelle: 'Accessibilité', href: 'public/societe/accessibilite.html', icone: 'accessibilite' },
  { libelle: 'Engagements', href: 'public/societe/a-propos.html#engagements', icone: 'feuille' },
  { libelle: 'Centre d’aide', href: 'public/aide/', icone: 'aide' },
];

export const ACCES = {
  suivre: 'auth/mon-dossier.html',
  espaceClient: 'auth/connexion.html',
};

export const NIVEAUX_BANDEAU = ['promotion', 'information', 'alerte', 'incident'];
export const CLE_BANNIERE_APP = 'gmb-banniere-app-fermee';
export const ECRAN_BUREAU = '(min-width: 1024px)';
