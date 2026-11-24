# Feuille de route

Quatre outils à ajouter à Multitool. On les fait un par un, du plus simple au plus
risqué, et chaque section se complète au fur et à mesure.

## Ordre proposé

| # | Module | État | Pourquoi à cette place |
|---|---|---|---|
| 0 | Socle modules | fait | Prérequis : le popover d'origine (Settings / Stats / Info) ne tenait pas quatre outils de plus. |
| 1 | Clipboard | fait (v1) | APIs publiques et stables, aucune nouvelle permission, périmètre clair. |
| 2 | Processus & ressources | en cours | Diagnostic du poste et éléments de démarrage. Lecture seule d'abord, actions ensuite. Quelques données demandent des droits admin. |
| 3 | Menu Bar | en cours | Pas d'API publique pour gérer les icônes des autres apps : le module règle les interrupteurs par app de macOS 27, par un outil signé Developer ID. À revérifier à chaque version de macOS. |
| 4 | Screenshot | à faire | Le plus gros chantier, et le plus personnel. Réutilise la sélection de zone et ScreenCaptureKit déjà présents. |

---

## 0. Socle modules (fait)

Objectif : pouvoir ajouter un outil sans toucher aux autres.

Réalisé le 4 novembre 2026 : un dossier par module, `Core/` pour les réglages, les
raccourcis globaux (`HotKeyCenter`) et les autorisations, une fenêtre de réglages
à navigation latérale (une page par module, sur le modèle de Koden), un popover
réduit à l'accès rapide, l'interface au design system Orbe. Voir le README.

- Un dossier par module sous `Sources/Multitool/` (ex. `Clipboard/`, `Processes/`),
  et un dossier `Core/` pour ce qui est partagé.
- Chaque module s'active ou se désactive dans les réglages, et ne démarre rien
  (event tap, timer, observateur) quand il est coupé.
- Le popover devient une navigation par module, avec les réglages de chaque module
  dans sa propre page.
- Raccourcis clavier globaux centralisés dans `Core/` : le Clipboard et le Screenshot
  en ont besoin, et deux modules ne doivent pas se disputer la même combinaison.
- Les permissions (Accessibilité, Enregistrement de l'écran) sont vérifiées et
  demandées par le socle, module par module.

## 1. Clipboard (façon PastePal) (v1 faite)

Fait dans la v1 : tout ce qui suit, sauf les questions ouvertes. Reste à vérifier
en usage réel le collage direct dans les apps qui filtrent les événements simulés
(certaines apps Electron, les champs de mot de passe).

**Besoin** : retrouver ce qui a été copié, le recoller sans le recopier.

Première version :
- Historique de ce qui est copié : texte, texte enrichi, images, fichiers.
- Un raccourci global ouvre un panneau flottant avec recherche ; Entrée colle
  l'élément dans l'app au premier plan.
- Épingler des éléments pour qu'ils ne sortent jamais de l'historique.
- Limite de taille de l'historique (nombre d'éléments et durée).

À ne pas oublier :
- Ignorer les contenus marqués comme sensibles ou temporaires par les gestionnaires
  de mots de passe (types `org.nspasteboard.ConcealedType` et
  `org.nspasteboard.TransientType`).
- Liste d'apps exclues (1Password, Trousseau…).
- Stockage local dans `~/Library/Application Support/Multitool/`.

Technique : macOS ne notifie pas les changements du presse-papiers, il faut
surveiller `NSPasteboard.changeCount` à intervalle court. Le collage se fait en
simulant ⌘V, ce qui utilise la permission Accessibilité déjà accordée.

Questions ouvertes :
- Faut-il synchroniser l'historique entre plusieurs Mac ?
- Snippets (textes types réutilisables) dans ce module ou plus tard ?

## 2. Processus & ressources : le poste de pilotage du Mac

**Besoin** : l'outil d'admin système du Mac, en version graphique. Voir tout ce qui
tourne et tout ce qui se lance seul, savoir à qui ça appartient, le couper ou le
rétablir, et trouver en quelques secondes ce qui ralentit le poste.

### Deux vues

**Diagnostic** : répondre à « pourquoi mon Mac rame ? » à tout moment.
- État du poste en un coup d'œil : CPU, pression mémoire et swap, débit disque,
  débit réseau, état thermique (bridage), batterie.
- Les plus gros consommateurs par axe (CPU, mémoire, écritures et lectures disque,
  réseau, énergie), regroupés par app : les « Helper » comptent pour l'app qui les
  a lancés.
- Une liste « Anormal » qui explique en clair ce qui cloche, par exemple :
  - un processus au-dessus de 80 % de CPU depuis plusieurs minutes ;
  - une mémoire qui grossit sans redescendre (fuite) ;
  - une pression mémoire haute ou un swap qui gonfle ;
  - un disque saturé en écriture par un seul processus ;
  - un service qui redémarre en boucle (launchd le relance sans cesse) ;
  - une app qui tient la saisie sécurisée et bloque les raccourcis
    (cas d'Arc, le 9 novembre) ;
  - un processus figé ou qui ne répond plus ;
  - le Mac bridé par la chaleur.
- Un historique court (une dizaine de minutes) pour voir les pics passés, pas
  seulement l'instant présent.
- L'icône de la barre des menus signale une anomalie, sans notification intrusive.

**Démarrage** : tout ce qui se lance seul, lisible par un humain.
- Inventaire complet : éléments d'ouverture de session, éléments d'arrière-plan
  déclarés par les apps, LaunchAgents (utilisateur et global), LaunchDaemons.
- Un nom lisible pour chaque élément, avec l'icône de son app :
  1. l'app qui contient l'exécutable (`/Applications/Foo.app/…` → Foo) ;
  2. sinon, l'éditeur qui l'a signé (« Developer ID Application: Google LLC ») ;
  3. sinon, un dictionnaire des libellés connus livré avec Multitool
     (`com.google.keystone.agent` → « Mise à jour Google ») ;
  4. en dernier recours, le libellé brut, nettoyé.
- Pour chaque élément : actif ou désactivé, en cours ou non, PID, dernier code de
  sortie, nombre de relances, ce qu'il consomme, et qui l'a installé.
- Actions : désactiver, réactiver, afficher le fichier dans le Finder, ouvrir
  le plist.
- Repérer les orphelins : un agent dont l'app a été supprimée.

### Ce que macOS permet sans droits administrateur

Mesuré le 15 novembre 2026 sur macOS 27.2 :

| Besoin | Sans droits admin | Avec droits admin |
|---|---|---|
| CPU, mémoire, disque, énergie par processus (`proc_pid_rusage`) | les processus de l'utilisateur, environ 70 % du total | tous |
| Réseau par processus (`nettop`) | oui | oui |
| Services launchd chargés (`launchctl print`) | oui, utilisateur et système | oui |
| Fichiers LaunchAgents et LaunchDaemons | lecture oui | lecture et écriture |
| Éléments d'arrière-plan (`sfltool dumpbtm`) | oui | oui |
| Désactiver un agent de l'utilisateur (`launchctl disable gui/…`) | oui | oui |
| Désactiver un agent global ou un daemon (`launchctl disable system/…`) | non | oui |

Conséquence : la vue Diagnostic et l'inventaire marchent sans rien demander.
Seuls les compteurs des processus système et la désactivation des daemons
demandent le mot de passe. Première approche : demander le mot de passe au moment
de l'action, par la fenêtre standard de macOS. Un helper privilégié permanent
(`SMAppService.daemon`) seulement si ça devient pénible.

### Découpage

1. **Diagnostic, lecture seule** (fait le 15 novembre 2026, à éprouver) : état du
   poste, gros consommateurs par axe, liste « Anormal », historique court, origines
   douteuses, service de lecture privilégié. Fenêtre dédiée, résumé dans le popover,
   icône de la barre des menus teintée en cas d'anomalie.
2. **Démarrage, lecture** : inventaire, noms lisibles, état, afficher dans le Finder.
3. **Démarrage, actions** : désactiver et réactiver, avec le mot de passe pour ce
   qui est système.
4. **Actions sur les processus** : quitter, forcer à quitter, ouvrir le dossier de
   l'exécutable.

Questions ouvertes :
- Seuils des anomalies : valeurs par défaut à ajuster à l'usage.
- Faut-il garder un historique plus long sur disque, pour retrouver le pic d'hier ?

## 3. Menu Bar (icônes cachées affichées dans une bande sous la barre)

> **Lot 6, 24 novembre 2026.** Le masquage par un chevron large (lots 2 à 4,
> décrits plus bas) laissait un vide dans la barre. Il est remplacé par les
> interrupteurs par app de macOS 27 : l'icône est retirée de la barre, qui se
> resserre. Le brief et les mesures sont dans `docs/menubar-lot6-brief.md`. Les
> sections qui suivent gardent l'historique des lots 1 à 4.

**Besoin** : choisir, icône par icône, ce qui reste dans la barre des menus, ce
qui passe dans une barre cachée et ce qui disparaît, sans jamais glisser une
icône à la main. La barre de Maxime est saturée : l'encoche cache déjà des icônes.

Comportement visé :
- Une page de réglages liste toutes les icônes de la barre avec leur application.
- Chaque icône a 2 cases : **Barre cachée** et **Masquée**. Sans case cochée, elle
  reste dans la **barre principale**. Multitool déplace l'icône lui-même.
- La barre cachée est une **bande dessinée par Multitool sous la barre des menus**,
  alignée à droite, sous l'horloge. Elle n'est pas à gauche de l'encoche.
- La bande montre l'icône de l'application, pas l'icône d'état : image fixe, sans
  pastille ni texte. Aucune permission nouvelle.
- Un clic sur une icône de la bande ouvre le vrai menu de l'icône.
- Une icône **Masquée** est évincée comme les autres, et la bande ne la dessine
  pas. Elle reste visible si on ouvre le déroulé natif de macOS à la main.
- La bande s'ouvre de 2 façons, au choix dans les réglages : au clic sur un chevron
  dédié, ou au survol du coin haut droit de l'écran.
- Une fois ouverte, elle reste tant que la souris est dans la barre ou dans la
  bande. Elle se referme dès que la souris en sort.
- L'horloge et le Centre de contrôle restent dans la barre principale : macOS ne
  permet pas de les déplacer.

### Ce que macOS 27 impose

Mesuré le 22 novembre 2026 sur macOS 27.2.1, écran du MacBook seul :

| Constat | Conséquence |
|---|---|
| La barre est dessinée par un seul processus, `MenuBarAgent`. Les icônes n'ont plus de fenêtre propre. | La méthode d'Ice (lister les fenêtres par `CGWindowList`, capturer chaque icône) ne marche plus. |
| L'Accessibilité rend chaque icône visible avec son app, sa position et sa largeur (`AXExtrasMenuBar`). | L'inventaire ne demande aucune nouvelle permission. |
| Quand la place manque, macOS évince les icônes les plus à gauche vers son propre débordement. | Un séparateur de largeur calibrée masque les icônes à sa gauche. |
| Un séparateur trop large est évincé seul et ne masque rien. | Règle prouvée à l'écran : le chevron va de son bord droit au bord droit de l'encoche, moins 48 points pour l'indicateur natif. |
| La fenêtre du chevron suit sa place réelle, et elle est marquée non visible (`occlusionState`) quand macOS l'évince. | Multitool détecte l'éviction du chevron et le rétrécit par pas de 20 points. |
| L'indicateur natif répond à `AXPress`. Son identifiant est `menu-bar-overflow-indicator` fermé et `menu-bar-overflow-indicator-expanded` ouvert. | Multitool ouvre et ferme le déroulé natif, et sait dans quel état il est. Ouvert par `AXPress`, il ne se referme pas seul. |
| Déroulé fermé, les icônes évincées sortent de l'Accessibilité. | Multitool ne peut ni les photographier ni les presser sans ouvrir le déroulé. |
| Déroulé ouvert, une icône évincée accepte `AXPress` : son menu s'ouvre sous sa place réelle, à gauche de l'encoche. `AXCancel` sur le menu le referme. | Le clic relayé depuis la bande est possible. Le menu ne s'ouvre pas sous la bande. |
| Une icône créée dans une barre saturée naît dans le déroulé, donc invisible. | Le chevron doit être amené dans la barre visible à la première activation. |
| Un glisser `⌘` simulé déplace une icône, dans les 2 sens. | C'est le moyen de ranger une icône dans une zone. Le curseur est pris moins d'une seconde. |

Mesuré le 23 novembre 2026 sur macOS 27.2, MacBook à encoche, barre saturée par
des icônes de test (séries A à D) :

| Constat | Conséquence |
|---|---|
| Déroulé ouvert par `AXPress`, une icône évincée est lisible en 30 à 54 ms. Il se referme en 50 à 85 ms. macOS le referme seul quand une app passe au premier plan. | Multitool relit l'état de l'indicateur avant chaque pression. |
| Déroulé fermé, une app évincée perd tout son `AXExtrasMenuBar`. | La bande dessine un cache, rempli déroulé ouvert. |
| Le menu natif d'une icône évincée s'ouvre sous sa place dans le déroulé, à gauche de l'encoche. | Le menu est relu et redessiné sous la bande. |
| Une entrée de menu lue déroulé ouvert se presse déroulé refermé. | Le menu redessiné presse l'entrée réelle. |
| `AXPress` sur une icône sans menu : Google Drive, Slack et Notion répondent, OneDrive l'ignore, Sophos Connect plante. | Jamais d'`AXPress` sur une icône sans menu : clic simulé, déroulé ouvert, curseur remis en place (11 à 25 ms). |
| Les fenêtres et popovers ouverts ainsi s'ancrent à gauche de l'encoche. | Limite acceptée. |
| Avec 32 icônes évincées, le déroulé natif n'en montre que 24. | La bande ne voit que ce que le déroulé montre. |
| Lire les 155 apps lancées une à une prend 2 s, dont 900 ms pour 3 apps qui ne répondent pas. | Lecture en parallèle, apps d'arrière-plan et apps muettes écartées. |

Décisions du 22 novembre 2026 :
- Matin : Multitool pilote le déroulé natif, la bande sous la barre est abandonnée
  (les icônes cachées semblaient hors d'atteinte).
- Soir, après l'essai à l'écran du lot 2 : la bande revient. Le déroulé natif à
  gauche de l'encoche ne convient pas sur une barre saturée, et le clic relayé est
  prouvé. Le déroulé natif reste le mécanisme, la bande en est la façade.
- La bande affiche l'icône de l'application, sans permission Enregistrement de
  l'écran.

### Découpage

1. **Inventaire, lecture seule** (fait) : page de réglages avec les icônes, leur
   app et leur zone actuelle.
2. **Chevron et masquage** (fait) : le chevron séparateur, sa largeur calibrée.
   Corrigés au lot 3 : le chevron né invisible est recréé une fois à droite des
   icônes tierces, la barre masquée ne compte plus comme une éviction, le clic
   ouvre toujours la bande, la page ne montre plus de faux « Multitool ».
3. **Bande** (écrit, essayé le 23/11, brief dans `docs/menubar-lot3-brief.md`) :
   la fenêtre sous l'horloge, les icônes d'application, le clic relayé (menu
   redessiné, menu natif ou clic simulé selon l'icône). Le chevron ouvre la bande,
   le ⌥-clic le déroulé natif. Corrections du lot 2 faites.
4. **Classement** : les 2 cases par icône, Multitool déplace l'icône par glisser
   `⌘` simulé. Une nouvelle icône arrive en barre principale.
5. **Survol** : ouverture par le coin haut droit, fermeture à la sortie de la
   barre et de la bande.

Questions ouvertes :
- Les fenêtres et popovers des icônes sans menu s'ouvrent à gauche de l'encoche.
- Le déroulé natif a une capacité limitée : au-delà, des icônes échappent à la bande.
- Écran externe, sans encoche : aucun masquage aujourd'hui, non testé.
- Identifiant stable d'une icône, nécessaire au classement : l'inventaire numérote
  par position.
- L'icône de Multitool devient noire quand le moniteur signale une anomalie : la
  teinte d'alerte ne sort pas en couleur sur macOS 27.

## 4. Screenshot (dans l'esprit de Shottr)

**Besoin** : à compléter, plans à détailler.

Ce que le code existant apporte déjà :
- `RegionSelector` : sélection d'une zone de l'écran à la souris.
- ScreenCaptureKit et la permission Enregistrement de l'écran, utilisés par
  Region Share.

Plans :
- _à compléter_
