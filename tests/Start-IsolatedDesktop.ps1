# Interactive fixture only: no installation, user data, real API or wallpaper changes.
param([switch]$Wait,[switch]$PrepareOnly)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path $Root ('.test-tmp/desktop-preview-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$utf8=New-Object Text.UTF8Encoding($true)
$runtime=[IO.File]::ReadAllText((Join-Path $Root 'src/Wallhaven-Wallpaper-Tray.ps1'))
$tokens=$null; $errors=$null
$tree=[Management.Automation.Language.Parser]::ParseInput($runtime,[ref]$tokens,[ref]$errors)
foreach($name in @('Set-WindowsWallpaper','Start-WallhavenApiTask')) {
    $fn=$tree.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)|Where-Object Name -eq $name|Select-Object -First 1
    $replacement=if($name -eq 'Set-WindowsWallpaper'){'function Set-WindowsWallpaper { param($Path) Write-Log INFO "fixture.apply $Path" }'}else{'function Start-WallhavenApiTask { param($Kind,$Url) throw "Network disabled in isolated UX fixture." }'}
    $runtime=$runtime.Replace($fn.Extent.Text,$replacement)
}
$identity='WallhavenUxFixture'+[guid]::NewGuid().ToString('N')
$runtime=$runtime.Replace('Local\WallhavenWallpaperRotator',('Local\'+$identity)).Replace('JulienTools.WallhavenRotator',('JulienTools.'+$identity))
$runtime=$runtime.Replace('$RunValueName = "WallhavenWallpaperRotator"',('$RunValueName = "'+$identity+'"'))
$runtime=$runtime.Replace('Title="Wallhaven Rotator"','Title="Wallhaven Rotator - isolated UX test"')
# ShellExecute can delegate to Explorer: isolate the child even without inherited environment.
$shared=Join-Path $fixture 'shared'
$prefix='$env:LOCALAPPDATA = '''+$fixture.Replace("'","''")+"'`r`n"+
    '$env:WALLHAVEN_SHARED_BASE_DIR = '''+$shared.Replace("'","''")+"'`r`n"+
    '$env:WALLHAVEN_SHARED_MUTEX_NAME = ''Local\'+$identity+"History'`r`n"
$runtime=$runtime.Replace('# Wallhaven Rotator',($prefix+'# Wallhaven Rotator'))
if($PrepareOnly) {
    $probe=@'
$script:Timer.Add_Tick({
    $report=@{pid=$PID;visible=$window.IsVisible;taskbar=$window.ShowInTaskbar;autostart=[bool]$Autostart}
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ui-probe.json'),($report|ConvertTo-Json -Compress))
    if(Test-Path (Join-Path $PSScriptRoot 'exit.fixture')) { Request-DesktopExit }
})
'@
    $runtime=$runtime.Replace('$app = New-Object System.Windows.Application',($probe+"`r`n"+'$app = New-Object System.Windows.Application'))
}
[IO.File]::WriteAllText((Join-Path $fixture 'Wallhaven-Wallpaper-Tray.ps1'),$runtime,$utf8)
foreach($file in @('Wallhaven-SharedPolicy.ps1','Wallhaven-Desktop.ps1')) { Copy-Item -LiteralPath (Join-Path $Root "src/$file") -Destination $fixture }
Copy-Item -LiteralPath (Join-Path $Root 'assets/Wallhaven-Rotator.ico') -Destination $fixture
Copy-Item -LiteralPath (Join-Path $Root 'src/Wallhaven-Rotator-Launcher.vbs') -Destination $fixture
$base=Join-Path $fixture 'WallhavenWallpaperRotator'
$cache=Join-Path $base 'cache'
[void][IO.Directory]::CreateDirectory($cache)
$settings=[pscustomobject]@{sort='Aléatoire';category='Toutes';query='';contentFilter='Strict';value=1;unit='Minutes';autoRotation=$false;resolutionMode='Personnalisé';resolutionMatch='Exacte';customWidth=5120;customHeight=1440;customRatio='32:9';checkUpdates=$false;autoUpdate=$false;lastNotifiedUpdate=''}
[IO.File]::WriteAllText((Join-Path $base 'settings.json'),($settings|ConvertTo-Json),$utf8)
$key=ConvertTo-Json -Compress -InputObject @('','Toutes','Aléatoire','Strict','32x9','Exacte',5120,1440)
Add-Type -AssemblyName System.Drawing
$bitmap=New-Object Drawing.Bitmap(5120,1440)
try {
    $entries=@(foreach($i in 1..3) {
        $id="preview$i"
        $bitmap.Save((Join-Path $cache "wallhaven-$id.jpg"),[Drawing.Imaging.ImageFormat]::Jpeg)
        [pscustomobject]@{id=$id;category='general';tags=@('forest');checkedAt=[DateTime]::UtcNow.ToString('o');selectionKey=$key;
            candidate=[pscustomobject]@{id=$id;path="https://w.wallhaven.cc/full/pr/wallhaven-$id.jpg";url="https://wallhaven.cc/w/$id";category='general';resolution='5120x1440';dimension_x=5120;dimension_y=1440;file_type='image/jpeg';selectionKey=$key}}
    })
} finally { $bitmap.Dispose() }
[IO.File]::WriteAllText((Join-Path $base 'metadata-cache.json'),(ConvertTo-Json -Depth 8 -InputObject @{schema=1;entries=$entries}),$utf8)
$shared=Join-Path $fixture 'shared'
[void][IO.Directory]::CreateDirectory($shared)
$history=@{version=2;updatedAt=[DateTimeOffset]::Now.ToString('o');pending=@();migrations=@{rotatorV1=$true;screensaverV1=$true};entries=@(foreach($i in 1..5000){@{wallhavenId="old$i";shownAt=[DateTimeOffset]::Now.AddDays(-1).ToString('o')}})}
[IO.File]::WriteAllText((Join-Path $shared 'history.json'),(ConvertTo-Json -Depth 5 -InputObject $history),$utf8)
if($PrepareOnly) { [pscustomobject]@{path=$fixture;mutex=('Local\'+$identity)}|ConvertTo-Json -Compress; return }
$previousLocal=$env:LOCALAPPDATA; $previousShared=$env:WALLHAVEN_SHARED_BASE_DIR; $previousMutex=$env:WALLHAVEN_SHARED_MUTEX_NAME
try {
    $env:LOCALAPPDATA=$fixture; $env:WALLHAVEN_SHARED_BASE_DIR=$shared; $env:WALLHAVEN_SHARED_MUTEX_NAME='Local\'+$identity+'History'
    $process=Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-STA','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+(Join-Path $fixture 'Wallhaven-Wallpaper-Tray.ps1')+'"')) -RedirectStandardError (Join-Path $fixture 'stderr.txt') -RedirectStandardOutput (Join-Path $fixture 'stdout.txt') -PassThru
    Write-Host "Isolated UX fixture PID=$($process.Id) path=$fixture"
    if($Wait) { $process.WaitForExit() }
}
finally { $env:LOCALAPPDATA=$previousLocal; $env:WALLHAVEN_SHARED_BASE_DIR=$previousShared; $env:WALLHAVEN_SHARED_MUTEX_NAME=$previousMutex }
