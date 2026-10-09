# GerMoonBank · Sécurité

## 1. Deux portes, deux clés

| | Espace Mon Dossier | Espace client |
|---|---|---|
| Rôle | Déposer et suivre une demande | Gérer ses comptes et son argent |
| Accès | E-mail et mot de passe (12 caractères au moins, refusé s’il figure dans une fuite connue) | Identifiant à 8 chiffres et code secret à 8 chiffres |
| Second facteur | Code par e-mail sur tout nouvel appareil | Appareil de confiance, ou code par e-mail sur tout nouvel appareil |
| Accès aux fonds | Jamais | Oui |
| Compte technique | Utilisateur Supabase « dossier » | Utilisateur Supabase « client », distinct |

Les deux espaces reposent sur deux comptes techniques différents : connaître l’e-mail et le
mot de passe de Mon Dossier ne donne jamais accès à l’Espace client.

## 2. Code secret et clavier aléatoire

- La grille est créée par le serveur, valable 120 secondes et à usage unique.
- Le navigateur reçoit chaque touche sous forme de dessin, jamais de chiffre ; seules les
  positions touchées repartent vers le serveur.
- Le code est conservé sous forme d’empreinte (bcrypt) ; personne ne peut le relire.
- 3 codes erronés bloquent l’accès 30 minutes ; 6 en 24 heures le bloquent complètement.
- Le serveur répond de la même façon et dans le même temps pour tout identifiant, qu’il
  existe ou non.

## 3. Sessions

- Mon Dossier : déconnexion après 15 minutes d’inactivité.
- Espace client : avertissement à 4 minutes, déconnexion à 5 minutes d’inactivité, et
  60 minutes au plus par session.
- « Se déconnecter de tous les appareils » est disponible dans les deux espaces.

## 4. Accès aux données pendant le développement

Règle du projet : **aucune RLS** sur les tables tant que le projet n’est pas terminé. Les
règles d’accès sont enregistrées dans la base mais inactives.

- `js/donnees.js` est le seul point d’accès aux tables depuis le site. Il filtre chaque
  lecture et chaque écriture sur la personne connectée, refuse toute table non déclarée et
  impose lui-même les colonnes de propriété.
- L’argent, les cartes, les décisions et les signatures passent par les fonctions
  contrôlées de la base (`gmb_*`), qui vérifient elles-mêmes les droits.

**Limite à connaître :** sans RLS, toute personne qui dispose de la clé publique du site
(elle figure, par nature, dans `js/core.js`) peut lire et modifier les tables directement,
sans passer par le site. Pendant le développement, n’y mettez donc que vos propres essais,
jamais les données de vrais clients, et n’ouvrez pas le service au public.

Une exception est déjà protégée : les coordonnées du compte qui reçoit les virements
(`parametres_banque`) sont en lecture seule pour le site. Elles ne changent que par le
back-office (Trésorerie, avec motif et trace au journal d’audit) ou depuis le SQL Editor.
Personne ne peut donc détourner les premiers versements en remplaçant l’IBAN avec la clé
publique.

## 5. Clés et secrets

- La clé publiable de Supabase est dans `js/core.js` : elle est publique par nature.
- La clé secrète du projet (`sb_secret_…`, ou l’ancienne `service_role`) n’existe que dans
  la fonction serveur `gmb-connexion`, à qui Supabase la fournit. Elle ne doit **jamais**
  apparaître dans le dépôt GitHub, dans le navigateur, ni dans une conversation.
- L’identifiant bancaire d’un client n’est jamais envoyé par e-mail : il l’affiche dans
  l’Espace Mon Dossier, après avoir redonné son mot de passe.

## 6. Fichiers déposés

- Pièces et justificatifs vont dans des espaces de stockage privés, dans un dossier au nom
  de la personne.
- Les documents ne s’ouvrent qu’avec un lien temporaire, valable 60 secondes.

## 7. Navigateur

- Le service worker (`sw.js`) ne met jamais en cache les espaces privés ni les échanges
  avec Supabase ou les autres services extérieurs.
- Les mots de passe sont vérifiés contre les fuites connues sans jamais être transmis :
  seuls les 5 premiers caractères de leur empreinte SHA-1 sont envoyés.

## 8. Avant d’ouvrir le service au public

1. Réactiver les règles d’accès : exécuter `supabase/gmb_mode_production.sql`, puis
   vérifier chaque parcours.
2. Limiter la fonction serveur au site : secret `GMB_ORIGINES`.
3. Brancher un serveur d’envoi d’e-mails professionnel et régler les modèles avec code.
4. Régler les adresses du site et les limites de tentatives dans Supabase Auth.
5. Faire relire les conditions générales et la politique de confidentialité par un avocat.
6. Compléter les mentions légales (adresse du siège).
7. Obtenir un agrément de l’ACPR ou signer avec un établissement partenaire agréé :
   recevoir l’argent du public sans l’un ou l’autre est interdit.

## 9. Signaler une faille

Écrivez-nous à l’adresse de contact indiquée dans les mentions légales. N’exploitez pas la
faille et ne divulguez rien avant notre réponse.
