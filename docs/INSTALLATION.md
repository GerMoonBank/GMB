# GerMoonBank · Installation et mise à niveau

Tout se fait depuis un téléphone ou un ordinateur, avec le **module d’installation** :

> `https://germoonbank.github.io/GMB/supabase/installation/installation-base-gmb.html`

Il contient chaque script, avec un bouton « Copier », et vérifie lui-même la fonction serveur. Cette page décrit les mêmes étapes, dans le même ordre.

| Élément | Où |
|---|---|
| Dépôt GitHub | `https://github.com/GerMoonBank/GMB` |
| Site publié | `https://germoonbank.github.io/GMB/` |
| Projet Supabase | `https://ufrzpdnsfuuchyywkeqt.supabase.co` (région Union européenne) |
| Version de la base | `20261007` (`select public.gmb_version();`) |

**Une seule de ces deux situations vous concerne :**

- **A. La base est déjà installée** : vous la mettez à niveau, sans rien effacer.
- **B. Le projet Supabase est neuf** : vous installez la base (8 parties).

Dans les deux cas, terminez par **C. Les réglages**.

> Ne faites jamais l’installation neuve (B) sur une base en service : sa première partie efface tout.

---

## Comment exécuter un script

1. Copiez le script (bouton « Copier » du module, ou contenu du fichier).
2. Supabase › **SQL Editor** (menu de gauche) › bouton **+** › requête vide › collez.
3. **Run**. Si Supabase demande de confirmer des « destructive operations », confirmez : d’anciennes fonctions sont remplacées.
4. Attendez « Success » avant de passer au script suivant. En cas d’erreur, arrêtez-vous et notez le message exact.

## A. Mettre à niveau une base déjà installée

Exécutez `supabase/gmb_mise_a_niveau.sql`. Depuis un téléphone, le fichier est proposé en deux blocs par le module (`supabase/installation/mise-a-niveau-1-sur-2.sql`, puis `mise-a-niveau-2-sur-2.sql`) : exécutez-les dans l’ordre.

- La mise à niveau **ne supprime aucune donnée** et peut être **exécutée plusieurs fois**.
- Le dernier résultat doit afficher **`version_base` = `20261007`**.
- Elle apporte la messagerie et les rendez-vous (lot E2b), les paramètres et la fermeture de compte (lot E2c), puis les correctifs : reprise d’une demande en cours, nom d’usage vide, premier versement, identifiant réaffichable, contrôle du code secret, décisions du back-office expliquées, compte de réception réglable depuis le back-office, état de l’installation.
- Ensuite, **redéployez la fonction serveur** (C.2).

Les anciens scripts `supabase/gmb_lot*.sql` sont retirés : ne les exécutez plus.

## B. Installer sur un projet neuf

1. Exécutez dans l’ordre `supabase/installation/partie-01-sur-08.sql` à `partie-08-sur-08.sql`, chacune dans une requête vide. Depuis un ordinateur avec psql : `psql "<chaîne de connexion>" -f supabase/gmb_installation_complete.sql` (même contenu).
2. La base démarre **vide** : aucun client, aucun dossier, aucune donnée de démonstration. La dernière partie met les règles d’accès (RLS) en pause, conformément à la règle du projet pendant le développement.
3. **Créez votre compte administrateur** :
   - Supabase › **Authentication** › **Users** › **Add user** › **Create new user** : votre adresse e-mail, un mot de passe de 12 caractères ou plus, **Auto Confirm User** coché, puis **Create user** ;
   - SQL Editor, requête vide : `select gmb_prive.creer_administrateur('vous@exemple.fr', 'Votre nom');` — le résultat affiche `"roles": 11`.
   - Utilisez pour l’administrateur une adresse **différente** de celle d’un client : un même compte ne peut pas être à la fois collaborateur et demandeur.

## C. Les réglages

### C.1 Les e-mails de Supabase

Tous les codes à 6 chiffres sont envoyés par Supabase. Quatre réglages, dans **Authentication** :

**a. Le serveur d’envoi** — **Emails** › onglet **SMTP Settings** › **Enable custom SMTP**. Sans lui, Supabase n’écrit qu’aux membres de l’équipe du projet, quelques fois par heure. Avec Gmail : hôte `smtp.gmail.com`, port `465`, identifiant et adresse d’expédition = l’adresse Gmail, mot de passe = un **mot de passe d’application** (Compte Google › Sécurité › Validation en deux étapes › Mots de passe des applications), nom d’expéditeur `GerMoonBank`.

**b. Les trois modèles** — **Emails** › onglet **Templates**. Pour *Confirm signup*, *Magic Link* et *Reset Password*, l’objet est `Votre code GerMoonBank : {{ .Token }}` et le message contient `{{ .Token }}` (les trois messages sont dans le module, prêts à copier).

- *Confirm signup* : création de l’accès à l’Espace Mon Dossier.
- *Magic Link* : connexion à Mon Dossier sur un nouvel appareil, connexion au back-office, activation de l’accès à l’Espace client, validation d’un nouvel appareil, code secret oublié.
- *Reset Password* : mot de passe oublié de Mon Dossier.

Le site accepte aussi un modèle resté avec un lien pour Mon Dossier et le back-office. **L’Espace client, lui, demande toujours le code** : sans `{{ .Token }}` dans *Magic Link*, aucun client ne peut activer son accès. Le tableau de bord du back-office le signale (ligne « E-mails de code »).

**c. Les adresses du site** — **URL Configuration** : *Site URL* `https://germoonbank.github.io/GMB/` ; *Redirect URLs* `https://germoonbank.github.io/GMB/**`.

**d. Les codes** — **Sign In / Providers** › **Email** : *Confirm email* activé, *Email OTP Expiration* `600`, *Minimum password length* `12`.

**Limites à connaître** (Authentication › **Rate Limits**) : une même adresse ne reçoit qu’**un e-mail par minute** ; avec un serveur d’envoi personnalisé, le projet envoie **30 e-mails par heure** par défaut (réglable). Le site affiche le délai restant et ne prétend jamais avoir envoyé un e-mail qui n’est pas parti.

### C.2 La fonction serveur `gmb-connexion`

Elle ouvre les sessions de l’Espace client (clavier aléatoire, appareils de confiance, codes par e-mail). Sans elle, aucun client ne peut activer son accès ni se connecter. Son code est `supabase/functions/gmb-connexion/index.ts`.

1. Supabase › **Edge Functions** › **Deploy a new function** › **Via Editor**.
2. Dans la case du nom, Supabase propose un nom au hasard (par exemple « super-service ») : remplacez-le par **`gmb-connexion`**, exactement.
3. Effacez le code d’exemple, collez tout `index.ts`, puis **Deploy function** (en bas de l’éditeur).
4. Ouvrez la fonction, onglet **Details** : désactivez **Verify JWT** (« Verify JWT with legacy secret »), puis **Save changes**. La fonction est appelée avant toute connexion, avec la clé publiable du site, qui n’est pas un JWT.
5. Vérifiez : bouton **Vérifier la fonction** du module, ou ouvrez `https://ufrzpdnsfuuchyywkeqt.supabase.co/functions/v1/gmb-connexion` dans un navigateur. La réponse attendue commence par `{"service":"gmb-connexion","statut":"ok"`.

Avec la ligne de commande : `supabase functions deploy gmb-connexion --no-verify-jwt --project-ref ufrzpdnsfuuchyywkeqt`.

Pour la mettre à jour : ouvrez `gmb-connexion`, onglet **Code**, remplacez tout, **Deploy updates**.

Aucun secret n’est à saisir : Supabase fournit `SUPABASE_URL` et les clés du projet. La fonction utilise les nouvelles clés (`SUPABASE_SECRET_KEYS`, `SUPABASE_PUBLISHABLE_KEYS`) et, à défaut, les anciennes (`SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_ANON_KEY`), que Supabase retire fin 2026. Facultatif : **Edge Functions › Secrets**, `GMB_ORIGINES` = `https://germoonbank.github.io` pour n’accepter que les appels venant du site.

### C.3 Les tâches quotidiennes

Exécutez `supabase/gmb_taches_quotidiennes.sql` (rejouable). Il active lui-même l’extension pg_cron.

| Heure (UTC) | Tâche |
|---|---|
| 0 h 05 | Intérêts du Livret |
| 5 h 00 | Cotisations mensuelles des formules |
| 6 h 00 | Virements différés et permanents, épargne programmée |
| 6 h 30 | Échéances de prêt |

### C.4 Le compte qui reçoit les virements

Back-office › **Trésorerie** › **Renseigner le compte de réception** : titulaire, IBAN, BIC (facultatif), banque.

- Tant qu’il est vide, aucun demandeur ne peut faire son premier versement ni déposer sa demande.
- Écrivez le **titulaire exactement comme sur le relevé d’identité bancaire** : la banque de chaque demandeur compare ce nom à celui du compte (vérification du bénéficiaire) et signale toute différence.
- Tout changement demande un motif et reste au journal d’audit. Le site lit ces coordonnées mais ne peut pas les modifier avec sa clé publique.

### C.5 Le contrôle final

Back-office › **Tableau de bord** › carte **État du service** : base, fonction serveur, e-mails de code, compte de réception, tâches quotidiennes, règles d’accès. Chaque ligne en alerte dit quoi faire.

Depuis le SQL Editor : `supabase/gmb_apres_installation.sql` (lecture seule).

---

## Publier le site

1. Déposez les fichiers dans le dépôt `GerMoonBank/GMB`, à leur place exacte (voir [`ARBORESCENCE.md`](ARBORESCENCE.md)).
2. GitHub › **Settings** › **Pages** : *Source* « Deploy from a branch », branche **main**, dossier **/ (root)**.
3. La publication prend une à deux minutes ; un navigateur peut garder l’ancienne version une dizaine de minutes. Pour forcer la nouvelle : rechargez la page deux fois.

Le site trouve seul sa racine et son projet Supabase (`js/core.js`). **Autre projet Supabase** : modifiez `url` et `cle` (clé *publishable*) dans `js/core.js` — jamais une clé secrète.

## Vérifier le parcours complet

1. **Ouvrir un compte** (`public/inscription/`) avec une adresse qui n’a pas encore d’accès : code reçu par e-mail, six étapes, premier versement déclaré, demande déposée.
2. **Back-office** (`bo/connexion.html`) › **Dossiers** › ouvrez le dossier : le « Parcours de validation » indique chaque étape — prendre en charge, valider les pièces, enregistrer la réception du versement, valider. Le compte est ouvert et l’identifiant créé.
3. **Espace Mon Dossier** (`auth/mon-dossier.html`) › **Identifiant** : l’identifiant s’affiche (mot de passe redemandé pour le revoir).
4. **Activer mon accès** (`auth/premiere-connexion.html`) : code reçu par e-mail, code secret à 8 chiffres saisi deux fois.
5. **Espace client** (`app/index.html`) : comptes, virements, épargne, crédit, documents, messagerie, paramètres.

Une adresse qui a déjà un accès ne recrée pas de compte : le site lui envoie un code de connexion et reprend sa demande en cours.

## Ce que disent les messages

| Message ou référence | Cause | À faire |
|---|---|---|
| « La base de données n’est pas à jour » (back-office), `base-PGRST205`, `base-PGRST202` | Une table ou une fonction manque | Exécuter la mise à niveau (A) |
| `fonction-absente` | Supabase ne trouve pas `gmb-connexion`, ou sa vérification du JWT est activée | C.2 |
| `fonction-fermée` | La fonction refuse les appels : vérification du JWT activée | C.2, point 4 |
| « Supabase refuse les clés… » (État du service) | La fonction n’a pas de clé secrète valable | Redéployer la fonction ; vérifier Settings › API Keys |
| « Un e-mail vient déjà de vous être envoyé… dans N secondes » | Un e-mail par minute et par adresse | Attendre, puis « Renvoyer le code » |
| `limite-emails` | Quota horaire d’e-mails du projet atteint | Authentication › Rate Limits |
| `envoi-email` | Le serveur d’envoi a refusé l’e-mail | Vérifier SMTP Settings (mot de passe d’application) |
| `envoi-non-autorise` | Pas de serveur d’envoi personnalisé | C.1 a |
| « Les coordonnées de versement… ne sont pas encore configurées » | Compte de réception vide | C.4 |

## Diagnostic d’un dossier

`supabase/gmb_diagnostic_dossier.sql` : remplacez, ligne `param`, la référence du dossier et l’adresse du demandeur, puis exécutez. Il ne modifie rien ; sa dernière ligne, **PROCHAINE ACTION**, dit quoi faire. N’enregistrez pas ce fichier dans le dépôt avec l’adresse d’une vraie personne.

## Ouvrir un compte sans premier versement (exploitant)

Réservé à l’exploitant, depuis le SQL Editor, par exemple pour son propre compte d’essai. Conditions : identité et coordonnées remplies (étapes 1 et 2), toutes les pièces validées. Le compte est ouvert **à 0 €**, le dossier suit le parcours normal des états et l’ouverture est inscrite au journal d’audit avec son motif.

```sql
select gmb_prive.ouvrir_compte_administratif(
  (select id from public.dossiers where reference = 'GMB-OUV-00-000000'),
  'Compte d’essai du propriétaire, ouvert sans premier versement');
```

Le titulaire affiche ensuite son identifiant dans l’Espace Mon Dossier et active son accès.

## Passage en production

Avant d’accueillir de vrais clients :

1. `supabase/gmb_mode_production.sql` : réactive les règles d’accès (RLS) sur toutes les tables, puis vérifiez le parcours complet.
2. Serveur d’envoi d’e-mails professionnel et limites d’envoi adaptées.
3. Secret `GMB_ORIGINES` de la fonction serveur.
4. Les points de [`SECURITE.md`](SECURITE.md), section 8 : agrément ou établissement partenaire agréé, documents juridiques relus.

## Fichiers retirés

Remplacés par `gmb_mise_a_niveau.sql`, ces fichiers ne contiennent plus qu’un avis et peuvent être supprimés du dépôt : `supabase/gmb_lot2_entreprises.sql`, `gmb_lotC_jeunes.sql`, `gmb_lotC2_authentification.sql`, `gmb_lotD_backoffice.sql`, `gmb_lotD2_backoffice.sql`, `gmb_lotE1_paiements.sql`, `gmb_lotE1b_epargne.sql`, `gmb_lotE1b3_credit.sql`, `gmb_lotE2_dossier_combine.sql`, `gmb_lotE2a_cotisations.sql`, `gmb_lotE2b_messagerie.sql`, `gmb_lotE2c_parametres.sql`, `gmb_ouverture_administrative.sql`.

Issus de versions plus anciennes, à supprimer s’ils existent encore : dossiers `ouvrir/`, `particuliers/`, `pro/`, `business/`, `developpeurs/`, `jeunes/`, `legal/`, `aide/` (à la racine), `composants/`, `design/`, `supabase/parties/` ; fichiers `manifest.webmanifest`, `supabase/gmb_schema_complet.sql`, `supabase/gmb_lot3_complements.sql`, `supabase/gmb_demonstration.sql`, `supabase/installation/partie-0X-sur-06.sql` et `partie-0X-sur-07.sql`.
