# Feuille de route

Quatre outils à ajouter à Multitool. On les fait un par un, du plus simple au plus
risqué, et chaque section se complète au fur et à mesure.

## Ordre proposé

| # | Module | État | Pourquoi à cette place |
|---|---|---|---|
| 0 | Socle modules | fait | Prérequis : le popover d'origine (Settings / Stats / Info) ne tenait pas quatre outils de plus. |
| 1 | Clipboard | fait (v1) | APIs publiques et stables, aucune nouvelle permission, périmètre clair. |
| 2 | Processus & ressources | à faire | Lecture seule d'abord, actions ensuite. Quelques données demandent des droits admin. |
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

## 2. Processus & ressources

**Besoin** : savoir ce qui tourne, ce qui consomme, et ce qui se lance tout seul.

Première version, en lecture seule :
- Liste des processus regroupés par app (les « Helper » rattachés à l'app qui les
  a lancés), avec CPU, mémoire et énergie.
- Vue en arbre parent → enfants pour comprendre qui a lancé quoi.
- Tri par consommation, historique court (quelques minutes) pour repérer les pics.

Deuxième temps :
- Inventaire de ce qui démarre seul : éléments d'ouverture de session,
  LaunchAgents (`~/Library/LaunchAgents`, `/Library/LaunchAgents`),
  LaunchDaemons (`/Library/LaunchDaemons`), extensions système.
- Pour chaque élément : quelle app l'a installé, s'il tourne, ce qu'il consomme.
- Actions : quitter ou forcer à quitter un processus, désactiver un élément de
  démarrage.

Technique : `libproc` (`proc_listpids`, `proc_pidinfo`) suffit pour les processus
de l'utilisateur. Les détails des processus système, l'inventaire complet des
éléments de démarrage (`sfltool dumpbtm`) et leur désactivation demandent des
droits administrateur, donc un helper privilégié à prévoir. La consommation réseau
par processus n'a pas d'API publique : à garder pour plus tard.

Questions ouvertes :
- Fenêtre dédiée ou seulement une vue compacte dans le popover ?
- Alertes quand un processus dépasse un seuil ?

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
