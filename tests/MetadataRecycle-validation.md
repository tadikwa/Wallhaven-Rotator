# Validation du correctif de sélection

Note historique : ce document décrit la validation du commit 635fa28. Le budget
par phase a depuis été remplacé par un budget global persistant. Voir
[NetworkBudget-results.md](NetworkBudget-results.md) pour le correctif actuel.

## Cause de l'échec initial de CI

Le job du run 39918172243 (workflow Build #36, PR #10, commit 89aecc8)
échouait à la ligne 126 de MetadataRecycle.Tests.ps1. Reproduit le 23 octobre
2026 avec Windows PowerShell 5.1 : le script de test UTF-8 sans BOM était lu
avec l'encodage ANSI. Le texte accentué de l'assertion ne correspondait plus
au motif renvoyé par le runtime, qui possède un BOM. L'ajout du seul BOM au
test, sans modification des assertions, a fait passer ce scénario.

## Défauts supplémentaires reproduits avant correction

- Le premier candidat inconnu au quota empêchait d'atteindre un candidat
  déjà validé dans la même page. Le reste de cette page est maintenant
  examiné sans réservation des inconnus ; le cycle reste borné.
- Les refus Strict déjà en cache réservaient/libéraient inutilement un ID,
  entraînant des réécritures de l'historique partagé.
- Une demande manuelle pouvait court-circuiter la pause 429. Le délai est
  désormais contrôlé à l'entrée et prend en compte Retry-After de l'API.
- Une erreur réseau de métadonnées était diagnostiquée comme un refus Strict.
- Des métadonnées incomplètes ou de mauvais types pouvaient être acceptées.
- La sauvegarde du cache écrasait directement le fichier. Elle emploie
  désormais un remplacement atomique, sous le mutex mono-instance existant,
  et conserve l'état sale si l'écriture échoue.
- Les réglages pouvaient changer pendant les tâches asynchrones. Leur clé
  est capturée à la recherche et contrôlée avant le téléchargement/application.

## Couverture automatisée

Exécuter chaque fichier tests/*.Tests.ps1 avec powershell.exe -NoProfile
-ExecutionPolicy Bypass -File. Les fixtures utilisent un répertoire temporaire,
un mutex et des chemins d'historique isolés ; aucune donnée utilisateur n'est lue.

SelectionEngine.Tests.ps1 exerce les fonctions réelles de sélection,
persistance, historique partagé, recyclage et traitement asynchrone. Seuls
HTTP, l'application native du fond et les composants d'interface sont remplacés.
Ses 21 scénarios couvrent notamment :

- quota épuisé, cache après un inconnu, transition après 16 requêtes réelles
  au transport factice puis application d'un candidat recyclé connu ;
- historiques de 0, 3 et 5 000 entrées, trois rotations et exclusions du jour ;
- cache absent, valide, expiré, corrompu, borné, sauvegarde défaillante puis reprise ;
- mêmes IDs, Strict accepté/refusé, changement de filtre et de requête en vol ;
- erreurs réseau, 429, Retry-After secondes/date, pause manuelle, reprise ;
- téléchargements échoués et libération des réservations ;
- redémarrage simulé par rechargement disque, rotation hors ligne, image corrompue ;
- requêtes 5120x1440/32:9 exactes et fallback de taille conservant le ratio.

Les autres suites couvrent l'initialisation d'historique, la politique de
contenu, les réservations partagées, les ratios et les helpers de mise à jour.
Le build existant rafraîchit le payload depuis src avant compilation Go.

## Limites de preuve

Ces tests n'ouvrent pas l'interface WPF et n'appliquent aucun fond au bureau.
Ils ne constituent pas une mesure de fluidité, un test de plusieurs heures
sur le moniteur 5120x1440, ni un test physique Rotator/Screensaver simultanés.
L'API Wallhaven est remplacée : les branches de transport et les délais sont
testés, pas la disponibilité du service externe.

Le secours hors ligne exige une image déjà téléchargée avec ces réglages et
des métadonnées encore valides. Si ces candidats sont épuisés pour aujourd'hui,
le fond actuel est conservé pour respecter l'interdiction de répétition.
La pause 429 est en mémoire ; un redémarrage peut effectuer une nouvelle
requête, qui appliquera de nouveau le délai si le serveur reste limité.

Avant une nouvelle release : vérifier plusieurs rotations sur le vrai bureau
5120x1440 en Strict, la réactivité de l'interface, un redémarrage et le partage
de l'historique avec le Screensaver. Aucun déploiement, fusion ou release n'est
effectué par cette validation.
