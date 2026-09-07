Wallhaven Rotator 1.2.0
=========================

Wallhaven Rotator change automatiquement le fond d'écran Windows à partir de
l'API publique SFW de Wallhaven.

Fonctions principales
---------------------
- Tendance / Populaires / Nouveaux / Aléatoire
- Général / Anime / Personnes / Toutes
- requête Wallhaven personnalisée optionnelle
- filtrage Standard / Reduced / Strict (Content Filter Policy v5)
- filtre résolution + ratio : automatique ou personnalisé
- intervalle Minutes / Heures / Jours
- changement manuel et pause / reprise
- systray
- historique partagé avec le Screensaver, incluant l'heure d'affichage
- aucun ID déjà affiché aujourd'hui n'est volontairement réutilisé
- historique roulant d'au moins 5 000 anciens IDs
- cache borné à 50 images ET 500 MiB
- logs avec rotation et rétention 7 jours
- vérification des mises à jour GitHub Releases
- mise à jour automatique optionnelle avec vérification SHA-256 obligatoire
- autostart utilisateur, sans service Windows
- aucun droit administrateur requis

Filtrage de contenu
-------------------
Wallhaven est toujours interrogé avec purity=100.

Standard :
- SFW Wallhaven uniquement.

Reduced :
- ajoute une inspection locale des tags/métadonnées Wallhaven pour écarter
  les signaux adultes/suggestifs forts.

Strict :
- mode volontairement conservateur basé sur Content Filter Policy v5 ;
- hard blocks, sujets féminins, Anime/People ambigus fail-closed et score de risque.

Ce mécanisme analyse les métadonnées Wallhaven, pas les pixels de l'image.

Historique / anti-répétition
----------------------------
Historique partagé :
%LOCALAPPDATA%\WallhavenShared\history.json

Les IDs affichés avec succès aujourd'hui sont une exclusion absolue. Les échecs
de téléchargement ou d'application ne consomment pas l'ID. Le cache d'images
et l'historique sont indépendants.

Cache
-----
%LOCALAPPDATA%\WallhavenWallpaperRotator\cache

Limites :
- 50 fichiers maximum
- 500 MiB maximum

Réseau / vie privée
-------------------
L'application contacte Wallhaven pour rechercher/télécharger les fonds et,
en Reduced/Strict, pour consulter les métadonnées d'un wallpaper. Elle contacte
GitHub Releases pour les mises à jour. Aucun endpoint analytique propre au projet.

Projet : https://github.com/tadikwa/Wallhaven-Rotator

Mises à jour
------------
Le programme consulte périodiquement la dernière GitHub Release.

L'installation automatique est optionnelle. Avant exécution, le programme exige
le setup canonique WallhavenRotator-Setup-vX.Y.Z.exe, récupère SHA256SUMS.txt et
vérifie que le SHA-256 du fichier téléchargé correspond exactement au checksum.

En cas d'asset absent, checksum absent ou hash incorrect, le setup n'est pas
exécuté automatiquement. Les réglages, l'historique, le cache, les logs et la
préférence d'autostart sont conservés.
