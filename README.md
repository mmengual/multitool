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
| Inversion ⌘ / ⌥ | en place | Inverse Commande et Option clavier par clavier, en pilotant le réglage Touches de modification de macOS. |
| Partage de zone | en place | Diffuse une zone de l'écran dans une fenêtre invisible que Teams, Zoom ou Meet peuvent partager. |
| Processus et ressources | en cours | Moniteur : état du poste, consommateurs par app (processeur, mémoire, disque, réseau, énergie), anomalies expliquées, exécutables d'origine douteuse. Éléments de démarrage à venir. |
| Barre des menus | en cours | Inventaire des icônes de la barre. Un chevron, désactivé par défaut et placé par glisser ⌘, cache les icônes à sa gauche dans le déroulé de macOS, qu'un clic sur le chevron ouvre et ferme. Classement des icônes à venir. |
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
rm -rf /Applications/Multitool.app && mv Multitool.app /Applications/
open /Applications/Multitool.app
```

La version vient du fichier `VERSION`, le numéro de build du nombre de commits.
L'app est signée avec le certificat Apple Development du poste : cette identité stable
garde l'autorisation Accessibilité d'une version à l'autre.

Au premier lancement, accorder la permission **Accessibilité** (Réglages Système →
Confidentialité et sécurité → Accessibilité). Le partage de zone demande aussi
**Enregistrement de l'écran**. La page Autorisations des réglages montre l'état des deux.

Sans ce certificat, le script signe en ad hoc : chaque build change alors d'empreinte,
et macOS peut garder une ancienne entrée Accessibilité qui bloque la nouvelle demande.
Dans ce cas, supprimer l'entrée Multitool de la liste puis relancer.

Options de développement, à passer au binaire
(`Multitool.app/Contents/MacOS/Multitool`) :

- `--settings <page>` ouvre les réglages sur une page (`general`, `permissions`,
  `updates`, `about`, `chatter`, `keyRemap`, `windowMover`, `regionShare`, `clipboard`) ;
- `--clipboard` ouvre l'historique du presse-papiers ;
- `--popover` ouvre le popover de la barre des menus ;
- `--monitor` ouvre le moniteur ;
- `--stress-resize` redimensionne la fenêtre au premier plan 10 fois par seconde pendant 30 s ;
- `--snapshot <fichier.png>` dessine la fenêtre au premier plan dans un PNG au bout de 12 s,
  sans autorisation d'enregistrement de l'écran ;
- `--update-in-background` cherche une mise à jour sans fenêtre et l'installe à la fermeture.

Commandes de la barre des menus, traitées sans démarrer l'app (pas d'icône, pas de fenêtre) :

- `--menubar-dump` liste les icônes de la barre, le cadre de l'indicateur du déroulé de macOS,
  la limite gauche (bord droit de l'encoche) et la largeur que prendrait un chevron posé
  à gauche de la première icône ;
- `--menubar-toggle` ouvre ou ferme le déroulé de macOS, imprime `toggle: ok` ou la cause
  de l'échec et sort en code 1 dans ce cas.

## Mises à jour

Multitool se met à jour avec [Sparkle](https://sparkle-project.org), depuis ce dépôt :

- l'appcast est `appcast.xml` sur la branche orpheline `releases`, lu via
  `https://raw.githubusercontent.com/mmengual/multitool/releases/appcast.xml` ;
- chaque version est une release GitHub `vX.Y.Z` dont l'asset est l'app zippée ;
- chaque archive est signée par une clé EdDSA. La clé privée est dans le trousseau
  (compte `multitool`), la clé publique dans `Resources/Sparkle/public-key.txt` et
  l'Info.plist. À sauvegarder une fois, hors dépôt :
  `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account multitool -x <fichier>`.

Publier une version :

```sh
echo 0.3.0 > VERSION && git commit -am "Version 0.3.0" && git push
scripts/release.sh                       # notes = commits depuis la dernière release
scripts/release.sh --notes "- Ajout de…" # ou notes explicites
```

Le script refuse un arbre modifié ou non poussé, construit, zippe, signe, crée la
release et ajoute la version en tête de l'appcast. Les copies installées la voient
à leur prochaine vérification (quotidienne, ou Réglages → Mises à jour).

Si le dépôt passe en privé, l'app a besoin d'un jeton de lecture : un token GitHub
*fine-grained* limité à ce dépôt, permission Contents en lecture seule, rangé dans
le trousseau. `build-app.sh` l'embarque alors dans l'Info.plist (`MTUpdateToken`),
et l'app ne le présente qu'à `raw.githubusercontent.com` et `api.github.com` :

```sh
security add-generic-password -U -s multitool-update-token -a github -w
```

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
  Updates/         Sparkle, accès au dépôt GitHub
  ChatterBlocker/  event tap clavier, statistiques, détection des jeux
  KeyRemap/        inversion ⌘ / ⌥ par le réglage macOS de chaque clavier
  WindowMover/     déplacement et redimensionnement des fenêtres
  RegionShare/     sélection de zone, capture ScreenCaptureKit, fenêtre de partage
  Monitor/         échantillonnage, anomalies, service de lecture, nettop
Sources/MultitoolShared/  protocole XPC et lecture des processus, communs à l'app et au service
Sources/MultitoolHelper/  service de lecture privilégié (daemon launchd)
```

- Ajouter un module : un dossier, une entrée dans `SettingsCatalog`
  (`UI/SettingsWindow.swift`), une page dans `UI/Panes/`, une ligne dans le popover.
- Réglages : `UserDefaults`, domaine `com.mmengual.multitool`. Au premier lancement,
  ceux de `com.mmengual.stopchattering` sont repris.
- Historique du presse-papiers : `~/Library/Application Support/Multitool/Clipboard/`,
  lisible par le seul compte de l'utilisateur.
- Les événements clavier que Multitool envoie lui-même (le ⌘V du presse-papiers)
  portent une marque que les autres modules laissent passer (`SyntheticEvents`).
- Inversion ⌘ / ⌥ : Multitool écrit le réglage que macOS range sous
  `com.apple.keyboard.modifiermapping.<vendor>-<product>-0` (domaine global, hôte courant),
  puis le pousse au clavier branché pour qu'il prenne effet tout de suite. macOS
  le réapplique seul à chaque branchement. Pas d'interception : ça marche aussi dans
  les champs de mot de passe et sans l'autorisation Accessibilité.
- Moniteur, lecture complète : macOS refuse à un utilisateur les compteurs des processus
  de root. `MultitoolHelper` est un daemon déclaré dans
  `Contents/Library/LaunchDaemons` et enregistré par `SMAppService.daemon` : l'utilisateur
  l'autorise une fois (Réglages Système → Général → Ouverture et extensions). Il ne fait
  que lire, n'accepte que Multitool signé par l'équipe `UGUP3H993V`, et l'app ne parle qu'à
  un service signé de même (`MultitoolShared/HelperProtocol.swift`). Il s'arrête seul après
  5 minutes sans demande. Après une mise à jour, l'app lui demande de quitter pour que
  launchd relance le nouveau binaire.
- Réseau par processus : `nettop -L 1` relancé à chaque mesure (son mode continu occupe
  plus d'un cœur), seulement fenêtre ouverte.
- Gel de l'interface : `HangWatchdog` journalise toute pause du fil principal de plus
  d'une seconde (« main thread was blocked for … s »).
- Fil principal : le moteur du moniteur tourne en arrière-plan et ne doit appeler ni
  AppKit ni le serveur de fenêtres (`CGSession…`). Une connexion au serveur de fenêtres
  ouverte hors du fil principal a fait planter l'app (redimensionnement de l'icône de la
  barre des menus hors du fil principal).
- Logs : `log stream --predicate 'subsystem == "com.mmengual.multitool"'`.
