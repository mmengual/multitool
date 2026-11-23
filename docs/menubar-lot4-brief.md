# Brief — Barre des menus, lot 4 : le classement des icônes (version 2)

Branche `menubar` (lot 3 à `f5daaed`). Cible : macOS 27.2, MacBook à encoche.
Version 2 du 23/11 : le rangement écrit la table de positions de macOS au lieu de
glisser les icônes. L'idée vient de Thaw 3 (GPL-3.0), aucun code n'en est repris.
La version 1 (⌘-glisser seul) est abandonnée, le glisser devient le secours.

Décisions de Maxime du 23/11 : ordre de macOS, rangement quand une case change,
nouvelle icône laissée en place et signalée, place restante affichée, pas de
copie de code de Thaw.

## 1. Ce que les mesures imposent

| Mesure (23/11, séries E et G) | Conséquence |
|---|---|
| macOS 27 garde l'ordre de la barre dans `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`, table `TrailingItemPreferredPositions`. | Une seule table à lire et à écrire. |
| Une entrée par icône : `status:<bundleID>::<nom>` (nom : `Item-0`, un `autosaveName` ou un UUID) ou `module:<nom>` pour une icône système. La valeur est un poids qui croît de droite à gauche (Horloge 0, chevron 339). | Clé stable par icône, fournie par macOS. L'ordre des poids est l'ordre à l'écran. |
| Toute icône dont le poids dépasse celui du chevron est à sa gauche, donc cachée. | Ranger = écrire un poids d'un côté ou de l'autre de celui du chevron. |
| Le dossier est protégé : lecture refusée sans accès accordé par l'utilisateur. | Une permission : Maxime désigne le fichier une fois (panneau d'ouverture, signet gardé), ou accès complet au disque. |
| Écrire par `CFPreferences` (domaine = chemin complet sans `.plist`) passe. `MenuBarAgent` n'applique l'écriture que lorsqu'une icône du processus qui a écrit est créée ou change de longueur. Effet en moins de 3 s. Relancer l'app visée ne suffit pas. | Après chaque écriture, le chevron change de longueur d'1 pt puis revient. |
| Une app peut avoir plusieurs entrées (Notion : `Item-0` et un UUID). Seule l'entrée active agit. `MenuBarAgent` réécrit le poids de l'entrée active quand la barre bouge. | Trouver l'entrée active avant d'écrire (§3.2). |
| ⌘-glisser simulé : 680 ms dans les 2 sens, déroulé ouvert pour une icône évincée. | Secours si l'écriture n'est pas suivie d'effet. |
| Une icône de 26 pt apparue dans la barre a fait compter 2 évictions au chevron, plafonné à 413 pt jusqu'à la relance. Une icône cachée est alors réapparue à sa gauche. | Défaut du lot 3 à corriger ici (§3.5). |

## 2. Périmètre

Dans le lot : la permission d'accès à la table, les 2 cases par icône, le
rangement par écriture de poids avec le glisser en secours, la place restante,
« Masquée » absente de la bande, les symboles des icônes système dans la bande,
le plafond d'éviction du chevron levé quand la place revient, le glyphe du
chevron à gauche (proposé, à confirmer), le fichier `LICENSE` GPL-3.0 (à
confirmer).

Hors lot : le survol (lot 5), l'écran externe, les vraies images par
enregistrement d'écran, le tri à l'intérieur d'une zone, cacher une icône sans
laisser de vide (Thaw y arrive par un binaire fermé, non repris).

## 3. Conception

### 3.1 Accès à la table (`MenuBarLayoutStore`)

- Sans accès : la page affiche « Accès à la disposition de la barre » avec un
  bouton. Il ouvre un `NSOpenPanel` placé sur le dossier, Maxime choisit
  `com.apple.MenuBar.plist`. Multitool garde un signet (`bookmarkData`) et le
  reprend à chaque lancement. Si l'app a l'accès complet au disque, rien à faire.
- Lecture : `CFPreferencesCopyValue` après `CFPreferencesSynchronize`, jamais le
  fichier lu directement (le service de préférences garde sa copie).
- Écriture : relire la table, changer les seules clés voulues, réécrire la table
  entière, synchroniser. Sur une file série. Avant la 1re écriture d'une session,
  une copie de la table dans `Application Support/Multitool/menubar-backup.plist`.
- À vérifier en premier pendant le code : que le signet d'un fichier choisi
  suffit à `CFPreferences`, qui passe par le service de préférences. Sinon repli :
  accès complet au disque, expliqué dans la page.

### 3.2 Clé et entrée active

- Clé de classement d'une icône : la clé de la table, telle quelle.
- Lien entre une icône lue par l'Accessibilité et son entrée : même `bundleID`,
  puis même rang. Les icônes d'une app sont triées par position à l'écran, ses
  entrées par poids, et on apparie dans l'ordre. Une entrée en trop (périmée) est
  celle dont le poids n'a pas changé depuis le plus longtemps : Multitool garde
  le dernier poids vu de chaque entrée et la date du changement.
- Icônes système : `module:<nom>` relié à l'identifiant de l'icône
  (`com.apple.menuextra.wifi` ↔ `module:WiFi`) par une table de correspondance
  courte, le reste par le rang parmi les icônes de `MenuBarAgent`.
- Si l'appariement est ambigu (2 entrées candidates, aucune n'a bougé) : écrire
  le même poids dans les 2, c'est sans effet sur l'entrée périmée.
- Une app sans entrée dans la table (jamais déplacée) : son icône n'est pas
  classable tant que macOS ne l'a pas écrite. La page le dit.

### 3.3 Classement et page de réglages

- `Settings.menuBarPlacements` : `clé → .main | .hidden | .masked`, en JSON.
- Page : une ligne par icône, avec l'icône, le nom, la zone actuelle et 2 cases.
  **Barre cachée** : à gauche du chevron, dessinée dans la bande. **Masquée** : à
  gauche du chevron, absente de la bande, coche et grise « Barre cachée ». Aucune
  case : barre principale.
- Premier usage : la 1re lecture enregistre en silence la zone actuelle de chaque
  icône. Une icône apparue ensuite porte « Nouvelle » jusqu'à ce qu'une case soit
  touchée ou « Garder ici » cliqué.
- **Place libre** : longueur cible du chevron (`targetLength`, sans plafond) −
  glyphe − passages en attente. Une icône coûte sa largeur + 4 pt. Un passage en
  barre principale au-delà est refusé, la ligne dit combien il manque. Écran sans
  encoche : rien n'est refusé, la page le dit.
- Les icônes non classables (horloge et Centre de contrôle si macOS refuse, apps
  sans entrée) sont listées sans cases.

### 3.4 Rangement (`MenuBarArranger`)

- **Vers la barre principale** : poids = milieu entre le poids du chevron et celui
  de son voisin de droite. **Vers la barre cachée ou Masquée** : milieu entre le
  poids du chevron et celui de son voisin de gauche (chevron + 10 sans voisin).
  L'ordre des autres icônes ne change pas.
- Puis **relecture forcée** : le chevron passe à longueur + 1 pt, revient 300 ms
  après. Pendant ce temps son recalcul et son compte d'évictions sont suspendus
  (drapeau « rangement en cours », aussi lu par le scan léger).
- **Vérification** après 1 s, par un scan léger : barre principale = icône visible
  à droite de l'indicateur natif, cachée = app lancée et icône non visible. Sinon
  un 2e essai, puis le **secours ⌘-glisser** (série E : déroulé ouvert pour une
  icône évincée, attente que l'icône soit lisible, 400 ms sans entrée clavier ni
  souris avant de partir). Encore un échec : « Non déplacée » sur la ligne, cause
  dans le journal. Cache des évincées marqué périmé dans tous les cas.
- **Quand** : au changement d'une case, et au bouton « Ranger maintenant ». Pas de
  rangement automatique (macOS garde la place après une relance, série E).
- Plusieurs cases changées : les écritures sont groupées (300 ms), une seule
  relecture forcée.
- Sans accès à la table : le secours ⌘-glisser seul, la page le dit.

### 3.5 Chevron

- **Plafond d'éviction levé quand la place revient** : quand le chevron est
  visible et qu'une icône tierce est visible à sa gauche (entre l'indicateur
  natif et lui), le plafond est remis à zéro et la longueur recalculée. Au plus
  une fois par minute, pour ne pas osciller.
- Glyphe dessiné à l'extrémité gauche, à côté de l'indicateur natif (proposé).

### 3.6 Bande

- « Masquée » non dessinée. Le ⌥-clic sur le chevron ouvre le déroulé natif.
- Symbole SF pour une icône système sans icône d'application, choisi par sa clé
  (`module:Bluetooth` → `bluetooth`…), repli `square.grid.2x2`.

### 3.7 CLI

- `--menubar-layout` : imprime la table avec, par icône lue, son entrée appariée.
- `--menubar-move <clé> main|hidden` : n'écrit pas depuis la CLI (le processus n'a
  pas de chevron pour forcer la relecture). Il demande le rangement à l'app lancée
  par une notification distribuée, et attend le résultat.

## 4. Fichiers

Nouveaux : `MenuBar/MenuBarLayoutStore.swift`, `MenuBar/MenuBarArranger.swift`.
Modifiés : `MenuBarInventory.swift` (clé appariée), `MenuBarChevron.swift`
(relecture forcée, plafond, glyphe), `MenuBarOverflow.swift` (drapeau),
`MenuBarBand*.swift`, `Settings.swift`, `MenuBarPane.swift`, `Main.swift`,
`docs/ROADMAP.md`, `LICENSE`.

## 5. Vérification

Série H à l'écran, icônes validées par Maxime : `--menubar-layout`, puis l'app
installée remplacée, accès accordé par Maxime, cases cochées (une icône à entrée
simple, une à UUID, une icône système), « Masquée », secours ⌘-glisser forcé.

## 6. Risques

- La table et son format sont internes à macOS : une mise à jour peut les changer.
  Le secours ⌘-glisser reste, et la copie de la table permet de revenir.
- Écrire la mauvaise entrée n'a aucun effet : c'est la vérification qui le voit.
- L'appariement par rang se trompe si une app a 2 icônes et 3 entrées dont une
  périmée récente.
- La relecture forcée change la longueur du chevron d'1 pt pendant 300 ms : un
  mouvement d'1 pt des icônes à sa gauche, toutes cachées.
- Le déclencheur exact de la relecture (création d'icône ou changement de
  longueur) n'est pas isolé : la série H le tranche avant le reste.

## 7. Corrections après relecture (23/11), elles priment sur le texte ci-dessus

- **Accès (§3.1)** : la série G a écrit depuis un terminal qui avait l'accès
  complet au disque. Rien ne prouve qu'un fichier choisi dans un panneau suffise :
  l'écriture passe par le service de préférences, pas par Multitool. **Premier
  essai du lot, avant tout autre code** : depuis l'app, choisir le dossier
  `Preferences` (pas le fichier), relancer l'app, lire, écrire, voir l'effet dans
  la barre. Voie nominale tant que ce n'est pas prouvé : l'accès complet au disque
  accordé à Multitool. La CLI ne prouve rien sur l'app : elle hérite des droits du
  terminal.
- **Relecture forcée (§3.4)** : pour un passage en barre principale, le chevron
  est d'abord raccourci du coût de l'icône, et ce changement de longueur sert de
  relecture forcée. Sinon l'icône qui arrive le pousse et il compte une éviction,
  le défaut mesuré en série G. Le drapeau « rangement en cours » tient jusqu'à la
  fin de la vérification.
- **Vérification (§3.4)** : par sondage jusqu'à 3 s. Elle relit la table (poids de
  l'entrée du bon côté de celui du chevron) et, quand l'icône est lisible, sa
  position par rapport au chevron. « Icône non visible » seule ne prouve rien (app
  muette, écran sans encoche).
- **Chaîne d'essais (§3.4)** : 1 écriture, puis le ⌘-glisser, puis « Non
  déplacée ». Pas de 2e écriture.
- **Plafond d'éviction (§3.5)** : levé au plus une fois pour une même situation
  (écrans, place du chevron, ensemble des icônes visibles), indicateur natif
  fermé, et évalué par un scan léger toutes les 60 s même hors de la page de
  réglages.
- **Barre et cases qui divergent** (Maxime glisse une icône à la main après
  l'avoir classée) : **la barre fait foi**, la case suit au scan suivant. À
  confirmer par Maxime.
- **Appariement (§3.2)** : fait au scan complet seulement. On aligne la suite
  entière des icônes à l'écran sur la table triée par poids, puisque l'ordre
  global est mesuré. Les icônes système hors table de correspondance et les
  icônes sans entrée ne sont pas classables par écriture : elles passent par le
  ⌘-glisser. Un processus sans `bundleID` est apparié par son nom de processus.
- **Poids (§3.4)** : à mesurer en série H : poids fractionnaire accepté ou non,
  renumérotation par `MenuBarAgent`, stabilité d'une clé UUID après relance de
  l'app. Renumérotation locale si l'écart entre 2 poids passe sous 1. L'entrée du
  chevron est désignée par son `autosaveName` et le `bundleID` du processus.
- **Sérialisation** : l'arrangeur passe par `MenuBarOverflow.queue`.
- **Sauvegarde** : la toute première copie de la table est gardée, jamais
  écrasée, avec un bouton « Restaurer la disposition d'origine ».
- **Retirés du lot** : `--menubar-move` (n'importe quel processus pourrait
  déclencher un rangement), le groupage des écritures. `LICENSE` GPL-3.0 : hors
  lot, à la demande de Maxime.

## 8. Écarts retenus pendant le code

- L'appariement icône ↔ entrée se fait par propriétaire (rang, puis bornes des
  voisins), à chaque scan. Un appariement sûr est retenu pour la session, et un
  choix enregistré avant d'avoir une entrée sûre migre vers sa nouvelle clé.
- Pas de renumérotation des poids : le milieu entre le chevron et son voisin
  réduit l'écart à chaque passage. `MenuBarAgent` réécrit lui-même les poids quand
  la barre bouge (mesuré : Tailscale 794 puis 810), ce qui rouvre les écarts.
- Pas de suivi du dernier poids vu pour désigner une entrée périmée : une icône
  ambiguë reçoit le poids dans toutes ses entrées.
- Une icône sans entrée dans la table garde ses cases et passe par le ⌘-glisser,
  la ligne le dit.
- Relecture du code (23/11) intégrée : côté réel mesuré par rapport au chevron,
  « la barre fait foi » suspendu sur un écran sans encoche, icône non dessinée
  comptée cachée seulement si son poids le confirme, icône retrouvée par son
  identifiant avant son index, retour de longueur du chevron annulé si un autre
  rangement l'a changée, table lue hors du main thread.
