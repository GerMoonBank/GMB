# GerMoonBank · Charte éditoriale

Règles d’écriture de tous les textes : pages, messages d’erreur, e-mails, notifications.

## Ton

- **Vouvoiement**, toujours.
- Phrases courtes, une idée par phrase. Le verbe porte l’action : « Gelez votre carte », pas
  « Gel de la carte possible ».
- Les mots du client, pas ceux de la banque : « argent disponible » plutôt que « solde
  créditeur », sauf obligation légale.
- Aucune pression commerciale : pas de compte à rebours promotionnel, pas de « dernière
  chance ».

## Vérité avant tout

- **Ne jamais écrire** : « démonstration », « démo », « prototype », « au lancement »,
  « fictif », « bientôt disponible » pour un service présenté comme existant.
- Un produit que GerMoonBank ne propose pas fait l’objet d’un **guide exact**, qui le dit
  clairement : « GerMoonBank ne propose pas le Livret A. »
- Un service qui n’est pas encore ouvert n’est jamais présenté comme disponible dans
  l’Espace client.
- Le statut réglementaire de GerMoonBank figure uniquement dans les pages juridiques
  (Mentions légales, CGU, AMF, FGDR) : jamais en pied de page, en bandeau ni en encadré sur
  les autres pages. Il se met à jour avec les références officielles (REGAFI, ORIAS) dès
  qu’elles sont fournies.
- Aucun chiffre réglementé qui change souvent (taux du Livret A, prélèvements sociaux…) ne
  s’écrit en dur : on renvoie à la source officielle ou on le lit en direct.

## Formats

| Donnée | Format | Exemple |
|---|---|---|
| Montant | séparateur de milliers insécable fin, virgule, symbole après | 12 480,36 € |
| Taux | virgule, deux décimales, espace insécable avant % | 5,90 % |
| Date | jour, mois en lettres, année | 26 septembre 2026 |
| Date courte (tableaux) | JJ/MM/AAAA | 26/09/2026 |
| Heure | 14 h 30 | 14 h 30 |
| Référence de dossier | en police à chasse fixe | GMB-OUV-26-000001 |
| Identifiant bancaire | deux groupes de quatre chiffres | 4827 1530 |

Les montants et taux affichés viennent toujours du catalogue (`data/products.json`,
`data/rates.json`) ou de la base : jamais saisis à la main dans une page.

## Mentions obligatoires

- **Crédit** : « Un crédit vous engage et doit être remboursé. Vérifiez vos capacités de
  remboursement avant de vous engager. » Le TAEG est affiché plus grand que tout autre taux.
- **Investissement** : risque de perte en capital ; pour les crypto-actifs, risque de perte
  totale.
- **Épargne** : la garantie des dépôts est décrite dans la page juridique FGDR
  (`public/legal/fgdr.html`).

## Messages d’erreur

Un message dit ce qui s’est passé et comment s’en sortir, sans jargon technique :
« Ce justificatif date de plus de 3 mois. Déposez un document plus récent. »
Jamais de code d’erreur brut ni de message en anglais.

## Liens et boutons

- Un lien annonce sa destination : « Voir la brochure tarifaire », pas « Cliquez ici ».
- Un bouton annonce son action : « Signer mon offre », « Déposer le document ».
- Un lien qui ouvre un nouvel onglet le signale aux lecteurs d’écran.

## E-mails

Objet explicite contenant le code s’il y en a un ; rappel systématique : « GerMoonBank ne
vous demandera jamais votre code secret ni votre mot de passe. »
