Wallhaven Rotator 1.1.0
=========================

Wallhaven Rotator change automatiquement le fond d'écran Windows à partir de
l'API publique SFW de Wallhaven.

Fonctions principales
---------------------
- Tendance / Populaires / Nouveaux / Aléatoire
- Général / Anime / Personnes / Toutes
- filtre résolution + ratio : automatique (écran principal) ou personnalisé
  avec correspondance « Au moins » / « Exacte » et ratio automatique ou explicite
- intervalle Minutes / Heures / Jours
- changement manuel et pause / reprise
- systray
- historique persistant de 1 000 IDs
- cache borné à 50 images ET 500 MiB
- sélection multi-pages pour améliorer la variété
- logs avec rotation et rétention 7 jours
- vérification des mises à jour GitHub Releases
- mise à jour silencieuse optionnelle uniquement pour les setups signés et vérifiés
- autostart utilisateur, sans service Windows
- aucun droit administrateur requis

Variété / anti-répétition
-------------------------
- Tendance : pages 1 à 20
- Populaires : pages 1 à 60
- Nouveaux : pages 1 à 100
- Aléatoire : randomisation native Wallhaven
- jusqu'à 4 pages testées lorsqu'une page ne contient que des éléments récents
- les 200 derniers IDs restent protégés même si l'historique complet est saturé

Cache
-----
Le cache se trouve dans :
%LOCALAPPDATA%\WallhavenWallpaperRotator\cache

Limites :
- 50 fichiers maximum
- 500 MiB maximum

Une image encore présente en cache est réutilisée sans être téléchargée à
nouveau. Les plus anciennes sont supprimées lorsque l'une des deux limites est
dépassée.

Historique
----------
%LOCALAPPDATA%\WallhavenWallpaperRotator\history.json

Les 1 000 derniers IDs sont mémorisés et survivent aux redémarrages.

Réseau / vie privée
-------------------
L'application contacte Wallhaven pour rechercher et télécharger les fonds.
Aucune télémétrie propre au projet, aucun compte et aucun endpoint analytique.

Projet : https://github.com/tadikwa/Wallhaven-Rotator

Affichage / ratios
------------------
Le mode Automatique détecte la résolution de l'écran principal et choisit le
ratio Wallhaven le plus proche (16:9, 16:10, 21:9, 32:9, 48:9, 4:3, 5:4, etc.).
Le mode Personnalisé permet de saisir une largeur et une hauteur cibles, de
choisir « Au moins » (Wallhaven `atleast`) ou « Exacte » (`resolutions`), puis
de laisser le ratio être dérivé automatiquement ou de choisir explicitement
16:9, 16:10, 21:9, 32:9, 48:9, 4:3, 5:4, 3:2, 1:1 ou un ratio portrait.

Mises à jour
------------
Le programme consulte périodiquement la dernière GitHub Release. Une mise à
jour est signalée dans l'interface et via la zone de notification. L'installation
automatique n'est autorisée que si le setup signé est disponible, que son
SHA-256 correspond au fichier publié, que sa signature Authenticode est valide
et que l'éditeur du certificat est SignPath Foundation. Les réglages,
l'historique, le cache, les logs et la préférence d'autostart sont conservés.
