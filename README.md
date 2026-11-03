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
- **Formules utilisées** : si une formule tourne, ses anciennes versions restent sur
  disque, y compris lors des nettoyages. Les services mis à jour sont redémarrés.
- **Vérification automatique** : `brew update` à intervalle réglable. Elle est mise en
  pause hors ligne, relancée au retour du réseau et après une mise en veille, puis
  retentée 15 min après un échec. Délai maximal : 5 min pour `brew update`.
- **Mise à jour automatique** (option) : ce qui n'est pas utilisé, ignoré, épinglé ni
  protégé par le mot de passe administrateur se met à jour seul.
- **Barre des menus** : icône avec le nombre de mises à jour. Un clic ouvre le menu
  (mises à jour rapides, vérification, réglages), un double-clic ouvre la fenêtre.
  Badge dans le Dock et notification des nouvelles versions en option.
- **Installés** : liste des paquets avec leur taille, fiche détaillée, désinstallation
  (avec `--zap` en option pour les casks).
- **Rechercher / installer** : recherche par nom et par description, triée par
  pertinence puis par ordre alphabétique. La fiche détaillée donne la version, le site,
  les dépendances et les avertissements, et explique pourquoi un paquet est déprécié ou
  désactivé dans Homebrew (et par quoi le remplacer). Installation en un clic.
- **Ignorer** un paquet : il est exclu des mises à jour groupées (clic droit).
- **Entretien** : `brew cleanup` tous les 7 jours, en tâche de fond, sans réglage. Menu
  Brew : nettoyage, `brew autoremove` et diagnostic `brew doctor`.
- **Mot de passe administrateur** : les apps qui en ont besoin (installées par `.pkg`)
  ne sont jamais mises à jour automatiquement. Le mot de passe est demandé au moment du
  clic, puis oublié à la fin de l'opération.
- **Journal** : sortie en direct de chaque commande brew. En cas d'échec, un bandeau
  mène au journal.
- **Langue** : français ou anglais, selon la langue du système.

Les opérations qui modifient brew passent par une file : une à la fois, dans l'ordre.
« Arrêter » (⌘.) interrompt l'opération en cours et vide la file.

### Léger en tâche de fond

- Les commandes lancées en fond tournent en priorité basse (`taskpolicy`), et brew ne
  télécharge qu'un fichier à la fois.
- Si l'image disque d'une app est occupée pendant sa mise à jour, Brasseur réessaie une
  fois 20 s plus tard.
- Un partage réseau qui ne répond plus bloque les recherches Spotlight, et donc brew.
  Après 10 s, Brasseur arrête la recherche bloquée et indique les partages en cause.

## Installer

Télécharger `Brasseur-<version>.zip` depuis les
[Releases](https://github.com/dorianbayart/brasseur/releases), le décompresser et placer
`Brasseur.app` dans `~/Applications` ou `/Applications`. Il faut macOS 15 ou plus, sur
un Mac Apple silicon.

L'app n'est pas signée par un compte développeur Apple : au premier lancement, macOS la
bloque. Pour l'autoriser, ouvrir Réglages Système › Confidentialité et sécurité ›
« Ouvrir quand même », ou retirer la quarantaine :

```sh
xattr -dr com.apple.quarantine ~/Applications/Brasseur.app
```

## Construire

Seuls les Command Line Tools sont nécessaires (pas Xcode). Il faut macOS 15 ou plus.

```sh
./scripts/build.sh           # construit build/Brasseur.app
./scripts/build.sh install   # copie dans ~/Applications et relance
```

Diagnostic sans interface : `~/Applications/Brasseur.app/Contents/MacOS/Brasseur --selftest`.

## Publier une version

Pousser un tag `v*` : la CI GitHub construit l'app et publie une release avec le zip.

```sh
git tag v1.0.1 && git push origin v1.0.1
```

La CI ne garde que les 3 dernières releases (les tags restent). Elle ne conserve aucun
artefact ni cache GitHub Actions, pour ne pas remplir le quota de stockage. Lancée à la
main (onglet Actions), elle vérifie seulement que l'app se construit.
