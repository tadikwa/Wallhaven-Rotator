# Setup Win32 : reactivite et diagnostic

Base : `ece4f9d`, branche `fix/wpf-responsive-selection`, PR #11. Version 1.2.0.

## Faits reproduits et inconnues

Le gestionnaire WM_COMMAND appelait install/uninstall directement sur le thread
de fenetre. Les lectures COM, copies/verifications, notification Shell, registre,
marqueur et ShellExecuteW monopolisaient donc la boucle de messages.
La boucle Win32 ne fixait pas non plus sa goroutine a un thread OS.

Dans la reproduction instrumentee, toutes les phases portaient le meme thread
que les notifications UI. Une installation sans ralentissement ajoute a pris
153 ms dans le coeur (173 ms observes cote sonde) et a manque une reponse
WM_NULL bornee a 100 ms. La reinstallation suivante a pris environ 65 ms cote
sonde et n'a pas manque de reponse. Les mesures sont ponctuelles, sur cette machine.

Le gel prolonge rapporte sur le poste utilisateur n'a pas ete reproduit.
L'appel responsable de ce delai precis reste inconnu : je ne sais pas lequel
est reste bloque lors de cet essai. Aucune instance de l'installateur signale
n'etait encore observable lors de la verification des processus en lecture seule.
Sur la fixture sans delai : validation COM environ 3-20 ms, sauvegarde du lien
3-38 ms, notification Shell environ 1 ms, ancien appel ShellExecute 15-37 ms.
Ces observations ne prouvent pas que COM ou le Shell causaient le gel prolonge.

Un delai controle de 1 500 ms dans la sauvegarde COM ou le lancement WSH a
reproduit le defaut structurel. Exemple WSH avant correction : 13 puis 12
reponses WM_NULL a 100 ms manquees, sur des operations d'environ 1 627/1 578 ms.
Apres deplacement sur le worker, le premier passage au meme seuil de 100 ms
est vert : 81-84 reponses traitees pendant ces operations, aucune manquee.

## Correctif

- Thread UI fixe pendant creation/destruction du HWND et boucle de messages.
- Installation et desinstallation dans un worker sur thread OS fixe, initialise
  COM STA. CoUninitialize et UnlockOSThread precedents a la publication du resultat.
- Progressions/resultat copies dans un canal Go, notification WM_APP et timer
  de secours. Les controles, peintures et boites de dialogue restent sur l'UI.
- Etat busy maintenu jusqu'au retour final, commandes en double ignorees.
  Fermer/croix demandent une fermeture differee, sans abandonner les ecritures.
- Mutex natif par installation pour les operations GUI, CLI et OTA. Refus
  immediat d'une operation concurrente ; liberation sur le thread proprietaire.
- Lanceur VBS officiel inchange. wscript.exe est lance directement, sans delegation
  ShellExecute ; le setup attend le code de sortie de WSH, au plus 15 secondes.
  Echec ou delai depasse est une erreur, jamais un message de reussite.
- Les erreurs de suppression de la valeur Run sont maintenant propagees.
  Le message final ne pretend plus que l'autostart est toujours active.
- Journaux, y compris OTA, hors du dossier installe. Regression reproduite rouge
  puis verte : un updater refuse ne recree plus app/logs apres desinstallation.

## Diagnostic livre

`%TEMP%\WallhavenRotator-Setup-<PID>.log` contient les phases debut/fin,
identifiants de thread, durees et erreurs. Le chemin est affiche en cas d'erreur.
Phases : worker STA, validation du lien, repertoires, ancien contenu, chaque fichier
payload, settings, sauvegarde COM, notification Shell, registre, install.json,
lancement WSH, suppression payload/lien et fin d'operation. Un debut sans fin
permet de localiser l'attente sur le prochain essai reel.

## Validation automatisee

Les tests GUI executent les fonctions et le vrai HWND du setup dans un sous-processus
de tests. Copies, verifications, marqueur, lien COM et notification Shell sont reels.
APPDATA/LOCALAPPDATA sont des dossiers temporaires ; les operations Run sont capturees
dans un fichier factice pour ne pas toucher HKCU. Le VBS officiel lance un script
PowerShell de sonde ; le parent attend sa preuve `probe/started.txt`.
Ce protocole ne constitue pas une installation du binaire dans le profil habituel.

La suite finale sonde WM_NULL avec une borne de 250 ms pour supporter la variabilite
des runners ; le passage rouge/vert initial a aussi ete execute avec la borne 100 ms.
Les douze mesures locales finales figurent dans `dist/setup-ui-metrics.json`.
Observation locale : aucune reponse manquee ; plus grande reponse mesuree environ
0,55 ms (precision de l'horloge locale). Avec retard COM/WSH, 81-84 reponses durant
une operation ; desinstallation retardee de 1 500 ms : 74 reponses, aucune manquee.
Il ne s'agit ni d'une garantie de latence ni de mesures du poste utilisateur.

Tests : installation/reinstallation/desinstallation, ralentissements COM/WSH/suppression,
verification du STA et du thread des notifications, doubles commandes, fermeture
differee, erreur COM injectee puis reprise, conflit STA/MTA reel sans desequilibrage,
WSH exit 7/fichier manquant/expiration, echec registre sans suppression des fichiers,
mutex concurrent/liberation et updater refuse sans recreation de dossier.
Tous les anciens tests du raccourci restent actifs. Mesures GUI ajoutees a l'artefact CI.

Les 13 suites PowerShell 5.1, Go, vet du depot et deux builds Windows ont ete executes.
Les resultats CI, le commit final et le SHA-256 livre sont references dans la PR #11.
`src/` et VERSION restent identiques a ece4f9d : WPF, moteur, Strict 32:9, quotas,
historique et VBS ne sont pas modifies.

## Limites et STOP_GATE

Le succes WSH confirme le retour du lanceur, pas la fin du demarrage WPF du produit.
Le message dit seulement que la demande d'ouverture a ete transmise. Le demarrage
WPF isole et la restauration de la meme instance ont leur test distinct conserve.
L'autostart reel du profil cible et le scenario initial prolonge restent a revalider
sur Windows 11 avec les nouveaux journaux. Le registre reel n'a pas ete modifie.

WSH est borne ; les appels natifs COM et fichiers ne sont pas interrompus brutalement.
La fenetre continue de traiter ses messages pendant leur attente ; la fermeture
attend leur retour pour proteger l'installation et les ressources COM.

Aucune fusion, release ou installation/desinstallation dans le profil utilisateur
reel. Aucune suppression de donnees existantes ni modification du moteur applicatif.
