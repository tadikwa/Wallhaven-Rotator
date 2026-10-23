# Régulation API — validation du 24 octobre 2026

## Cause et politique

Le commit 635fa28 bornait chaque phase, mais pas les appels cumulés par minute.
Chaque nouvelle rotation relançait une recherche ; le recyclage renouvelait
le budget de métadonnées. Les clics successifs et un redémarrage pouvaient
multiplier ces allocations. Le cooldown 429 était seulement en mémoire.

Le correctif remplace cela par un registre séparé de l'historique, écrit avant
chaque appel, sous mutex, par remplacement atomique :

- API partagée : 24 appels maximum sur toute fenêtre glissante de 60 secondes ;
- part Rotator : 12 appels maximum, espacement minimal global de 2,6 secondes ;
- par changement : 2 recherches et 6 métadonnées maximum, recyclage compris ;
- échéance 45 secondes contrôlée aussi pour les tâches en vol ; annulation
  propre à la sélection, sans interruption des mises à jour GitHub ;
- 429/Retry-After persisté, y compris une réponse terminée après l'échéance ;
- cache local qualifié prioritaire, puis découvertes de recherches gardées
  15 minutes, maximum 16 réponses, isolées par tous les réglages de sélection ;
- refus Strict et IDs dédupliqués sans nouvelles réservations inutiles ;
- bilan de sélection unique : appels réellement émis, cache, rejets, durée,
  au maximum trois IDs d'exemple. Aucun quota ne valide une image inconnue.

Une défaillance du registre bloque les nouveaux appels API ; le cache local
reste utilisable. Aucun réglage ni historique utilisateur n'est réinitialisé.

## Mesures comparables avant/après

Même harnais PowerShell 5.1, même faux serveur, même horloge virtuelle, réponses
immédiates, pas de véritable appel API. Référence : runtime extrait avec
`git show 635fa28:src/Wallhaven-Wallpaper-Tray.ps1`, avec son quota original de
16 métadonnées par phase. Nouveau runtime : quota total de 6. Le scénario froid
commence sans tags ni fichiers ; le chaud contient 24 images JPEG et des
métadonnées de fixture valides. Les sorties réelles du transport factice sont
comptées, jamais les seules intentions de log. Fenêtres inclusives de 60 secondes.

| Scénario | API avant → après | Pic/60s avant → après | Maximum/changement avant → après | Fonds avant/après |
|---|---:|---:|---:|---:|
| 20 changements manuels, froid | 40 → 21 | 40 → 12 | 2 → 2 | 20 / 20 |
| 20 changements manuels, chaud | 20 → 0 | 20 → 0 | 1 → 0 | 20 / 20 |
| 60 changements, un/minute, froid | 336 → 28 | 10 → 3 | 8 → 2 | 24 / 24 |
| 30 changements, un/minute, historique 5 000 | 192 → 26 | 10 → 3 | 8 → 2 | 24 / 24 |
| 20 demandes, uniquement des refus Strict | 181 → 25 | 181 → 12 | 29 → 7 | 0 / 0 |

Le pool du faux serveur contient seulement 24 IDs fixes. Après leur affichage
le même jour, garder le fond courant est le résultat attendu ; les 36 demandes
automatiques suivantes ne doivent pas fabriquer des images supplémentaires.

Le premier changement froid demande 1 recherche + 1 métadonnée dans cette fixture
où tous les paysages sont acceptables. Les suivants réutilisent la recherche :
19 réutilisations sur les 20 demandes manuelles. À chaud, 100 % des qualifications
servies proviennent du cache et les 20 changements n'émettent aucun appel API.
L'indicateur de cache du nouveau moteur est hits positifs / (hits positifs +
appels de métadonnées) ; les refus négatifs réutilisés ne gonflent pas ce taux.

Temps virtuels médian/maximal des sélections après correction : froid manuel
2,5 / 31,4 s, chaud 0 / 0 s, automatique froid 0,1 / 2,9 s, historique saturé
0,2 / 2,9 s, tous refusés 0,1 / 44,5 s. Le froid manuel ralentit volontairement
par rapport aux 0,3 s simulées de la référence qui ne régulait aucun débit.
Ces valeurs incluent les créneaux imposés et le pas de simulation de 100 ms,
mais excluent latence Internet, temps CPU/disque et rendu WPF : elles ne sont
pas une prédiction de durée réelle sur le PC de l'utilisateur.

Les mesures réelles fournies par l'utilisateur (31 appels pour un fond après
le premier correctif, 46 sur 60 secondes, puis 429) motivent cette mission ;
les journaux correspondants n'ont pas été relus ici. Elles ne sont pas
interchangeables avec les simulations ci-dessus.

## Tests et preuves

- ApiBudget.Tests.ps1 : fenêtres glissantes, limites Rotator et partagée,
  deux clients, deux processus PowerShell réellement concurrents, redémarrage,
  recul d'horloge, corruption, persistance et expiration du cooldown.
- NetworkLoad.Tests.ps1 : les cinq scénarios, 200 clics pendant une tâche
  (coalescés), 100 clics après 429 et rechargement mémoire, reprise après délai,
  cache de recherche après rechargement/changement de requête/expiration/corruption,
  refus d'un candidat 16:9, quatre états expirés et 429 déjà reçu à l'échéance.
- SelectionEngine.Tests.ps1 conserve ses 21 scénarios, avec temps virtuel pour
  les attentes nouvelles. Les anciennes assertions de remise à zéro du budget
  sont remplacées par la conservation du budget total exigée par cette mission.
- Les résultats structurés sont générés dans dist/network-budget-results.json
  et joints à l'artefact CI. Pour la référence locale, passer -BaselineRuntime
  au même script avec le fichier extrait du commit 635fa28.

## Coordination Screensaver

Source consultée le 24/10/2026 :
[WallhavenClient.cs](https://github.com/tadikwa/Wallhaven-Screensaver/blob/main/src/WallhavenScreensaver/WallhavenClient.cs),
blob 4abf8c7ba87b91f69989a4088f486f7f7046525b. La branche main utilise une queue
statique en mémoire, maximum 30/minute. La version effectivement installée
sur le PC est inconnue. Aucun fichier de ce second dépôt n'est modifié.

Protocole disponible pour son intégration : même fichier
%LOCALAPPDATA%/WallhavenShared/api-budget.json, même mutex
Local\WallhavenSharedHistoryV2-ApiBudget ; schéma 1, notBefore ISO UTC,
requests [{at: ISO UTC, client: Rotator|Screensaver, key: URL|metadata:ID}].
Sous mutex, relire/pruner puis réserver sur disque avant chaque émission ;
fusionner tout Retry-After avec le maximum du cooldown déjà présent.
Get-WallhavenApiPermit et Set-WallhavenApiCooldown constituent l'implémentation
PowerShell de référence. Un port C# devra conserver l'écriture atomique et les
mêmes plafonds ; copier seulement le fichier ne coordonne pas les processus.

Tant qu'il n'adopte pas ce protocole, la borne commune 24 ne couvre pas le
Screensaver. La part Rotator 12 laisse une marge théorique : 12 + 30 = 42 < 45,
sous l'hypothèse d'un seul autre client réellement borné à 30. Aucune garantie
sur une adresse IP entière avec d'autres applications ou machines.

Limite officielle consultée : [Wallhaven, API v1](https://www.whvn.cc/help/api),
section Rate Limiting and Errors, 45/minute (page sans date de publication).

## Limites de livraison

Les tests n'ouvrent pas l'application WPF, n'installent rien et ne changent pas
le bureau réel. Un essai Windows 10/11 prolongé avec les deux applications,
de vrais délais réseau et l'écran 5120×1440 reste nécessaire. Ni fusion ni release.
