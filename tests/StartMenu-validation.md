# Raccourci du menu Demarrer — validation du 24 octobre 2026

Base : `4d7e0d4`, branche `fix/wpf-responsive-selection`, PR #11 sur PR #10.

## Diagnostic et correctif

L'installateur ne creait aucun raccourci dans Programs. Le lanceur VBS officiel
fonctionnait deja ; il reste inchange, ainsi que tous les fichiers `src/` et VERSION.

`setup/startmenu_windows.go` utilise IShellLinkW/IPersistFile directement, sans
dependance externe, sur un thread COM STA verrouille et libere correctement.
Le lien par utilisateur est exactement `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Wallhaven Rotator.lnk` :

- cible `%WINDIR%\System32\wscript.exe` ;
- arguments `//B //Nologo "<installation>\Wallhaven-Rotator-Launcher.vbs" show` ;
- icone `<installation>\Wallhaven-Rotator.ico`, index 0 ;
- dossier de travail : installation ; description : `Wallhaven Rotator`.

L'installation et l'OTA passent par `installWithLaunch`. Un lien reconnu vers
notre VBS (directement ou via wscript) est repare, y compris un lien manuel sans
dossier de travail ou utilisant autostart. Un lien etranger, inconnu ou illisible
n'est jamais remplace silencieusement : l'installation signale le conflit avant
de modifier son payload. Le remplacement utilise un fichier temporaire dans le
meme dossier ; un echec ne supprime pas l'ancien lien.

La desinstallation retire uniquement ce lien reconnu, apres suppression reussie
du dossier d'application. Un lien etranger reste en place. Le perimetre existant
de suppression de l'application est inchange.

## Preuves automatiques locales sur Windows

- Tests Go 1.23.2 : creation, proprietes lues independamment via WScript.Shell,
  reinstallation sans doublon, suppression/reparation, adoption du lien manuel,
  OTA, conflit etranger, lien corrompu/repertoire, premier script etranger dans
  les arguments, remplacement verrouille et desinstallation echouee.
- Le premier cycle CI a revele une difference entre chemin court Windows
  (`RUNNER~1`) et chemin long renvoye par le Shell pour un lien VBS manuel.
  Echec reproduit localement avec de vrais alias 8.3, puis corrige via
  GetLongPathNameW. Les octets du lien reconnu sont memorises avant la suppression
  de l'application et compares avant son retrait. Trois sous-tests couvrent les
  liens VBS manuels, repares et WScript avec arguments courts. Un autre test
  prouve qu'un lien remplace entre reconnaissance et retrait est conserve.
- Installation/OTA/desinstallation executees dans des dossiers APPDATA et
  LOCALAPPDATA factices ; appels registre, mutex reel et lancement de l'installateur
  remplaces dans ce test. Parametres, caches et historique sont compares octet
  par octet apres reinstallation/OTA ; historique partage et autres liens restent
  presents apres la desinstallation isolee.
- Chemins avec espaces et accents ; caracteres chinois et hors BMP conserves
  dans le fichier UTF-16 et relus via IShellLinkW. WScript.Shell expose des
  chaines ANSI : il ne sert pas d'oracle pour les caracteres hors de sa page de code.
- Lancement effectif du `.lnk` via le Shell/WSH, VBS officiel et runtime WPF
  copie : fenetre visible en mode show, HWND reel, croix masquant la fenetre,
  second lancement restaurant le meme PID, arret propre de cette instance.
  Donnees et mutex propres a la fixture, API de selection et application du fond
  neutralisees, recherche de mises a jour desactivee. Les commandes manuelles
  de mise a jour ne sont pas declenchees par ce scenario. Ce test necessite une execution hors du bac a sable local qui
  empechait la creation du processus par le Shell ; le premier essai restreint
  a echoue sans preuve de fenetre. Le test complet hors sandbox est vert.
- 13 suites PowerShell 5.1 vertes, dont cycle WPF, autostart/OTA, geometrie,
  runspace, selection Strict 32:9, historique et budgets reseau.
- `go vet -unsafeptr=false ./...` vert (commande du build existant).
- Deux executions de `scripts/Build.ps1`, meme SHA-256 :
  `4bd3e2a5b3cf34382c0fe4c67c77b2d3140674f55aa9a9b95797ace829a177a2`.
  Installateur `dist/WallhavenRotator-Setup-v1.2.0.exe`, version 1.2.0 inchangee.

## Limites et STOP_GATE

La validation physique WPF/UX precedente sous Windows 11 est rapportee par
l'utilisateur. Cette livraison ajoute une preuve automatique sur une vraie
fenetre isolee ; elle ne remplace pas la verification visuelle du resultat de
recherche dans le menu Demarrer apres installation normale. L'indexation Windows,
le lancement depuis ce resultat et le rendu de son icone restent a confirmer
manuellement sur le poste cible. Aucun delai d'indexation n'est garanti.

Aucune installation/desinstallation sur le profil reel, aucune fusion, aucune
release et aucune modification de donnees utilisateur. Le chemin Programs suit
l'emplacement APPDATA demande ; les profils a dossier Programs redirige ne sont
pas testes. Les contraintes de coordination Screensaver de PR #10 subsistent.

Les resultats CI propres au commit livre sont references dans la PR #11.
