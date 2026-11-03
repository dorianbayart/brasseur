# Brasseur

Interface graphique macOS pour Homebrew. L'app reste dans la barre des menus avec le
nombre de mises à jour en attente, et ne casse plus les apps ouvertes.

## Fonctions

- **Mises à jour** : liste des paquets en retard (apps d'abord, puis formules, puis
  dépendances). On peut mettre à jour un paquet, la sélection, tout, ou **tout sauf les
  paquets utilisés**.
- **Détection d'utilisation** : un paquet est « utilisé » si l'un de ses exécutables
  tourne (chemin réel sous `Cellar/`, `Caskroom/` ou dans son `.app`) ou si son service
  brew est démarré.
- **Apps ouvertes** : avant de mettre à jour un cask ouvert, Brasseur ferme l'app
  proprement puis la relance. On peut aussi désactiver ce comportement pour laisser les
  apps ouvertes de côté.
- **Formules utilisées** : si une formule tourne, les anciennes versions restent sur
  disque (`HOMEBREW_NO_INSTALL_CLEANUP`) ; on les supprime plus tard avec « Nettoyer ».
  Les services mis à jour sont redémarrés.
- **Vérification automatique** : `brew update` à intervalle réglable. Elle est mise en
  pause hors ligne, relancée au retour du réseau et après une mise en veille, puis
  retentée 15 min après un échec. Délai maximal : 5 min pour `brew update`.
- **Barre des menus et Dock** : badge du nombre de mises à jour, mises à jour rapides
  depuis le menu, notification optionnelle des nouvelles versions.
- **Rechercher / installer / désinstaller** : `brew search --desc`, fiche détaillée
  (version, site, dépendances, avertissements), installation en un clic. Désinstallation
  avec `--zap` en option pour les casks.
- **Ignorer** un paquet : il est exclu des mises à jour groupées (clic droit).
- **Entretien** : `brew cleanup`, `brew autoremove` (menu Brew).
- **Mot de passe administrateur** : les casks installés par `.pkg` le demandent dans une
  boîte de dialogue macOS (`SUDO_ASKPASS`).
- **Journal** : sortie en direct de chaque commande brew.

Les opérations qui modifient brew passent par une file : une à la fois, dans l'ordre.
« Arrêter » (⌘.) interrompt l'opération en cours et vide la file.

## Construire

Seuls les Command Line Tools sont nécessaires (pas Xcode). Il faut macOS 15 ou plus.

```sh
./scripts/build.sh           # construit build/Brasseur.app
./scripts/build.sh install   # copie dans ~/Applications et relance
```

Diagnostic sans interface : `~/Applications/Brasseur.app/Contents/MacOS/Brasseur --selftest`.
