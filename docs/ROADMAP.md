# Feuille de route

Quatre outils à ajouter à Multitool. On les fait un par un, du plus simple au plus
risqué, et chaque section se complète au fur et à mesure.

## Ordre proposé

| # | Module | État | Pourquoi à cette place |
|---|---|---|---|
| 0 | Socle modules | fait | Prérequis : le popover d'origine (Settings / Stats / Info) ne tenait pas quatre outils de plus. |
| 1 | Clipboard | fait (v1) | APIs publiques et stables, aucune nouvelle permission, périmètre clair. |
| 2 | Processus & ressources | cadré | Diagnostic du poste et éléments de démarrage. Lecture seule d'abord, actions ensuite. Quelques données demandent des droits admin. |
| 3 | Menu Bar | à faire | Repose sur des contournements (macOS n'offre pas d'API pour gérer les icônes des autres apps). Fragile d'une version de macOS à l'autre. |
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

1. **Diagnostic, lecture seule** : état du poste, gros consommateurs par axe,
   liste « Anormal », historique court. Fenêtre dédiée, résumé dans le popover.
2. **Démarrage, lecture** : inventaire, noms lisibles, état, afficher dans le Finder.
3. **Démarrage, actions** : désactiver et réactiver, avec le mot de passe pour ce
   qui est système.
4. **Actions sur les processus** : quitter, forcer à quitter, ouvrir le dossier de
   l'exécutable.

Questions ouvertes :
- Seuils des anomalies : valeurs par défaut à ajuster à l'usage.
- Faut-il garder un historique plus long sur disque, pour retrouver le pic d'hier ?

## 3. Menu Bar (façon Bartender / Ice)

**Besoin** : garder un nombre fixe d'icônes visibles dans la barre des menus, et
ranger les autres dans un menu secondaire.

Comportement visé :
- Les N icônes les plus à droite restent visibles, N étant réglable.
- Les autres sont masquées et accessibles depuis un menu secondaire ouvert par
  l'icône Multitool (ou un chevron dédié).
- Choisir quelles apps sont toujours visibles, et lesquelles sont toujours masquées.

Technique, du plus simple au plus délicat :
1. **Masquer** : Multitool place une icône « séparateur » dont la largeur devient
   énorme ; tout ce qui est à sa gauche est poussé hors de l'écran. C'est la
   méthode de Hidden Bar, simple et fiable.
2. **Afficher les icônes masquées dans un menu** : il faut lister les icônes
   (fenêtres de la barre via `CGWindowList`), capturer leur image (permission
   Enregistrement de l'écran) et simuler un clic sur l'icône d'origine quand on
   clique sur sa copie. C'est la méthode d'Ice, plus fragile.
3. **Réordonner** automatiquement pour respecter « N visibles » : simuler un
   glisser avec ⌘ sur les icônes. Le plus fragile des trois.

À vérifier avant de se lancer : les réglages natifs de la barre des menus dans les
versions récentes de macOS (autoriser ou non une app dans la barre), et
l'encoche des MacBook, derrière laquelle des icônes disparaissent sans prévenir.

## 4. Screenshot (dans l'esprit de Shottr)

**Besoin** : à compléter, plans à détailler.

Ce que le code existant apporte déjà :
- `RegionSelector` : sélection d'une zone de l'écran à la souris.
- ScreenCaptureKit et la permission Enregistrement de l'écran, utilisés par
  Region Share.

Plans :
- _à compléter_
