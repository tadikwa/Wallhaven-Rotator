Wallhaven Rotator 1.2.1
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

Les tags/catégories Wallhaven sont conservés séparément dans
%LOCALAPPDATA%\WallhavenWallpaperRotator\metadata-cache.json
(1 200 entrées maximum, validité 7 jours, remplacement atomique).
Chaque utilisation réévalue le filtre actif ; le cache ne mémorise pas un verdict.
Un changement utilise au maximum 2 recherches et 6 vérifications réseau,
recyclage compris. Une image affichée aujourd'hui reste interdite. Un quota
technique n'est pas un refus Strict.

En cas d'indisponibilité de Wallhaven, les images déjà téléchargées et validées
peuvent être réutilisées avec les mêmes réglages de recherche, taille, ratio et
filtrage. Les fichiers invalides sont ignorés. Sans candidat local admissible,
le fond actuel reste affiché. Les erreurs 429 suspendent les recherches pendant
au moins 15 minutes, ou davantage selon Retry-After ; un clic manuel respecte
aussi cette pause, qui est persistée et survit au redémarrage.
Aucun historique ni réglage n'est effacé.

Les recherches et métadonnées passent par le même registre atomique :
%LOCALAPPDATA%\WallhavenShared\api-budget.json
Plafonds sur une fenêtre glissante de 60 secondes : 24 appels pour les clients
coopérants, dont 12 au maximum pour le Rotator, avec 2,6 secondes d'espacement.
Un registre illisible ou impossible à écrire interdit de nouveaux appels API.
Les attentes utilisent le timer d'interface ; une sélection dépassant 45 secondes
est annulée, sans annuler les vérifications de mise à jour GitHub.

Le Rotator privilégie les images locales qualifiées, puis les candidats connus.
Les réponses de recherche sont conservées 15 minutes (16 réponses maximum)
dans search-cache.json, sans remplacement de l'inspection Strict des tags.
Les IDs et recherches sont dédupliqués par cycle ; un même ID ne reçoit pas
deux appels de métadonnées dans une fenêtre de 60 secondes. Les diagnostics
sont regroupés dans une ligne selection.summary par sélection.

Le Screensaver actuel possède son propre plafond de 30 appels/minute. Il doit
adopter le registre commun pour une coordination effective ; le Rotator seul
ne peut pas compter les appels d'un autre logiciel ou d'autres machines derrière
la même adresse IP. Son plafond propre de 12 laisse une marge sous 45 lorsque
le seul autre client émet au maximum 30 appels/minute.

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
