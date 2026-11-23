# Brief — Barre des menus, lot 3 : la bande sous l'horloge

Branche `menubar` (lots 1 et 2 à `02b8880`). Cible : macOS 27.2, MacBook à encoche.
Mesures : séries A (23/11, écran externe), B et C (23/11, MacBook, barre saturée par
14 fausses icônes). Prototype : `relay` dans le scratchpad, hors repo.

## 1. Ce que les mesures imposent

| Mesure | Valeur | Conséquence |
|---|---|---|
| Déroulé ouvert par AXPress → icône évincée lisible | 30 à 54 ms | attente bornée à 500 ms |
| Déroulé refermé par AXPress | 62 à 85 ms | — |
| macOS referme seul le déroulé quand une app passe au premier plan | vu 2 fois | ne jamais presser l'indicateur « pour fermer » sans relire son état |
| Déroulé fermé, une app évincée perd tout son `AXExtrasMenuBar` | — | l'ensemble des icônes évincées ne se lit que déroulé ouvert : il faut un cache |
| AXPress sur une icône à menu (Teams) | menu à l'écran en 101 ms, à x 475 (bande vers x 1900) | menu natif loin de la bande : on le redessine |
| AXPress sur une icône à menu, côté appelant | rend la main à la fermeture du menu (ou en erreur -25204 au délai) | toujours hors du main thread |
| AXPress sur une entrée lue déroulé ouvert, pressée déroulé refermé | accepté, effet réel (Teleport Connect revient au premier plan) | menu redessiné possible sans rouvrir le déroulé |
| AXPress sur une icône sans menu | Google Drive 102 ms, Slack 421 ms, Notion 1151 ms ; OneDrive sourde ; **Sophos Connect plante** (SIGILL dans son gestionnaire de clic) | **jamais d'AXPress sur une icône sans menu** |
| Clic simulé (CGEvent) au centre de l'icône, déroulé ouvert | Slack 86 ms, OneDrive 230 ms, Sophos 883 ms, aucun plantage ; curseur remis en 11 à 25 ms | mode des icônes sans menu |
| Fenêtre ou popover ouverts par le clic | restent après la fermeture du déroulé, ancrés sous la place de l'icône dans le déroulé (à gauche de l'encoche) | limite acceptée : Multitool ne déplace pas les fenêtres des autres apps |

## 2. Périmètre

Dans le lot : la bande sous l'horloge au design system Orbe, les icônes évincées
montrées par l'icône de leur application, le clic relayé, le chevron qui ouvre et
ferme la bande (et le déroulé natif au ⌥-clic), les 3 corrections du lot 2.

Hors lot : les 2 cases par icône et le glisser ⌘ (lot 4), le survol du coin (lot 5),
l'écran externe (la bande s'ouvre sur l'écran de la barre, état vide si rien n'est
évincé), les identifiants stables (lot 4 : on garde `bundleID#index`).

## 3. Conception

### 3.1 Inventaire : scan complet et cache (`MenuBarInventory`)

- **Scan complet** : ouvre le déroulé s'il est fermé (AXPress sur l'indicateur),
  attend l'identifiant `-expanded` puis la stabilité de la liste (2 lectures
  identiques à 20 ms d'écart, 500 ms au plus), lit toutes les icônes, referme le
  déroulé **seulement si Multitool l'a ouvert et s'il est encore ouvert**.
- Par icône, on garde en plus : `hasMenu` (un enfant `AXMenu`), le nombre d'entrées,
  et le mode de relais calculé (§3.3).
- **Cache `evicted`** : icônes à gauche de l'indicateur au dernier scan complet.
  Entre 2 scans complets, le scan léger (déroulé fermé, celui d'aujourd'hui) le
  retire les apps qui ont quitté. Le cache est **périmé** (relecture B6) dès
  qu'une icône visible disparaît du scan léger sans que son app ait quitté, qu'une
  icône d'une app inconnue du cache apparaît, que la place ou la longueur du
  chevron change, ou que les écrans changent. Pas de correction icône par icône :
  `#index` peut différer entre déroulé ouvert et fermé.
- **Quand** : un scan complet n'a lieu qu'à l'ouverture de la bande si le cache est
  vide ou périmé, et à chaque clic relayé (le déroulé est ouvert de toute façon).
  Jamais en tâche de fond : le déroulé s'afficherait sans que Maxime ait cliqué.
- **Faux « Multitool » (correction lot 2)** : `ownItems()` prend toutes les fenêtres
  `NSStatusBarWindow` de l'app. Il ne doit lire que la fenêtre du bouton de
  l'icône principale (`AppDelegate.statusItem`), exposée par un petit registre, et
  seulement si elle est sur un écran et visible (`occlusionState`). Cause exacte à
  confirmer pendant le code (fenêtres de status items retirés ou cachés,
  identifiant `#index` instable).

### 3.2 La bande (`MenuBarBand`, `MenuBarBandView`)

- `NSPanel` sans bordure, non activant (`.nonactivatingPanel`), niveau
  `.statusBar`, `canJoinAllSpaces` + `fullScreenAuxiliary`, `hidesOnDeactivate =
  false`. Ce n'est pas une `NSStatusBarWindow` : l'inventaire ne la voit pas.
- Place : écran de la barre (`NSScreen.screens.first`), bord haut collé sous la
  barre (hauteur de barre = `screen.frame.maxY - screen.visibleFrame.maxY`, 39 pt
  mesurés sur l'encoche, repli `safeAreaInsets.top`), bord droit aligné sur le bord
  droit de l'horloge lu dans l'inventaire (repli `screen.frame.maxX - 8`).
- Contenu SwiftUI aux jetons Orbe uniquement : fond `surface`, filet `filet`,
  rayon et marges `Densite`, une cellule par icône évincée avec l'icône de
  l'application (`NSRunningApplication.icon`, 18 pt), survol `surfaceHaute`, info-
  bulle au nom de l'app. Ordre : celui de la barre (de gauche à droite).
- États : liste ; **vide** « Aucune icône cachée » ; **Accessibilité absente**
  avec le bouton « Autoriser » ; **lecture en cours** pendant un scan complet ;
  **icône non relayée** (badge `alerte` une seconde) quand le relais échoue.
- Fermeture : 2e clic sur le chevron, Échap, clic hors de la bande (moniteur
  global `leftMouseDown`), et dès qu'un clic relayé part.

### 3.3 Le clic relayé (`MenuBarRelay`)

**Un seul propriétaire du déroulé** (relecture B2) : `MenuBarOverflow` devient une
file série unique qui porte toutes les pressions de l'indicateur (⌥-clic, scan
complet, relais). Elle garde un jeton « ouvert par Multitool », relit `-expanded`
juste avant chaque AXPress (plus de `toggle` à l'aveugle) et refuse un 2e relais
tant qu'un relais est en cours. Le minuteur de 3 s de la page de réglages ne
lance pas de scan pendant un relais. Le chevron suspend son recalcul de longueur
tant que Multitool garde le déroulé ouvert (relecture C3).

Pour l'icône X cliquée dans la bande :

1. La bande **reste ouverte**, X passe à l'état « en cours » (relecture B1).
   Ouvrir le déroulé s'il est fermé, puis attendre que X soit lisible en ne
   lisant que le pid de X (même pid, même index, 500 ms au plus), sans scan de
   toutes les apps sur le chemin du clic (relecture B7). Échec : badge sur X,
   log, déroulé refermé. Le scan complet qui met le cache à jour suit le relais,
   tant que le déroulé est encore ouvert.
2. Choisir le mode, recalculé sur la lecture fraîche :
   - **Menu redessiné** si X a un `AXMenu` d'au moins une entrée et que toutes ses
     entrées sont lisibles (titre ou séparateur). On lit l'arbre (titre, activé,
     coche, un seul niveau de sous-menu) en gardant les `AXUIElement`, on referme
     le déroulé, puis on affiche sur le main thread un `NSMenu` construit à partir
     de l'arbre, ouvert sous la cellule de X (la bande se ferme à l'ouverture du
     menu). Choisir une entrée fait un AXPress sur l'élément gardé, sur la file
     série.
   - **Menu natif** si X a un `AXMenu` vide (rempli à l'ouverture : Zoom,
     GlobalProtect) ou illisible : la bande se ferme, AXPress sur X avec un délai
     AX long posé sur X pour cet appel seulement ; le menu s'ouvre à gauche de
     l'encoche. Un retour -25204 veut dire « menu encore ouvert », pas « fini »
     (relecture B3). La fin du menu se détecte par une relecture bornée de
     l'`AXMenu` de X (cadre disparu, 30 s au plus), puis le déroulé est refermé.
   - **Clic simulé** si X n'a pas d'`AXMenu` : la bande se ferme, relire le cadre
     de X juste avant, `leftMouseDown` puis `leftMouseUp` au centre
     (`CGEventSource .hidSystemState`, `.cghidEventTap`, **`flags = []`** pour ne
     pas transformer un ⌘ tenu en ⌘-glisser), curseur remis à sa place
     (`CGWarpMouseCursorPosition` après
     `CGEventSourceSetLocalEventsSuppressionInterval(0)`), déroulé refermé 300 ms
     après s'il est encore ouvert. **Jamais d'AXPress** sur ces icônes.
3. L'icône de Multitool lui-même, si elle est évincée, ouvre son popover
   directement, sans AX, ancré sur la cellule de la bande
   (`showPopover(relativeTo:)`, relecture B4) et sans `NSApp.activate`. Pour le
   cache, sa présence se lit sur le main thread **après** l'ouverture du déroulé.

Journal `MenuBar` niveau info à chaque étape, avec les délais en ms.

### 3.4 Le chevron (`MenuBarChevron`)

- Clic → ouvre ou ferme la bande. ⌥-clic → ouvre ou ferme le déroulé natif
  (comportement du lot 2). `sendAction(on:)` garde `.leftMouseUp`, le modificateur
  est lu dans `NSApp.currentEvent`.
- **Né invisible (correction lot 2)** : la détection d'éviction ne joue
  aujourd'hui qu'au-delà de 24 pt, donc un chevron né évincé n'est jamais vu. À la
  création, après le premier placement (1 s au plus), un chevron non visible
  (`occlusionState`, pas d'écran, ou cadre hors écran) est retiré puis recréé une
  seule fois avec une position préférée par défaut (`NSStatusItem Preferred
  Position MultitoolMenuBarChevron`) qui le place à droite des icônes tierces,
  juste à gauche des icônes système. Mesuré avec les fausses icônes : une position
  de 260 depuis le bord droit les place juste à gauche du VPN. Valeur calculée
  depuis l'inventaire (bord gauche de la 1re icône système de la zone droite),
  repli à 260 sans Accessibilité. Le retrait passe par un chemin qui ne restaure
  pas l'ancienne position (`stop()` la réécrit), et la clé est écrite avant
  `autosaveName` (relecture B5). Cette position remplace le choix du ⌘-glisser,
  puisque ce choix menait à un chevron invisible. Log de la tentative et du
  résultat.
- **Fausses évictions (relecture C1, C2)** : ne pas compter d'éviction quand la
  barre est masquée (`NSMenu.menuBarVisible()` faux, plein écran, session
  verrouillée), ni au passage où la configuration d'écran vient de changer ;
  exiger 2 relectures concordantes. Le plafond d'éviction est remis à zéro quand
  Maxime déplace le chevron au ⌘-glisser (C4).
- **Clic refusé muet (correction lot 2)** : le clic ouvre toujours la bande, qui
  dit pourquoi elle est vide (rien d'évincé, Accessibilité absente).

### 3.5 Réglages et CLI

- Page « Barre des menus » : la section « Barre cachée » lit le cache.
- `--menubar-relay <bundleID>` dans `Main.swift` : le relais sans interface, pour
  les essais à l'écran sans lancer l'app complète. Il ne couvre que le menu natif
  et le clic simulé ; le menu redessiné demande l'app (relecture B11).

### 3.6 Pièges AppKit à traiter pendant le code (relecture B8, B10)

Bande : `canBecomeKey` vrai et `makeKey` pour Échap (comme `ClipboardPanel`),
premier clic accepté sans activation, info-bulles avec l'app inactive, fermeture
aussi au clic droit et au changement d'espace. Hauteur de barre : le max de
`frame.maxY - visibleFrame.maxY`, `NSStatusBar.system.thickness` et
`safeAreaInsets.top` (0 quand la barre se masque). Le tap de WindowMover voit les
clics simulés : le main thread reste libre pendant un relais.

## 4. Fichiers

Nouveaux : `MenuBar/MenuBarBand.swift`, `MenuBar/MenuBarBandView.swift`,
`MenuBar/MenuBarRelay.swift`. Modifiés : `MenuBarInventory.swift` (scan complet,
cache, `ownItems`), `MenuBarOverflow.swift` (ouvrir, fermer, attendre l'état),
`MenuBarChevron.swift` (clic, ⌥, né invisible), `AppDelegate.swift` (registre de
l'icône principale, popover), `Main.swift` (CLI), `MenuBarPane.swift`,
`docs/ROADMAP.md`.

## 5. Vérification

Pas de cible de test. Les fonctions pures (géométrie de la bande, choix du mode de
relais depuis un instantané, correction du cache) sont statiques et vérifiées par
`--menubar-dump` et `--menubar-relay`. Essai à l'écran avec les fausses icônes,
sur la liste d'icônes que Maxime valide, puis l'app complète avec son accord.

## 6. Risques

- Le clic simulé tombe à côté si le déroulé bouge entre la lecture et le clic :
  cadre relu juste avant, et clic annulé si X n'est plus à gauche de l'indicateur.
- Le curseur saute 11 à 25 ms.
- Une entrée gardée n'est prouvée valable que quelques secondes : l'arbre est relu
  à chaque clic, jamais réutilisé d'une ouverture à l'autre.
- Le déroulé peut rester ouvert si Multitool quitte au milieu d'un relais.
- macOS peut refermer le déroulé entre la relecture de son état et l'AXPress de
  Multitool, qui le rouvrirait alors : fenêtre courte, non supprimable.
- Les fenêtres et popovers des apps s'ouvrent à gauche de l'encoche.

## 7. Écarts retenus pendant le code

- Pas de scan complet après chaque clic relayé : il rallongerait le temps où le
  déroulé reste ouvert. Le cache est corrigé par les règles de péremption et relu
  à l'ouverture suivante de la bande.
- Position de secours du chevron : la constante mesurée 260. La valeur de
  `NSStatusItem Preferred Position` n'est pas une distance en points (260 a posé
  les fausses icônes vers x 1640 sur un écran de 2056 pt) : elle ne se calcule pas
  depuis l'inventaire.
- Popover de Multitool évincé : `NSApp.activate` reste, les contrôles SwiftUI du
  popover en ont besoin. Le risque cité (macOS referme le déroulé) ne joue pas : ce
  chemin n'ouvre pas le déroulé.
- Fin d'un menu natif : lue dans les fenêtres de niveau menu de l'app
  (`CGWindowList`, couche 101), pas dans le cadre de l'`AXMenu`.
- Relecture du code (23/11) intégrée : `held` relâché seulement après la fermeture
  lue, état ouvert lu sur l'identifiant `-expanded`, sauvetage du chevron après
  placement et 2 lectures concordantes, état d'échec de la bande, menu redessiné
  lancé depuis la run loop, entrées pressées sur la file du déroulé, refus « relais
  en cours » sans badge ni péremption.
