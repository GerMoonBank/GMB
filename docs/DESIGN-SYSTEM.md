# GerMoonBank · Design system

Référence unique des choix visuels. Les valeurs vivent dans `css/variables.css` :
ce document les explique, il ne les remplace pas.

## Couleurs de marque

| Rôle | Jeton | Valeur | Usage |
|---|---|---|---|
| Violet, action | `--gmb-violet-500` | `#635BFF` | Boutons principaux, liens d’action, éléments actifs |
| Violet, texte de lien | `--gmb-violet-700` | `#4B42D6` | Liens sur fond clair (contraste suffisant) |
| Teal, accent | `--gmb-teal-400` | `#00D4B8` | Décor, graphiques, lune, fonds sombres |
| Teal, texte | `--gmb-teal-700` | `#00796B` | Texte vert sur fond clair |
| Rose, mise en avant | `--gmb-rose-500` | `#FF3E9A` | Pastilles, badges de nouveauté, avec parcimonie |

Chaque teinte existe de 50 à 900 (et 950 pour le violet) dans `css/variables.css`.

**Règle de contraste impérative :** le teal `#00D4B8` ne s’écrit jamais en texte sur fond
blanc (contraste de 1,9:1). On utilise `--gmb-teal-700` (`#00796B`). Tout texte respecte un
contraste d’au moins 4,5:1 (3:1 pour les textes de 24 px et plus).

Couleurs d’état : succès (`--gmb-succes-*`), alerte (`--gmb-alerte-*`), danger
(`--gmb-danger-*`), information (`--gmb-info-*`). Une information ne repose jamais sur la
seule couleur : une icône ou un mot l’accompagne.

## Thèmes

- **Clair**, par défaut partout.
- **Sombre premium**, au choix du client dans l’Espace client (Profil). Les jetons sont
  redéfinis sous `[data-theme="sombre"]` ; les composants n’écrivent jamais de couleur en dur.

## Typographie

- **Manrope**, graisses 400 à 800, pour tout le texte. Fichiers dans `assets/fonts/`.
- **JetBrains Mono**, graisses 400 et 600, pour les références, numéros de compte, IBAN et
  codes.
- Échelle fluide : `--gmb-fs-2xs` à `--gmb-fs-5xl`. Les montants utilisent des chiffres à
  chasse fixe (`font-variant-numeric: tabular-nums`).

## Espacements, rayons, ombres

- Espacements : `--gmb-space-0` à `--gmb-space-12`.
- Rayons : `--gmb-radius-xs` à `--gmb-radius-3xl`, `--gmb-radius-pill`, `--gmb-radius-circle`.
- Ombres : `--gmb-shadow-xs` à `--gmb-shadow-2xl`, plus les ombres de marque
  (`--gmb-shadow-brand`, `--gmb-shadow-teal`, `--gmb-shadow-rose`).

## Couches CSS

Ordre déclaré dans `css/variables.css` :
`tokens, reset, base, layout, components, utilities, pages`.

| Fichier | Couche | Contenu |
|---|---|---|
| `css/variables.css` | `tokens` | Jetons, thèmes |
| `css/base.css` | `reset`, `base` | Polices, remise à zéro, typographie, focus |
| `css/layout.css` | `layout` | En-tête, pied de page, conteneurs, piles, grilles |
| `css/components.css` | `components` | Boutons, champs, cartes, badges, dialogues, clavier… |
| `css/utilities.css` | `utilities` | Lecteurs d’écran, affichage selon l’écran, animations |
| `css/app.css`, `css/pages/*.css` | `pages` | Styles propres à chaque famille de pages |

Une page charge toujours les cinq premières feuilles, puis celles de sa famille
(`pages/product.css`, `pages/business.css`, `pages/legal.css`, `pages/home.css`,
`pages/auth.css`, `pages/onboarding.css` ou `app.css`).

## Nommage

Classes préfixées `gmb-`, en français, sur le modèle bloc, élément, variante :
`gmb-carte`, `gmb-carte__titre`, `gmb-bouton--principal`.

## Le motif de la lune

La lune signale l’avancement : un dossier, un coffre, un budget. Sa phase va de la nouvelle
lune (rien) à la pleine lune (atteint). Elle est produite par `luneSVG()` dans `js/core.js`
et porte toujours un titre lisible par les lecteurs d’écran.

## Accessibilité (référentiel RGAA, niveau AA)

- Focus toujours visible ; ordre de tabulation logique ; lien « Aller au contenu » en tête.
- Cibles tactiles d’au moins 44 × 44 px.
- Formulaires : libellé visible pour chaque champ, erreurs annoncées sous le champ et liées
  par `aria-describedby`.
- Animations : aucune si la personne a demandé à les réduire ; le contenu n’est jamais rendu
  invisible par une animation.
- Chaque page est contrôlée automatiquement (axe-core, WCAG 2.1 AA) à 390 et 1 280 px de
  large, sans débordement horizontal jusqu’à 320 px.
