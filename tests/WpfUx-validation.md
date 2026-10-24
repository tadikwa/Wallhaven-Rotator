# Validation WPF / UX — 24 octobre 2026

Base : fe614dd, branche fix/wpf-responsive-selection, livraison empilée sur PR #10.

## Diagnostic et mesures réelles

Le timer Dispatcher appelait le moteur complet : historique, filtre Strict,
GDI/image, écriture/normalisation et nettoyage du cache. Le caractère asynchrone
de HttpClient ne déplaçait pas ces opérations hors du thread WPF.
Get-SharedHistorySnapshot réécrivait aussi systématiquement le fichier sous mutex.
Les 6 782 ms indiquées par l'utilisateur n'ont pas été reproduites sur son bureau.

Mesures Stopwatch locales PowerShell 5.1, fixtures isolées dans le même environnement de test :

| Mesure | Base fe614dd | Correctif |
|---|---:|---:|
| 5 lectures de 5 000 entrées : réécritures | 5 | 0 |
| Même test : normalisations | 5 | 0 |
| Médiane des lectures | 309,0 ms | 91,5 ms au premier passage ; 104,7 ms lors de la suite complète |
| Sélection locale avec historique 5 000 | 1 724,5 ms, thread appelant | 1 140,9 ms, worker initialisé à la demande ; 796,2 ms au changement suivant |
| Retour de la demande côté UI | sélection complète synchrone ci-dessus | 20,4 ms |

Les deux dernières lignes sont des observations ponctuelles, pas des médianes
ni un engagement de latence. Deux fichiers JPEG 5120×1440 et le moteur réel
sont utilisés ; seul l'appel Windows appliquant réellement le fond est remplacé.
Les tests ne touchent aucun fond ni historique utilisateur. Zéro appel API pour
les deux sélections locales, y compris après 100 clics manuels regroupés.

Le test de réactivité possède un véritable Dispatcher WPF : 37 ticks ont été
traités pendant un worker retardé volontairement de 400 ms, sur un autre thread.
Cela prouve la séparation du travail, pas la fluidité du bureau physique pendant
SystemParametersInfo. Les journaux ajoutent selection.worker (temps réel/thread),
real_elapsed_ms/history_reads au bilan et ui.tick lorsqu'un tick dépasse 50 ms.

## Correctif et invariants

- Lectures sans normalisation/réécriture ; migrations toujours persistées une fois.
  Réservations et commits restent sous mutex et relisent l'état autoritaire.
- Une vue de l'historique par sélection, invalidée au changement de jour ; aucun
  cache ne remplace le contrôle quotidien lors de la réservation.
- Runspace STA dédié réutilisé, HTTP et état propres. Entrées copiées, annulation
  coopérative et progression par queue ; aucune référence WPF dans le worker.
- Un seul travail actif, clics regroupés, annulation lors de sauvegarde des
  réglages. Quitter et OTA attendent le nettoyage avant de libérer le mutex.
- Budget API et 429 conservés, y compris un 429 déjà reçu avant annulation.
  Le nouveau client utilise compression et proxy par défaut, sans transmission
  ajoutée des identifiants Windows au proxy.
- Options à droite ; repli vertical mesuré selon la hauteur réelle des commandes.
  Deux zones défilantes, commandes de rotation/enregistrement dans un pied fixe.
  Calcul sur le moniteur du HWND, zone de travail et DPI effectif, coordonnées
  physiques pour le placement, prise en compte des notifications d'écran/DPI.
- Fenêtre visible ownerless APPWINDOW sans TOOLWINDOW, ICO WPF ; fermeture masque,
  double-clic systray restaure, Quitter dispose worker/HTTP/icône/menu/mutex.

## Vérifications

Les 13 suites PowerShell 5.1 couvrent les huit suites antérieures et :
HistoryPerformance, SelectionWorker, DesktopSelection, WindowGeometry,
WindowLifecycle. UpdateHelpers exécute aussi le hand-off OTA sans lancer d'EXE.
Le correctif OTA a été vérifié rouge puis vert après la revue indépendante.

- Géométrie pure : 48 cas combinant 5120×1440, 1920×1080 et 1366×768,
  DPI 96/120/144/192, options masquées/ouvertes, origines négatives et barre des tâches.
- Véritable XAML WPF/HWND : icône, propriétaire/styles Win32, visibilité,
  fermeture/masquage/restauration et fermeture finale. Arrangements WPF réels aux
  12 combinaisons résolution/DPI simulées, viewports d'au moins 24 DIPs.
- Moteur dans le runspace : cache chaud, historique saturé, clics regroupés,
  commit Screensaver concurrent avant réservation, 429 puis clics sans nouvel API.
- Charges réseau antérieures : mêmes résultats, plafonds observés de 12/60 s
  pour les rafales et 3/60 s pour les rotations automatiques simulées.
- Go 1.23.2, go vet et build exécutés ; le helper Desktop est inclus dans
  la liste installée et le payload embarqué. Aucun installateur exécuté.

## STOP_GATE interactif

Une fixture de l'application complète a été lancée avec données/identité isolées,
réseau et application du fond désactivés. Son HWND actif a été constaté, mais
les outils Computer Use ne renvoient pas cette fenêtre dans leur inventaire,
y compris après lancement hors sandbox. Aucun HWND inventé n'a été utilisé pour
contourner cet accès. Les deux processus de fixture ont été fermés après essai.

Donc NON validés visuellement : bouton/icône réellement affichés dans la barre des
tâches, présence dans Alt+Tab, double-clic systray, déplacement entre moniteurs de
DPI différents, et disparition du gel avec le véritable appel natif sur le bureau.
Les résolutions/DPI ci-dessus sont simulés dans les tests, pas imposés au poste.

Pour poursuivre manuellement : exécuter tests/Start-IsolatedDesktop.ps1 -Wait.
La fixture conserve ses logs sous .test-tmp/desktop-preview-*. Ne pas confondre
son application du fond factice avec un essai fonctionnel de rotation réelle.

Une validation Windows 10/11 interactive reste nécessaire avant diffusion.
La coordination réseau du Screensaver non coopérant reste la limite documentée
de PR #10 ; aucun second dépôt ni donnée utilisateur n'a été modifié. Un proxy
exigeant l'authentification Windows intégrée reste aussi à vérifier.
