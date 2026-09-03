Wallhaven Rotator 1.0.0
=========================

Wallhaven Rotator change automatiquement le fond d'écran Windows à partir de
l'API publique SFW de Wallhaven.

Fonctions principales
---------------------
- Tendance / Populaires / Nouveaux / Aléatoire
- Général / Anime / Personnes / Toutes
- filtre automatique sur la résolution de l'écran
- intervalle Minutes / Heures / Jours
- changement manuel et pause / reprise
- systray
- historique persistant de 1 000 IDs
- cache borné à 50 images ET 500 MiB
- sélection multi-pages pour améliorer la variété
- logs avec rotation et rétention 7 jours
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
