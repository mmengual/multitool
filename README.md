# Multitool

Une app macOS de barre des menus qui regroupe les petits accessoires du quotidien,
pour éviter d'installer (et de payer) un outil par besoin.

Anciennement **StopChattering** : l'app ne faisait au départ que filtrer les doubles
frappes d'un clavier défectueux. Elle a grossi, d'où le changement de nom.

## Modules

| Module | État | Rôle |
|---|---|---|
| Presse-papiers | en place | Historique de ce qui est copié (texte, images, fichiers), panneau de recherche au raccourci ⇧⌘V, collage direct, éléments épinglés. |
| Chatter Blocker | en place | Filtre les doubles frappes d'un switch mécanique défectueux (seuil par touche, en ms). Se met en pause quand un jeu est au premier plan. |
| Window Mover | en place | Déplace ou redimensionne n'importe quelle fenêtre en maintenant des modificateurs et en glissant à la souris. |
| Inversion ⌘ / ⌥ | en place | Inverse Commande et Option, toujours ou seulement quand un clavier Logitech est branché. |
| Partage de zone | en place | Diffuse une zone de l'écran dans une fenêtre invisible que Teams, Zoom ou Meet peuvent partager. |
| Processus et ressources | prévu | Carte des processus, de ce qui consomme, et des éléments lancés au démarrage. |
| Barre des menus | prévu | Choisir quelles icônes restent visibles, les autres passent dans un menu secondaire. |
| Captures d'écran | prévu | Captures et retouche, dans l'esprit de Shottr. |

Le détail des modules prévus et l'ordre de réalisation sont dans
[docs/ROADMAP.md](docs/ROADMAP.md).

## Utilisation

- **Icône de la barre des menus** : accès rapide, un interrupteur par module.
- **Réglages** (⌘, ou « Ouvrir les réglages ») : une fenêtre avec une page par module.
- **Presse-papiers** : ⇧⌘V ouvre l'historique par-dessus l'app en cours. ↩ colle,
  ⌥↩ colle en texte brut, ⌘1 à ⌘9 collent l'un des 9 premiers éléments, ⌘P épingle,
  ⌘⌫ supprime, esc ferme. Le raccourci se change dans les réglages.

## Construire et installer

```sh
./scripts/build-app.sh          # produit Multitool.app à la racine
mv Multitool.app /Applications/
open /Applications/Multitool.app
```

Au premier lancement, accorder la permission **Accessibilité** (Réglages Système →
Confidentialité et sécurité → Accessibilité). Le partage de zone demande aussi
**Enregistrement de l'écran**. La page Autorisations des réglages montre l'état des deux.

L'app est signée en ad hoc : chaque nouveau build change son empreinte, et macOS
peut garder une ancienne entrée Accessibilité qui bloque la nouvelle demande.
En cas de doute, supprimer l'entrée Multitool de la liste puis relancer.

Options de développement, à passer au binaire
(`Multitool.app/Contents/MacOS/Multitool`) :

- `--settings <page>` ouvre les réglages sur une page (`general`, `permissions`,
  `about`, `chatter`, `keyRemap`, `windowMover`, `regionShare`, `clipboard`) ;
- `--clipboard` ouvre l'historique du presse-papiers ;
- `--popover` ouvre le popover de la barre des menus.

## Interface : Orbe

L'interface suit [Orbe](https://claude.ai/artifact/KFb1xbo3Wy6JoP2htKS8Pw), la charte
commune des applications : thème `sombre`, densité `compacte`, accent **Lilas**.

- `UI/Orbe.swift` traduit les tokens d'Orbe en SwiftUI (couleurs, typographie,
  espacements, rayons, durées) et fournit les composants : `OrbeSection`,
  `OrbePanel`, `OrbeRow`, `OrbeSwitch`, `OrbeButtonStyle`, `OrbeSegmented`,
  `OrbeMenuPicker`, `OrbeBadge`, `OrbeKey`, `OrbeStat`, `OrbeMark`.
- Aucune couleur, taille ou rayon n'est écrit ailleurs : les vues passent par `Orbe`.
- L'accent se change en un seul endroit, `Orbe.appAccent`.
- Les polices Outfit, Manrope et JetBrains Mono (licence SIL OFL) sont dans
  `Resources/Fonts` et copiées dans l'app par le script de build. Lancé hors du
  bundle, le binaire retombe sur la police système.
- Écarts : les icônes sont des SF Symbols en graisse légère, pas le jeu d'icônes
  d'Orbe ; la flèche du popover garde la matière du système.

## Organisation du code

```
Sources/Multitool/
  App/             démarrage, icône de barre des menus, menu principal, logs
  Core/            réglages, raccourcis globaux, autorisations, ouverture de session
  UI/              Orbe, fenêtre de réglages, popover, une page par module (Panes/)
  Clipboard/       surveillance, stockage, panneau d'historique
  ChatterBlocker/  event tap clavier, statistiques, détection des jeux
  KeyRemap/        inversion ⌘ / ⌥, détection des claviers
  WindowMover/     déplacement et redimensionnement des fenêtres
  RegionShare/     sélection de zone, capture ScreenCaptureKit, fenêtre de partage
```

- Ajouter un module : un dossier, une entrée dans `SettingsCatalog`
  (`UI/SettingsWindow.swift`), une page dans `UI/Panes/`, une ligne dans le popover.
- Réglages : `UserDefaults`, domaine `com.mmengual.multitool`. Au premier lancement,
  ceux de `com.mmengual.stopchattering` sont repris.
- Historique du presse-papiers : `~/Library/Application Support/Multitool/Clipboard/`,
  lisible par le seul compte de l'utilisateur.
- Les événements clavier que Multitool envoie lui-même (le ⌘V du presse-papiers)
  portent une marque que les autres modules laissent passer (`SyntheticEvents`).
- Logs : `log stream --predicate 'subsystem == "com.mmengual.multitool"'`.
