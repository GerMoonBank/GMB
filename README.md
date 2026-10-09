# GerMoonBank

Néobanque en ligne : compte courant, cartes, épargne, crédit, espaces Pro, Business et
Jeunes, avec un back-office qui fait avancer chaque dossier.

- Site : https://germoonbank.github.io/GMB/
- Éditeur : The Hub of Inspiration of Soccer (HubISoccer), RCCM RB/ABC/24 A 111814, Bénin.
- Statut : GerMoonBank n’est ni un établissement de crédit, ni un établissement de
  paiement, ni un établissement de monnaie électronique agréé par l’ACPR.

> **Installation et mise à niveau : ouvrez le [module d’installation](https://germoonbank.github.io/GMB/supabase/installation/installation-base-gmb.html)**, ou suivez [`docs/INSTALLATION.md`](docs/INSTALLATION.md). L’arborescence complète est dans [`docs/ARBORESCENCE.md`](docs/ARBORESCENCE.md).

## Technologies

HTML5, CSS3 et JavaScript (modules natifs), sans framework ni compilation ; base de données,
authentification, stockage et fonction serveur sur Supabase (région Union européenne) ;
publication sur GitHub Pages.

## Structure

L’architecture suit le plan des 372 fichiers, une page par écran, complété par le
back-office et la base de données. La liste complète, fichier par fichier, est dans
`docs/ARCHITECTURE.md`.

| Dossier | Contenu |
|---|---|
| `public/` | Pages publiques (Particuliers, épargne, crédit, cartes, Business…) |
| `public/inscription/` | Ouverture de compte |
| `auth/` | Connexions à Mon Dossier et à l’Espace client |
| `app/` | Espace client et Mon Dossier |
| `bo/` | Back-office |
| `css/` | Feuilles de style (jetons, base, mise en page, composants, pages) |
| `js/` | Modules : `core.js`, `donnees.js`, `nav.js`, `components.js`, `forms.js`, `charts.js`, `animations.js`… |
| `data/` | Catalogue (`products.json`, `rates.json`), questions, équipe, glossaire |
| `assets/` | Logos, icônes, polices |
| `docs/` | Architecture, design system, charte éditoriale, sécurité |
| `supabase/` | Base de données (installation, mise à niveau, tâches), fonction serveur, module d’installation |

Toutes les pages publiques, dont l’inscription, sont dans `public/`. Les dossiers `clients/` et
`mon-dossier/` ne contiennent plus que des redirections vers l’Espace client (`app/`) et l’Espace
Mon Dossier (`app/mon-dossier/`).

## Installation

Le détail, pas à pas, est dans [`docs/INSTALLATION.md`](docs/INSTALLATION.md) et dans le module d’installation.

1. **Base de données.** Projet neuf : les 8 parties de `supabase/installation/`, dans l’ordre, dans
   Supabase › SQL Editor. Base déjà installée : `supabase/gmb_mise_a_niveau.sql` (ne supprime rien,
   rejouable). Résultat attendu : `select public.gmb_version();` renvoie `20261007`.
2. **Premier administrateur** (projet neuf) : Authentication › Users › Add user, puis
   `select gmb_prive.creer_administrateur('e-mail', 'Nom');`
3. **E-mails de Supabase** : serveur d’envoi (SMTP), trois modèles avec `{{ .Token }}`, adresses du site.
4. **Fonction serveur** `supabase/functions/gmb-connexion/`, déployée sous ce nom exact, vérification du
   JWT désactivée. Son adresse, ouverte dans un navigateur, répond `"statut":"ok"`.
5. **Tâches quotidiennes** : `supabase/gmb_taches_quotidiennes.sql`.
6. **Compte de réception des virements** : back-office › Trésorerie.
7. **Contrôle** : back-office › Tableau de bord › « État du service ».
8. **Publication** : GitHub Pages, branche `main`, dossier racine.

## Règles du projet

- Aucune démonstration ni donnée fictive : uniquement des processus réels.
- Pendant le développement, aucune RLS : chaque accès aux données passe par
  `js/donnees.js`. Voir `docs/SECURITE.md` avant toute ouverture au public.
- Les prix, taux et frais viennent uniquement de `data/products.json` et `data/rates.json`.
- Écriture : `docs/CHARTE-EDITORIALE.md`. Visuel : `docs/DESIGN-SYSTEM.md`.

## Avancement

| Lot | Contenu | État |
|---|---|---|
| A | Fondations : styles, modules, données, documentation, base de données | Livré |
| B1 | Particuliers, Tarifs et Épargne (41 pages) | Livré |
| B2 | Crédit et Cartes (42 pages) | Livré |
| B3 | Investissement et Crypto (46 pages) | Livré |
| B4 | Assurance, Jeunes et Société (46 pages) | Livré |
| B5 | Business, Aide et Légal (50 pages) | Livré |
| C1 | Inscription : 8 pages, 5 parcours (Particulier, Pro, Business, Jeunes, prêt) | Livré |
| C2 | Authentification : 7 pages, fonction serveur réécrite pour la base réelle | Livré |
| D1 | Back-office : connexion, tableau de bord, dossiers, pièces, crédits, trésorerie | Livré |
| D2 | Back-office : LCB-FT, fraude, clients, support, pilotage, contenus, catalogue, sécurité, collaborateurs, audit | Livré |
| E1a | Espace client : accueil, comptes, historique, virements avec authentification forte, bénéficiaires | Livré |
| E1b-1 | Espace client : épargne (Livret, coffres, objectifs, épargne programmée, intérêts) ; exécution quotidienne des virements programmés | Livré |
| E1b-2 | Espace client : cartes ; pages publiques corrigées (aucune carte n’est émise sans partenaire émetteur) | Livré |
| E1b-3 | Espace client : crédit (prêts, échéancier, remboursement anticipé, simulateur, demande, suivi) ; prélèvement quotidien des échéances | Livré |
| E2-0 | Dossier combiné : ouverture de compte et demande de prêt depuis le tunnel | Livré |
| E2a | Espace Mon Dossier (suivi, documents, échanges, signatures, identifiant) ; documents de l’Espace client ; prélèvement des cotisations | Livré |
| E2b | Messagerie, réclamations, conseiller (service clients), rendez-vous, discussion instantanée ; rendez-vous traités au back-office | Livré |
| E3 | Espace client : investissement et crypto-actifs (services non proposés, expliqués honnêtement ; simulateur de placement réel) | Livré |
| E2c | Paramètres : profil, coordonnées, code secret, sécurité, appareils, notifications, apparence, fermeture du compte (traitée au back-office) | Livré |
| F1 | Fiabilisation : création d’accès et codes par e-mail (adresse déjà inscrite, délais, liens), reprise d’une demande, compte de réception réglé au back-office, parcours de validation d’un dossier, identifiant réaffichable, état du service, mise à niveau unique de la base, module d’installation refait | Livré |
