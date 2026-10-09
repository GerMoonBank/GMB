# GerMoonBank · Architecture du projet

Référence : architecture des 372 fichiers (312 annoncés, 319 pages HTML effectivement listées), une page par écran, validée par Ozawa le 4 octobre 2026.
Règles : aucune démonstration ni donnée fictive ; processus réels sur Supabase ; aucune RLS pendant le développement, chaque accès aux données passant par `js/donnees.js` ; vanilla HTML, CSS et JavaScript, publication sur GitHub Pages.

## Chiffres

- Fichiers de l’architecture d’origine nommés un par un : 362 (dont `data/user-mock.json`, faux utilisateur, remplacé par `data/glossaire.json`)
- Fichiers d’images, de logos et de polices (`assets/`) : 31
- Ajouts indispensables au fonctionnement réel (back-office, base de données, 404, état des services, couche de données) : 69
- **Total : 462 fichiers, dont 341 pages HTML**

## Nature des fichiers

- guide (non proposé par GerMoonBank) : 116
- offre réelle : 72
- fonction réelle : 66
- support : 65
- ajout : base de données : 36
- institutionnel : 27
- service non disponible (prestataire agréé requis) : 23
- ajout : back-office : 19
- processus réel : 15
- ajout : nécessaire au fonctionnement : 14
- outil de calcul réel : 9

## Lots

- A · fondations : 105 fichiers
- B1 · pages publiques : 41 fichiers
- B2 · pages publiques : 42 fichiers
- B3 · pages publiques : 46 fichiers
- B4 · pages publiques : 46 fichiers
- B5 · pages publiques : 50 fichiers
- C · inscription et authentification : 17 fichiers
- D · back-office : 19 fichiers
- E1 · Espace client : 47 fichiers
- E2 · Espace client : 29 fichiers
- E3 · Espace client : 20 fichiers

## Liste complète

| Fichier | Nature | Reprend le contenu de | Lot |
|---|---|---|---|
| `index.html` | support | index.html | A · fondations |
| `manifest.json` | support | manifest.webmanifest | A · fondations |
| `sw.js` | support | nouveau | A · fondations |
| `robots.txt` | support | nouveau | A · fondations |
| `sitemap.xml` | support | nouveau | A · fondations |
| `README.md` | support | nouveau | A · fondations |
| `public/particuliers/index.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/particuliers/compte-courant.html` | offre réelle | particuliers/compte-carte.html | B1 · pages publiques |
| `public/particuliers/compte-joint.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/particuliers/compte-indivis.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/particuliers/compte-budget.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/particuliers/compte-a-theme.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/particuliers/compte-etudiant.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/particuliers/compte-senior.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/particuliers/compte-non-resident.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/particuliers/compte-multi-devises.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/particuliers/compte-paiement.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/particuliers/compte-a-terme.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/particuliers/options-compte.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/particuliers/comparateur-comptes.html` | outil de calcul réel | nouveau | B1 · pages publiques |
| `public/epargne/index.html` | offre réelle | particuliers/epargne.html | B1 · pages publiques |
| `public/epargne/livret-a.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/ldds.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/livret-jeune.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/livret-germoon-plus.html` | offre réelle | particuliers/epargne.html | B1 · pages publiques |
| `public/epargne/cel.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/pel.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/per.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/coffres.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/epargne/objectifs.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/epargne/epargne-programmee.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/epargne/epargne-enfants.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/epargne/epargne-salariale.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/interessement-participation.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/pee.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/perco.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/simulateur-epargne.html` | outil de calcul réel | nouveau | B1 · pages publiques |
| `public/epargne/comparateur-livrets.html` | outil de calcul réel | nouveau | B1 · pages publiques |
| `public/epargne/taux-en-vigueur.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/epargne/fiscalite-epargne.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/epargne/garantie-fgdr.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/epargne/glossaire.html` | guide (non proposé par GerMoonBank) | nouveau | B1 · pages publiques |
| `public/investissement/index.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/bourse.html` | guide (non proposé par GerMoonBank) | particuliers/bourse.html | B3 · pages publiques |
| `public/investissement/compte-titres.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/pea.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/pea-pme.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/actions.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/etf.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/obligations.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/fonds.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/opcvm.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/scpi.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/opci.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/assurance-vie.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/multisupport.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/fonds-euros.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/unites-de-compte.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/per-individuel.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/per-collectif.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/robo-advisor.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/gestion-pilotee.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/gestion-libre.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/portefeuille-modele.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/simulateur-boursier.html` | outil de calcul réel | nouveau | B3 · pages publiques |
| `public/investissement/carnet-ordres.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/types-ordres.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/frais-courtage.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/fiscalite-pea.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/fiscalite-cto.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/ifu.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/dici.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/avertissement-risques.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/investissement/nos-analystes.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/index.html` | guide (non proposé par GerMoonBank) | particuliers/crypto.html | B3 · pages publiques |
| `public/crypto/acheter.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/vendre.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/wallet.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/staking.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/rendement.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/bitcoin.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/ethereum.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/altcoins.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/nft.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/fiscalite-crypto.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/securite-crypto.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/glossaire-crypto.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/crypto/avertissement-amf.html` | guide (non proposé par GerMoonBank) | nouveau | B3 · pages publiques |
| `public/credit/index.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/pret-personnel.html` | offre réelle | particuliers/credits.html | B2 · pages publiques |
| `public/credit/pret-travaux.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/pret-auto.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/pret-moto.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/pret-etudiant.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/pret-mariage.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/credit-immobilier.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/pret-relais.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/pret-in-fine.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/rachat-credit.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/regroupement-credits.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/microcredit.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/credit-renouvelable.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/decouvert-autorise.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/credit-affecte.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/credit-non-affecte.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/simulateur-pret.html` | outil de calcul réel | nouveau | B2 · pages publiques |
| `public/credit/simulateur-immobilier.html` | outil de calcul réel | nouveau | B2 · pages publiques |
| `public/credit/capacite-emprunt.html` | outil de calcul réel | nouveau | B2 · pages publiques |
| `public/credit/taux-en-vigueur.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/assurance-emprunteur.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/credit/garanties.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/credit/delais-obtention.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/assurance/index.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/auto.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/moto.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/habitation.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/sante.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/mutuelle.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/prevoyance.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/deces.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/dependance.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/emprunteur.html` | offre réelle | nouveau | B4 · pages publiques |
| `public/assurance/scolaire.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/animaux.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/smartphone.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/voyage.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/tous-risques.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/au-tiers.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/au-kilometre.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/comparateur.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/declarer-sinistre.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/suivre-sinistre.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/resilier-contrat.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/partenaires.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/fiscalite-assurance-vie.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/clauses-beneficiaires.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/avance-contrat.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/assurance/glossaire-assurance.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/cartes/index.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/debit-immediat.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/debit-differe.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/cartes/classique.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/gold.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/metal.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/visa-premier.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/cartes/infinite.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/cartes/virtuelle.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/prepayee.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/cartes/enfant.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/etudiante.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/sans-contact.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/apple-google-pay.html` | guide (non proposé par GerMoonBank) | nouveau | B2 · pages publiques |
| `public/cartes/options.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/assurances.html` | offre réelle | particuliers/assurances.html | B2 · pages publiques |
| `public/cartes/plafonds-retraits.html` | offre réelle | nouveau | B2 · pages publiques |
| `public/cartes/frais-etranger.html` | offre réelle | particuliers/international.html | B2 · pages publiques |
| `public/business/index.html` | offre réelle | business/index.html | B5 · pages publiques |
| `public/business/compte-pro.html` | offre réelle | pro/index.html | B5 · pages publiques |
| `public/business/compte-association.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/compte-sci.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/compte-prof-liberale.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/compte-auto-entrepreneur.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/compte-startup.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/encaissement.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/lien-paiement.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/passerelle-ecommerce.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/terminal-tap-to-pay.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/terminal-physique.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/cartes-corporate.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/plafonds-collaborateurs.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/notes-de-frais.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/tresorerie-previsionnelle.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/financement-pro.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/credit-pro.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/affacturage.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/leasing.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/change-entreprise.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/api-developpeurs.html` | offre réelle | developpeurs/index.html | B5 · pages publiques |
| `public/business/webhooks.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/sandbox.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/integrations-comptables.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/integrations-erp.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/facturation.html` | offre réelle | pro/facturation.html | B5 · pages publiques |
| `public/business/recouvrement.html` | guide (non proposé par GerMoonBank) | nouveau | B5 · pages publiques |
| `public/business/multi-utilisateurs.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/roles-permissions.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/cas-clients.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/tarifs-business.html` | offre réelle | business/tarifs.html | B5 · pages publiques |
| `public/business/contacter-equipe-pro.html` | offre réelle | nouveau | B5 · pages publiques |
| `public/business/simulateur-tpe.html` | outil de calcul réel | nouveau | B5 · pages publiques |
| `public/kids-teens/index.html` | offre réelle | jeunes/index.html | B4 · pages publiques |
| `public/kids-teens/compte-enfant.html` | offre réelle | nouveau | B4 · pages publiques |
| `public/kids-teens/compte-ado.html` | offre réelle | nouveau | B4 · pages publiques |
| `public/kids-teens/carte-enfant.html` | offre réelle | nouveau | B4 · pages publiques |
| `public/kids-teens/carte-ado.html` | offre réelle | nouveau | B4 · pages publiques |
| `public/kids-teens/controle-parental.html` | offre réelle | nouveau | B4 · pages publiques |
| `public/kids-teens/education-financiere.html` | offre réelle | nouveau | B4 · pages publiques |
| `public/kids-teens/gamification.html` | guide (non proposé par GerMoonBank) | nouveau | B4 · pages publiques |
| `public/tarifs/index.html` | outil de calcul réel | nouveau | B1 · pages publiques |
| `public/tarifs/particuliers.html` | offre réelle | particuliers/tarifs.html | B1 · pages publiques |
| `public/tarifs/business.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/tarifs/options.html` | offre réelle | nouveau | B1 · pages publiques |
| `public/tarifs/grille-tarifaire.html` | offre réelle | particuliers/brochure-tarifaire.html | B1 · pages publiques |
| `public/societe/a-propos.html` | institutionnel | a-propos.html | B4 · pages publiques |
| `public/societe/mission.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/equipe.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/carrieres.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/presse.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/blog.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/securite.html` | institutionnel | securite.html | B4 · pages publiques |
| `public/societe/accessibilite.html` | institutionnel | legal/accessibilite.html | B4 · pages publiques |
| `public/societe/contact.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/agences.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/partenaires.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/societe/actualites.html` | institutionnel | nouveau | B4 · pages publiques |
| `public/aide/index.html` | institutionnel | aide/index.html | B5 · pages publiques |
| `public/aide/faq.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/aide/centre-aide.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/aide/guides.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/aide/videos.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/aide/contact-support.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/legal/cgv.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/legal/cgu.html` | institutionnel | legal/conditions-generales.html | B5 · pages publiques |
| `public/legal/mentions-legales.html` | institutionnel | legal/mentions-legales.html | B5 · pages publiques |
| `public/legal/rgpd.html` | institutionnel | legal/confidentialite.html | B5 · pages publiques |
| `public/legal/cookies.html` | institutionnel | legal/confidentialite.html | B5 · pages publiques |
| `public/legal/mediation.html` | institutionnel | aide/reclamation.html | B5 · pages publiques |
| `public/legal/tarification.html` | institutionnel | particuliers/document-information-tarifaire.html | B5 · pages publiques |
| `public/legal/fgdr.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/legal/amf.html` | institutionnel | nouveau | B5 · pages publiques |
| `public/inscription/index.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `public/inscription/etape-1-identite.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `public/inscription/etape-2-coordonnees.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `public/inscription/etape-3-situation.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `public/inscription/etape-4-documents.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `public/inscription/etape-5-signature.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `public/inscription/etape-6-validation.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `public/inscription/confirmation.html` | processus réel | ouvrir/index.html, js/tunnel.js | C · inscription et authentification |
| `auth/mon-dossier.html` | processus réel | mon-dossier/connexion.html | C · inscription et authentification |
| `auth/connexion.html` | processus réel | clients/connexion.html | C · inscription et authentification |
| `auth/validation-forte.html` | processus réel | nouveau | C · inscription et authentification |
| `auth/code-secret.html` | processus réel | clients/acces-oublie.html | C · inscription et authentification |
| `auth/mot-de-passe-oublie.html` | processus réel | mon-dossier/mot-de-passe.html | C · inscription et authentification |
| `auth/premiere-connexion.html` | processus réel | clients/activation.html | C · inscription et authentification |
| `auth/activation-app.html` | processus réel | nouveau | C · inscription et authentification |
| `app/index.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/index.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/courant.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/joint.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/epargne.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/rib.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/virements.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/virements-internationaux.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/virements-programmes.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/beneficiaires.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/prelevements.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/comptes/chequier.html` | service non disponible (prestataire agréé requis) | nouveau | E1 · Espace client |
| `app/comptes/oppositions.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/cartes/index.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/cartes/detail.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/cartes/plafonds.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/cartes/virtuelle.html` | service non disponible (prestataire agréé requis) | nouveau | E1 · Espace client |
| `app/cartes/commande.html` | service non disponible (prestataire agréé requis) | nouveau | E1 · Espace client |
| `app/cartes/opposition.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/cartes/etranger.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/cartes/assurances.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/epargne/index.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/epargne/livret-detail.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/epargne/coffres.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/epargne/coffre-detail.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/epargne/objectifs.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/epargne/programmation.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/epargne/interets.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/investissement/index.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/position-detail.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/ordre-achat.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/ordre-vente.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/carnet-ordres.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/historique-ordres.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/performances.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/robo-advisor.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/reequilibrage.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/dici.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/ifu.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/investissement/simulateur.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/crypto/index.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/crypto/actif.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/crypto/acheter.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/crypto/vendre.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/crypto/staking.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/crypto/historique.html` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `app/credit/index.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/credit/detail.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/credit/echeancier.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/credit/remboursement-anticipe.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/credit/simulateur.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/credit/demande.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/credit/suivi.html` | fonction réelle | nouveau | E1 · Espace client |
| `app/documents/index.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/documents/releves.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/documents/attestations.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/documents/fiscaux.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/documents/contrats.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/documents/factures.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/messages/index.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/messages/nouveau.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/messages/conversation.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/conseiller/index.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/conseiller/rendez-vous.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/conseiller/chat.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/profil.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/coordonnees.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/mot-de-passe.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/code-secret.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/2fa.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/appareils.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/notifications.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/langue-devise.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/parametres/fermeture.html` | fonction réelle | nouveau | E2 · Espace client |
| `app/mon-dossier/index.html` | fonction réelle | mon-dossier/index.html | E2 · Espace client |
| `app/mon-dossier/documents.html` | fonction réelle | mon-dossier/index.html | E2 · Espace client |
| `app/mon-dossier/kyc.html` | fonction réelle | mon-dossier/index.html | E2 · Espace client |
| `app/mon-dossier/signature.html` | fonction réelle | mon-dossier/index.html | E2 · Espace client |
| `app/mon-dossier/validation.html` | fonction réelle | mon-dossier/index.html | E2 · Espace client |
| `css/variables.css` | support | design/variables.css | A · fondations |
| `css/base.css` | support | design/base.css | A · fondations |
| `css/layout.css` | support | design/layout.css | A · fondations |
| `css/components.css` | support | design/components.css | A · fondations |
| `css/utilities.css` | support | nouveau | A · fondations |
| `css/app.css` | support | design/espace-client.css | A · fondations |
| `css/pages/home.css` | support | nouveau | A · fondations |
| `css/pages/product.css` | support | design/vitrine.css | A · fondations |
| `css/pages/business.css` | support | nouveau | A · fondations |
| `css/pages/auth.css` | support | nouveau | A · fondations |
| `css/pages/onboarding.css` | support | design/souscription.css | A · fondations |
| `css/pages/legal.css` | support | nouveau | A · fondations |
| `js/core.js` | support | js/core.js | A · fondations |
| `js/nav.js` | support | nouveau | A · fondations |
| `js/auth.js` | support | js/dossier-acces.js, client-connexion.js, client-activation.js, clavier.js | C · inscription et authentification |
| `js/forms.js` | support | js/souscription.js | A · fondations |
| `js/animations.js` | support | nouveau | A · fondations |
| `js/charts.js` | support | nouveau | A · fondations |
| `js/components.js` | support | composants/gm-header.js, gm-footer.js, gm-souscription.js | A · fondations |
| `js/app/dashboard.js` | fonction réelle | js/espace-client.js | E1 · Espace client |
| `js/app/accounts.js` | fonction réelle | js/espace-client.js | E1 · Espace client |
| `js/app/transfers.js` | fonction réelle | js/espace-client.js | E1 · Espace client |
| `js/app/savings.js` | fonction réelle | js/espace-client.js | E1 · Espace client |
| `js/app/invest.js` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `js/app/crypto.js` | service non disponible (prestataire agréé requis) | nouveau | E3 · Espace client |
| `js/app/history.js` | fonction réelle | js/espace-client.js | E1 · Espace client |
| `js/app/security.js` | fonction réelle | js/espace-client.js | E2 · Espace client |
| `js/app/messages.js` | fonction réelle | js/espace-client.js | E2 · Espace client |
| `js/app/mon-dossier.js` | fonction réelle | js/mon-dossier.js | E2 · Espace client |
| `data/products.json` | support | js/catalogue.js | A · fondations |
| `data/rates.json` | support | js/catalogue.js | A · fondations |
| `data/faq.json` | support | nouveau | A · fondations |
| `data/team.json` | support | nouveau | A · fondations |
| `data/glossaire.json` | support | nouveau | A · fondations |
| `docs/ARCHITECTURE.md` | support | nouveau | A · fondations |
| `docs/DESIGN-SYSTEM.md` | support | nouveau | A · fondations |
| `docs/CHARTE-EDITORIALE.md` | support | nouveau | A · fondations |
| `docs/SECURITE.md` | support | nouveau | A · fondations |
| `assets/fonts/LICENCE-POLICES.txt` | support | design/fonts/LICENCE-POLICES.txt | A · fondations |
| `assets/fonts/jetbrains-mono-400.woff2` | support | design/fonts/jetbrains-mono-400.woff2 | A · fondations |
| `assets/fonts/jetbrains-mono-600.woff2` | support | design/fonts/jetbrains-mono-600.woff2 | A · fondations |
| `assets/fonts/manrope-400.woff2` | support | design/fonts/manrope-400.woff2 | A · fondations |
| `assets/fonts/manrope-500.woff2` | support | design/fonts/manrope-500.woff2 | A · fondations |
| `assets/fonts/manrope-600.woff2` | support | design/fonts/manrope-600.woff2 | A · fondations |
| `assets/fonts/manrope-700.woff2` | support | design/fonts/manrope-700.woff2 | A · fondations |
| `assets/fonts/manrope-800.woff2` | support | design/fonts/manrope-800.woff2 | A · fondations |
| `assets/logo/LISEZMOI.txt` | support | nouveau | A · fondations |
| `assets/logo/apple-touch-icon.png` | support | nouveau | A · fondations |
| `assets/logo/favicon-16.png` | support | nouveau | A · fondations |
| `assets/logo/favicon-32.png` | support | nouveau | A · fondations |
| `assets/logo/favicon.ico` | support | nouveau | A · fondations |
| `assets/logo/gmb-icone-mono.svg` | support | nouveau | A · fondations |
| `assets/logo/gmb-icone-pleine.svg` | support | nouveau | A · fondations |
| `assets/logo/gmb-icone.svg` | support | nouveau | A · fondations |
| `assets/logo/gmb-logo-mono.svg` | support | nouveau | A · fondations |
| `assets/logo/gmb-logo-sombre.svg` | support | nouveau | A · fondations |
| `assets/logo/gmb-logo.svg` | support | nouveau | A · fondations |
| `assets/logo/gmb-partage.png` | support | nouveau | A · fondations |
| `assets/logo/icone-192.png` | support | nouveau | A · fondations |
| `assets/logo/icone-512.png` | support | nouveau | A · fondations |
| `assets/logo/icone-masquable-192.png` | support | nouveau | A · fondations |
| `assets/logo/icone-masquable-512.png` | support | nouveau | A · fondations |
| `assets/fonts/jetbrains-mono-400.woff2` | support | design/fonts/jetbrains-mono-400.woff2 | A · fondations |
| `assets/fonts/jetbrains-mono-600.woff2` | support | design/fonts/jetbrains-mono-600.woff2 | A · fondations |
| `assets/fonts/manrope-400.woff2` | support | design/fonts/manrope-400.woff2 | A · fondations |
| `assets/fonts/manrope-500.woff2` | support | design/fonts/manrope-500.woff2 | A · fondations |
| `assets/fonts/manrope-600.woff2` | support | design/fonts/manrope-600.woff2 | A · fondations |
| `assets/fonts/manrope-700.woff2` | support | design/fonts/manrope-700.woff2 | A · fondations |
| `assets/fonts/manrope-800.woff2` | support | design/fonts/manrope-800.woff2 | A · fondations |
| `404.html` | ajout : nécessaire au fonctionnement | nouveau | A · fondations |
| `public/aide/etat-des-services.html` | ajout : nécessaire au fonctionnement | nouveau | B5 · pages publiques |
| `js/donnees.js` | ajout : nécessaire au fonctionnement | nouveau | A · fondations |
| `js/inscription.js` | ajout : nécessaire au fonctionnement | nouveau | C · inscription et authentification |
| `js/app/app.js` | ajout : nécessaire au fonctionnement | nouveau | E1 · Espace client |
| `bo/connexion.html` | ajout : back-office | nouveau | D · back-office |
| `bo/index.html` | ajout : back-office | nouveau | D · back-office |
| `js/catalogue.js` | ajout : nécessaire au fonctionnement | nouveau | E1 · Espace client |
| `mon-dossier/index.html` | ajout : nécessaire au fonctionnement | nouveau | E1 · Espace client |
| `docs/INSTALLATION.md` | ajout : nécessaire au fonctionnement | nouveau | A · fondations |
| `docs/ARBORESCENCE.md` | ajout : nécessaire au fonctionnement | nouveau | A · fondations |
| `supabase/gmb_installation_complete.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/gmb_apres_installation.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/gmb_ouverture_administrative.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_diagnostic_dossier.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/gmb_lotE2b_messagerie.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotE2c_parametres.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/installation/installation-base-gmb.html` | ajout : base de données | nouveau | A · fondations |
| `supabase/gmb_mise_a_niveau.sql` | ajout : base de données | nouveau | F1 · fiabilisation |
| `supabase/installation/mise-a-niveau-1-sur-2.sql` | ajout : base de données | nouveau | F1 · fiabilisation |
| `supabase/installation/mise-a-niveau-2-sur-2.sql` | ajout : base de données | nouveau | F1 · fiabilisation |
| `clients/index.html` | ajout : nécessaire au fonctionnement | nouveau | E1 · Espace client |
| `bo/cms.html` | ajout : back-office | nouveau | D · back-office |
| `bo/dossiers.html` | ajout : back-office | nouveau | D · back-office |
| `bo/dossier.html` | ajout : back-office | nouveau | D · back-office |
| `bo/kyc.html` | ajout : back-office | nouveau | D · back-office |
| `bo/lcb-ft.html` | ajout : back-office | nouveau | D · back-office |
| `bo/clients.html` | ajout : back-office | nouveau | D · back-office |
| `bo/credit.html` | ajout : back-office | nouveau | D · back-office |
| `bo/operations.html` | ajout : back-office | nouveau | D · back-office |
| `bo/fraude.html` | ajout : back-office | nouveau | D · back-office |
| `bo/reclamations.html` | ajout : back-office | nouveau | D · back-office |
| `bo/parametres.html` | ajout : back-office | nouveau | D · back-office |
| `bo/securite.html` | ajout : back-office | nouveau | D · back-office |
| `bo/audit.html` | ajout : back-office | nouveau | D · back-office |
| `bo/collaborateurs.html` | ajout : back-office | nouveau | D · back-office |
| `bo/tresorerie.html` | ajout : back-office | nouveau | D · back-office |
| `js/bo/bo.js` | ajout : back-office | nouveau | D · back-office |
| `css/pages/bo.css` | ajout : back-office | nouveau | D · back-office |
| `supabase/gmb_schema.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/gmb_lot2_entreprises.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotC_jeunes.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotC2_authentification.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotD_backoffice.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotD2_backoffice.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotE1_paiements.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotE1b_epargne.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotE1b3_credit.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotE2_dossier_combine.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_lotE2a_cotisations.sql` | retiré : remplacé par `gmb_mise_a_niveau.sql` | avis seul | F1 · fiabilisation |
| `supabase/gmb_taches_quotidiennes.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/gmb_mode_developpement.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/gmb_mode_production.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-01-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-02-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-03-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-04-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-05-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-06-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-07-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/installation/partie-08-sur-08.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/v3/01_fondations.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/v3/02_tables.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/v3/03_fonctions.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/v3/04_declencheurs_securite.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/v3/05_reference.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/v3/06_administration.sql` | ajout : base de données | nouveau | A · fondations |
| `supabase/functions/gmb-connexion/index.ts` | ajout : base de données | nouveau | A · fondations |
