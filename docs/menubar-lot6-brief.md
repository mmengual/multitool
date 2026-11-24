# Brief — Barre des menus, lot 6 : cacher sans vide

Branche à créer depuis `main` (0.4.1, `c820669`). Cible : macOS 27.2.
Décision de Maxime du 24/11 : partir sur l'interrupteur natif de macOS par app, qui
cache une icône sans laisser de vide. Le chevron large (lots 2 à 4) laissait un
vide de plusieurs centaines de points dans la barre.

## 1. Ce que les mesures imposent

| Mesure (23 et 24/11, série I, sur Notion) | Conséquence |
|---|---|
| macOS 27 garde un interrupteur par app (Réglages Système > Barre des menus) dans le domaine de préférences `group.com.apple.controlcenter`, clé `trackedApplications` : un plist binaire, tableau alterné clé (`bundle`) et valeur (`isAllowed`, `location`, `menuItemLocations`). 73 apps sur ce Mac. | Cacher = `isAllowed` à faux pour le `bundleID` de l'app. |
| Écrire par le chemin du fichier (accès complet au disque) passe mais n'est pas appliqué, et macOS réécrit la liste en moins de 20 s. | Voie écartée. |
| Un binaire signé **Developer ID** avec l'entitlement `com.apple.security.application-groups = [group.com.apple.controlcenter]` lit et écrit le domaine nommé (`CFPreferencesSetValue` puis `CFPreferencesSynchronize`). Signé Apple Development, il est tué au lancement. | Multitool doit être signé Developer ID avec cet entitlement. Plus besoin de l'accès complet au disque pour cacher. |
| Éteindre : icône partie en 713 et 861 ms, les icônes à sa gauche se resserrent, aucun vide. Rallumer : icône revenue en 94 et 99 ms, à la même place. `MenuBarAgent` n'est pas relancé. | Rallumer est assez rapide pour un clic dans la bande. |
| Tient après avoir quitté et relancé l'app éteinte. | L'état est durable, aussi si Multitool n'est plus là. |
| L'`AXExtrasMenuBar` d'une app éteinte reste lisible, avec son ancien cadre. | Ne jamais déduire « visible » de l'Accessibilité de l'app. Vérifier par l'élément sous le point (`AXUIElementCopyElementAtPosition`) : il appartient à l'app, rôle `AXMenuBarItem`. |
| Constats tiers, non revérifiés : macOS réécrit parfois la liste (apps non lancées retirées), l'horloge, le Centre de contrôle, Siri et Spotlight n'y sont pas, Wi-Fi et Bluetooth n'obéissent pas toujours. | Relire juste avant d'écrire, ne toucher qu'aux apps tierces. |

## 2. Périmètre

Dans le lot : la signature Developer ID avec l'entitlement, le masquage par
l'interrupteur natif pour « Barre cachée » et « Masquée », la bande qui rallume
l'icône au clic puis la recache, le journal des apps éteintes et leur remise en
service, le chevron ramené à un bouton de 24 pt, le retrait du masquage par
largeur du chevron et du rangement par table de positions.

Hors lot : cacher les icônes système (elles restent dans la barre), l'ordre des
icônes, la notarisation, les vraies images des icônes (lot suivant), le survol.

## 3. Conception

### 3.1 Signature

- `scripts/build-app.sh` signe avec l'identité « Developer ID Application » quand
  elle existe sur le Mac, avec `--options runtime` et un fichier
  `Resources/Multitool.entitlements` qui porte le groupe. Sinon il signe comme
  aujourd'hui (Apple Development, sans l'entitlement) et prévient : le masquage
  natif est alors indisponible, l'app le dit dans la page.
- Sparkle, le helper privilégié et l'app sont signés par la même identité (le
  helper vérifie l'équipe, inchangée : `UGUP3H993V`).
- Conséquences à vérifier en premier, avant tout autre code :
  1. l'app signée ainsi se lance et lit la liste (pas tuée par macOS) ;
  2. le helper `SMAppService` se réenregistre ;
  3. Sparkle accepte la mise à jour 0.4.1 (Apple Development) → nouvelle version
     (Developer ID) : la clé EdDSA est la même, l'identité de signature change ;
  4. l'Accessibilité est à accorder de nouveau, 1 fois par Mac.
- Le certificat n'existe que sur le MacBook d'essai : les releases partent de ce Mac
  tant qu'il n'est pas exporté.

### 3.2 `MenuBarVisibilityStore`

- Lit et écrit `trackedApplications` par le domaine nommé. Lecture : plist binaire
  → tableau alterné. `isAllowed(bundleID)`, `hasEntry(bundleID)`.
- Écriture : sur la file série du module, **relire, modifier la seule entrée
  visée, réécrire le tableau entier, synchroniser**, puis relire pour confirmer.
  Jamais d'écriture à partir d'une lecture ancienne.
- `available` : faux si la lecture rend nil (app non signée Developer ID).
- Avant la 1re écriture, copie du blob d'origine dans
  `Application Support/Multitool/menubar-visibility-origin.plist`, jamais écrasée.

### 3.3 Journal et remise en service

- `Settings.menuBarSwitchedOff` : les `bundleID` que Multitool a éteints, écrit
  **avant** d'éteindre, retiré **après** avoir rallumé.
- Tout est rallumé : quand le module est désactivé, quand Multitool quitte
  (`applicationWillTerminate`), et au lancement pour toute app du journal dont le
  classement n'est plus « caché ». Après un plantage, les icônes restent éteintes
  jusqu'au prochain lancement de Multitool, qui réconcilie. Elles restent
  réglables dans Réglages Système.
- Une app que Maxime a éteinte lui-même dans Réglages Système n'est pas dans le
  journal : Multitool ne la rallume jamais.

### 3.4 Classement

- Les 2 cases restent. Clé du classement : le `bundleID` (le réglage de macOS vaut
  pour l'app entière). Migration : un choix du lot 4 enregistré sous une clé
  `status:<bundleID>::…` passe sous `<bundleID>`.
- « Barre cachée » et « Masquée » : app éteinte. Aucune case : app allumée.
- **La barre fait foi** : si une app classée cachée est trouvée allumée hors d'un
  relais (Maxime l'a rallumée dans Réglages Système), sa case se décoche.
- La page liste les apps qui ont une icône lisible ou qui sont dans le journal.
  Sans entrée dans la liste de macOS, ou icône système : pas de cases, la ligne
  dit pourquoi. La place libre, « Ranger maintenant », l'accès à la disposition et
  « Restaurer la disposition » du lot 4 sont retirés.

### 3.5 La bande

- Elle montre les apps classées « Barre cachée » qui sont lancées, par l'icône de
  l'application. Plus de lecture du déroulé natif, plus de cache des évincées.
- **Clic sur une icône** :
  1. rallumer l'app, attendre que son icône soit dessinée (élément sous le point
     au centre du cadre lu par l'Accessibilité, 500 ms au plus) ;
  2. presser : `AXPress` si l'icône a un `AXMenu` (rôle seul, jamais ses entrées),
     clic simulé sinon. Le menu ou la fenêtre s'ouvre sous la vraie icône ;
  3. recacher quand l'app n'a plus de fenêtre de niveau menu ou popover à l'écran
     (`CGWindowList`), relu toutes les 200 ms, au plus tôt 1,5 s après le clic, au
     plus tard après 60 s.
- Le menu redessiné sous la bande du lot 3 est retiré : il n'a plus de raison
  d'être et lisait les entrées des menus.
- Si le relais échoue, l'app est recachée et la cellule porte le badge d'alerte.

### 3.6 Chevron

- Bouton de 24 pt, clic = bande. Plus de largeur calculée, plus de détection
  d'éviction, plus de plafond. Le sauvetage « né invisible » reste. Le ⌥-clic reste
  (déroulé natif, utile si la barre déborde encore).
- À l'activation du module sur une barre qui utilisait le lot 4, rien n'est
  déplacé : les icônes autrefois à gauche du chevron redeviennent visibles tant
  qu'elles ne sont pas classées.

### 3.7 Code retiré

`MenuBarLayoutStore`, `MenuBarArranger` (poids, ⌘-glisser), le calcul de longueur
du chevron, le scan complet et le cache des évincées de `MenuBarInventory`, le
menu redessiné et le mode « menu natif à travers le déroulé » de `MenuBarRelay`.
`MenuBarOverflow` ne garde que le ⌥-clic.

## 4. Vérification

Série J à l'écran, avec l'accord de Maxime : build Developer ID installé, les 4
points du §3.1, puis cases de Notion (Barre cachée, Masquée), clic dans la bande
sur une icône à menu (Teleport Connect) et sans menu (OneDrive), désactivation du
module (tout revient), arrêt brutal de Multitool puis relance (réconciliation).

## 5. Risques

- L'entitlement vise un groupe qui appartient à Apple : une mise à jour de macOS
  peut le refuser, et l'app ne se lancerait plus. Parade : le build de secours
  sans l'entitlement, et la 0.4.1 qui reste publiée.
- Une icône éteinte par Multitool reste éteinte s'il est désinstallé sans être
  quitté proprement. Elle se rallume dans Réglages Système.
- macOS peut réécrire la liste entre notre lecture et notre écriture : fenêtre de
  quelques millisecondes, écriture confirmée par relecture.
- Le réglage vaut pour l'app entière : une app à 2 icônes les cache ensemble.
- Recacher trop tôt ferme un popover encore utile : la règle du §3.5 est à
  ajuster à l'essai.

## 6. Corrections après relecture (24/11), elles priment sur le texte ci-dessus

- **Porteur de l'entitlement (§3.1)** : un petit exécutable dédié dans le bundle,
  `MultitoolVisibility`, signé Developer ID avec l'entitlement et le hardened
  runtime. L'app le lance pour lire et écrire la liste (arguments, réponse en
  JSON). **L'app, Sparkle et le helper root gardent leur signature actuelle** :
  pas d'Accessibilité à redonner, pas de risque sur les mises à jour, et si macOS
  refuse un jour ce groupe, seul le masquage tombe. À confirmer par Maxime. Premier
  essai du lot : cet exécutable, dans le bundle installé, lancé par l'app.
- **Quand on éteint et quand on rallume (§3.3)** : le classement s'applique. Une
  app classée cachée est éteinte quand le module est actif et que son entrée
  existe : au lancement de Multitool, à l'activation du module, au changement
  d'une case, au lancement de l'app (`didLaunchApplication`, puis 2 s). Elle est
  rallumée quand sa case est décochée ou le module désactivé. **Multitool ne
  rallume rien en quittant** ni pendant une mise à jour : les icônes ne
  clignotent pas à chaque login. À confirmer par Maxime.
- **Journal** : il dit « Multitool est responsable de cette extinction ». Écrit et
  synchronisé avant d'éteindre, il ne bouge pas pendant un relais. Une app en sort
  quand son entrée est relue allumée après une demande de rallumage. Entrée
  disparue : l'app reste au journal jusqu'à ce que son entrée revienne.
- **La barre fait foi, restreint (§3.4)** : seulement pour un passage éteint →
  allumé observé en direct, module actif, hors relais, plus de 5 s après la
  dernière écriture de Multitool. Jamais au lancement.
- **Multitool lui-même** n'est pas classable : l'éteindre retirerait le chevron.
  `showPopover(anchoredAt:)` est retiré.
- **Écritures par lot** : 1 seul cycle lire, modifier, écrire pour plusieurs apps.
  La relecture compare aussi les autres entrées à la lecture d'avant.
- **Reprise depuis 0.4.x** :
  - migration des choix vers le `bundleID` depuis `status:<bundleID>::…` et
    `app:<bundleID>#<index>`. Deux icônes d'une même app classées différemment :
    le plus caché gagne. Les choix `module:…` (icônes système) et ceux sans
    `bundleID` sont abandonnés ;
  - les icônes système cachées en 0.4.x redeviennent visibles, sans recours dans
    Multitool. À dire dans les notes de version ;
  - le chevron revient à 24 pt : si la barre déborde encore, macOS évince des
    icônes, accessibles par son indicateur `»` ou le ⌥-clic. La bande ne les
    montre plus ;
  - « Restaurer la disposition d'origine » reste tant que la sauvegarde du lot 4
    existe, avec le minimum de `MenuBarLayoutStore` pour l'écrire. Le reste du
    rangement est retiré.
- **Relais (§3.5)** : cadre relu à chaque essai, 1,5 s au plus. Recacher : par
  comparaison avec les fenêtres de l'app relevées avant le clic, jamais tant
  qu'une fenêtre nouvelle de niveau supérieur à 0 est à l'écran, pas de plafond
  de 60 s. Un relais en cours bloque toute extinction jusqu'à sa pression.
  Série J tranche si le clic simulé suffit pour toutes les icônes (l'icône est
  réellement à l'écran), ce qui retirerait `AXPress`.
- **Non mesuré, à voir en série J** : barre masquée automatiquement, plein écran,
  icône rallumée mais évincée faute de place. Le relais y échoue proprement.
- **Retirés** : la copie du blob d'origine (la restaurer écraserait la liste
  courante), le build de secours.

## 7. Écarts retenus pendant le code, et série J (24/11)

- Clic relayé : clic simulé pour toutes les icônes, sans `AXPress`. L'icône est
  réellement dans la barre, le clic simulé est le plus proche d'un vrai clic.
- Échec d'un relais : un bip et une ligne de journal, pas de badge (la bande est
  déjà fermée).
- Un relais est abandonné au bout de 10 min si l'app garde une fenêtre flottante.
- Les lignes de la page sont triées par nom, pas par position dans la barre.
- Série J, sur le MacBook d'essai : reprise des 7 choix de la 0.4, 6 icônes
  éteintes sans vide (Teleport Connect n'était pas lancé), bande alignée sous le
  chevron de 24 pt, OneDrive rallumée et dessinée en 230 ms, popover ouvert sous
  l'icône, recachée moins de 0,5 s après sa fermeture, case décochée puis recochée,
  module désactivé (tout revient, journal vidé) puis réactivé, arrêt brutal puis
  relance (rien ne bouge, journal intact). Non essayé : une icône à menu.
