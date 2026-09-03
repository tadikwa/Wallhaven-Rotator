param(
    [switch]$Autostart
)

# Wallhaven Rotator
# Version épurée : rotation du wallpaper Wallhaven uniquement.

$ErrorActionPreference = "Stop"
$script:AppVersion = "1.1.0"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$AppName = "WallhavenWallpaperRotator"
$RunValueName = "WallhavenWallpaperRotator"
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

$BaseDir = Join-Path $env:LOCALAPPDATA $AppName
$CacheDir = Join-Path $BaseDir "cache"
$LogDir = Join-Path $BaseDir "logs"
$SettingsPath = Join-Path $BaseDir "settings.json"
$HistoryPath = Join-Path $BaseDir "history.json"
$ShowRequestPath = Join-Path $BaseDir "show.request"
$UpdateDir = Join-Path $BaseDir "updates"

$IconPath = Join-Path $PSScriptRoot "Wallhaven-Rotator.ico"
$LauncherPath = Join-Path $PSScriptRoot "Wallhaven-Rotator-Launcher.vbs"
$WScriptPath = Join-Path $env:WINDIR "System32\wscript.exe"

$ApiBase = "https://wallhaven.cc/api/v1/search"
$GitHubLatestReleaseApi = "https://api.github.com/repos/tadikwa/Wallhaven-Rotator/releases/latest"
$GitHubReleasesUrl = "https://github.com/tadikwa/Wallhaven-Rotator/releases"
$UpdateCheckInterval = [TimeSpan]::FromHours(6)
$ExpectedUpdateSignerCn = "CN=SignPath Foundation"
$ExpectedUpdateSignerOrg = "O=SignPath Foundation"
$UpdateRetentionDays = 7
$LogRetentionDays = 7
$LogMaxBytes = 2097152

# Anti-répétition / cache.
# 1 000 IDs = plus de deux journées de 8 h à raison d'un changement/minute.
$HistoryMaxIds = 1000
$HistoryRecentFallbackIds = 200
$CacheMaxFiles = 50
$CacheMaxBytes = 524288000  # 500 MiB
$ApiSelectionAttemptsPerMode = 4

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
New-Item -ItemType Directory -Path $UpdateDir -Force | Out-Null

$script:LastLogCleanup = [DateTime]::MinValue

function Get-CurrentLogPath {
    Join-Path $LogDir ("wallhaven-{0}.log" -f (Get-Date -Format "yyyy-MM-dd"))
}

function Remove-ExpiredLogs {
    try {
        $cutoff = [DateTime]::Now.AddDays(-1 * $LogRetentionDays)
        Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -like "wallhaven-*.log" -and
                $_.LastWriteTime -lt $cutoff
            } |
            Remove-Item -Force -ErrorAction SilentlyContinue

        $script:LastLogCleanup = [DateTime]::Now
    } catch {}
}

function Write-Log {
    param(
        [string]$Level,
        [string]$Message
    )

    try {
        if (([DateTime]::Now - $script:LastLogCleanup).TotalMinutes -ge 30) {
            Remove-ExpiredLogs
        }

        $logPath = Get-CurrentLogPath

        if (Test-Path $logPath) {
            $file = Get-Item $logPath -ErrorAction SilentlyContinue
            if ($file -and $file.Length -gt $LogMaxBytes) {
                $archive = Join-Path $LogDir (
                    "wallhaven-{0}-{1}.log" -f
                    (Get-Date -Format "yyyy-MM-dd"),
                    (Get-Date -Format "HHmmss")
                )
                Move-Item $logPath $archive -Force -ErrorAction SilentlyContinue
            }
        }

        $line = "{0} [{1}] {2}" -f `
            (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"),
            $Level,
            $Message

        Add-Content -Path $logPath -Value $line -Encoding UTF8
    } catch {}
}

Remove-ExpiredLogs

# Une seule instance.
$createdNew = $false
$script:Mutex = [System.Threading.Mutex]::new(
    $true,
    "Local\WallhavenWallpaperRotator",
    [ref]$createdNew
)

if (-not $createdNew) {
    try {
        Set-Content `
            -Path $ShowRequestPath `
            -Value ([DateTime]::Now.ToString("o")) `
            -Encoding ASCII
    } catch {}

    exit
}

if (-not ("WallpaperNativeV40" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class WallpaperNativeV40
{
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern bool SystemParametersInfo(
        int uAction,
        int uParam,
        string lpvParam,
        int fuWinIni
    );
}

public static class ConsoleNativeV40
{
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    public static void Hide()
    {
        IntPtr h = GetConsoleWindow();
        if (h != IntPtr.Zero) {
            ShowWindow(h, 0);
        }
    }
}

public static class ShellIdentityNativeV40
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
}
"@
}

# Filet de sécurité si le script est démarré autrement que par le launcher WScript.
try { [ConsoleNativeV40]::Hide() } catch {}

$script:AppUserModelId = "JulienTools.WallhavenRotator"
try {
    [void][ShellIdentityNativeV40]::SetCurrentProcessExplicitAppUserModelID(
        $script:AppUserModelId
    )
} catch {}

$SortNames = @("Tendance", "Populaires", "Nouveaux", "Aléatoire")
$CategoryNames = @("Général", "Anime", "Personnes", "Toutes")
$UnitNames = @("Minutes", "Heures", "Jours")
$ResolutionModeNames = @("Automatique", "Personnalisé")
$ResolutionMatchNames = @("Au moins", "Exacte")
$CustomRatioNames = @(
    "Automatique",
    "16:9", "16:10", "21:9", "32:9", "48:9",
    "4:3", "5:4", "3:2", "1:1",
    "10:16", "9:16", "9:18"
)

function Get-DefaultSettings {
    [pscustomobject]@{
        sort = "Aléatoire"
        category = "Toutes"
        value = 1
        unit = "Minutes"
        autoRotation = $true
        resolutionMode = "Automatique"
        resolutionMatch = "Au moins"
        customWidth = 2560
        customHeight = 1440
        customRatio = "Automatique"
        checkUpdates = $true
        autoUpdate = $false
        lastNotifiedUpdate = ""
    }
}

function Load-Settings {
    $defaults = Get-DefaultSettings

    if (-not (Test-Path $SettingsPath)) {
        return $defaults
    }

    try {
        $old = Get-Content -Path $SettingsPath -Raw | ConvertFrom-Json

        $sort = if ([string]$old.sort -in $SortNames) {
            [string]$old.sort
        } else {
            $defaults.sort
        }

        $category = if ([string]$old.category -in $CategoryNames) {
            [string]$old.category
        } else {
            $defaults.category
        }

        $value = 0
        if (-not [int]::TryParse([string]$old.value, [ref]$value)) {
            $value = $defaults.value
        }
        if ($value -lt 1 -or $value -gt 999) {
            $value = $defaults.value
        }

        $unit = if ([string]$old.unit -in $UnitNames) {
            [string]$old.unit
        } else {
            $defaults.unit
        }

        $auto = if ($null -eq $old.autoRotation) {
            $true
        } else {
            [bool]$old.autoRotation
        }

        $resolutionMode = if ([string]$old.resolutionMode -in $ResolutionModeNames) {
            [string]$old.resolutionMode
        } else {
            $defaults.resolutionMode
        }

        $customWidth = 0
        if (-not [int]::TryParse([string]$old.customWidth, [ref]$customWidth) -or $customWidth -lt 640 -or $customWidth -gt 15360) {
            $customWidth = $defaults.customWidth
        }

        $customHeight = 0
        if (-not [int]::TryParse([string]$old.customHeight, [ref]$customHeight) -or $customHeight -lt 480 -or $customHeight -gt 8640) {
            $customHeight = $defaults.customHeight
        }

        $resolutionMatch = if ([string]$old.resolutionMatch -in $ResolutionMatchNames) {
            [string]$old.resolutionMatch
        } else {
            $defaults.resolutionMatch
        }

        $customRatio = if ([string]$old.customRatio -in $CustomRatioNames) {
            [string]$old.customRatio
        } else {
            $defaults.customRatio
        }

        $checkUpdates = if ($null -eq $old.checkUpdates) { $true } else { [bool]$old.checkUpdates }
        $autoUpdate = if ($null -eq $old.autoUpdate) { $false } else { [bool]$old.autoUpdate }
        $lastNotifiedUpdate = if ($null -eq $old.lastNotifiedUpdate) { "" } else { [string]$old.lastNotifiedUpdate }

        return [pscustomobject]@{
            sort = $sort
            category = $category
            value = $value
            unit = $unit
            autoRotation = $auto
            resolutionMode = $resolutionMode
            resolutionMatch = $resolutionMatch
            customWidth = $customWidth
            customHeight = $customHeight
            customRatio = $customRatio
            checkUpdates = $checkUpdates
            autoUpdate = $autoUpdate
            lastNotifiedUpdate = $lastNotifiedUpdate
        }
    }
    catch {
        Write-Log "WARN" "Paramètres illisibles ; valeurs par défaut utilisées : $($_.Exception.Message)"
        return $defaults
    }
}

function Save-Settings {
    try {
        [ordered]@{
            sort = [string]$script:Settings.sort
            category = [string]$script:Settings.category
            value = [int]$script:Settings.value
            unit = [string]$script:Settings.unit
            autoRotation = [bool]$script:Settings.autoRotation
            resolutionMode = [string]$script:Settings.resolutionMode
            resolutionMatch = [string]$script:Settings.resolutionMatch
            customWidth = [int]$script:Settings.customWidth
            customHeight = [int]$script:Settings.customHeight
            customRatio = [string]$script:Settings.customRatio
            checkUpdates = [bool]$script:Settings.checkUpdates
            autoUpdate = [bool]$script:Settings.autoUpdate
            lastNotifiedUpdate = [string]$script:Settings.lastNotifiedUpdate
        } |
            ConvertTo-Json |
            Set-Content -Path $SettingsPath -Encoding UTF8
    }
    catch {
        Write-Log "ERROR" "Impossible d'enregistrer les paramètres : $($_.Exception.Message)"
    }
}

function ConvertTo-QueryString {
    param([System.Collections.IDictionary]$Parameters)

    (($Parameters.GetEnumerator() | ForEach-Object {
        "{0}={1}" -f `
            [Uri]::EscapeDataString([string]$_.Key), `
            [Uri]::EscapeDataString([string]$_.Value)
    }) -join "&")
}

function Get-Interval {
    $value = [double]$script:Settings.value

    switch ([string]$script:Settings.unit) {
        "Minutes" { [TimeSpan]::FromMinutes($value) }
        "Heures"  { [TimeSpan]::FromHours($value) }
        "Jours"   { [TimeSpan]::FromDays($value) }
        default   { [TimeSpan]::FromMinutes(1) }
    }
}

function Format-Interval {
    $value = [int]$script:Settings.value

    switch ([string]$script:Settings.unit) {
        "Minutes" {
            if ($value -eq 1) { "1 minute" } else { "$value minutes" }
        }
        "Heures" {
            if ($value -eq 1) { "1 heure" } else { "$value heures" }
        }
        "Jours" {
            if ($value -eq 1) { "1 jour" } else { "$value jours" }
        }
        default { "1 minute" }
    }
}

function Schedule-NextChange {
    $script:NextChange = [DateTime]::Now.Add((Get-Interval))
}

function Get-PrimaryResolution {
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        [pscustomobject]@{
            Width = [int]$bounds.Width
            Height = [int]$bounds.Height
        }
    }
    catch {
        [pscustomobject]@{ Width = 0; Height = 0 }
    }
}

function Get-WallhavenRatioForSize {
    param(
        [int]$Width,
        [int]$Height
    )

    if ($Width -le 0 -or $Height -le 0) {
        return "16x9"
    }

    $target = [double]$Width / [double]$Height
    $ratios = @(
        [pscustomobject]@{ Name = "48x9"; Value = 48.0 / 9.0 },
        [pscustomobject]@{ Name = "32x9"; Value = 32.0 / 9.0 },
        [pscustomobject]@{ Name = "21x9"; Value = 21.0 / 9.0 },
        [pscustomobject]@{ Name = "16x9"; Value = 16.0 / 9.0 },
        [pscustomobject]@{ Name = "16x10"; Value = 16.0 / 10.0 },
        [pscustomobject]@{ Name = "3x2"; Value = 3.0 / 2.0 },
        [pscustomobject]@{ Name = "4x3"; Value = 4.0 / 3.0 },
        [pscustomobject]@{ Name = "5x4"; Value = 5.0 / 4.0 },
        [pscustomobject]@{ Name = "1x1"; Value = 1.0 },
        [pscustomobject]@{ Name = "10x16"; Value = 10.0 / 16.0 },
        [pscustomobject]@{ Name = "9x16"; Value = 9.0 / 16.0 },
        [pscustomobject]@{ Name = "9x18"; Value = 9.0 / 18.0 }
    )

    $best = $ratios[0]
    $bestDistance = [double]::MaxValue

    foreach ($ratio in $ratios) {
        # Log distance treats reciprocal/relative differences consistently.
        $distance = [math]::Abs([math]::Log($target / [double]$ratio.Value))
        if ($distance -lt $bestDistance) {
            $bestDistance = $distance
            $best = $ratio
        }
    }

    return [string]$best.Name
}

function Convert-WallhavenRatioChoice {
    param(
        [string]$Choice,
        [int]$Width,
        [int]$Height
    )

    if ([string]::IsNullOrWhiteSpace($Choice) -or $Choice -eq "Automatique") {
        return (Get-WallhavenRatioForSize -Width $Width -Height $Height)
    }

    if ($Choice -in $CustomRatioNames) {
        return $Choice.Replace(":", "x")
    }

    return (Get-WallhavenRatioForSize -Width $Width -Height $Height)
}

function Get-TargetDisplayFilter {
    if ([string]$script:Settings.resolutionMode -eq "Personnalisé") {
        $width = [int]$script:Settings.customWidth
        $height = [int]$script:Settings.customHeight
        $source = "Personnalisé"
        $matchMode = if ([string]$script:Settings.resolutionMatch -in $ResolutionMatchNames) {
            [string]$script:Settings.resolutionMatch
        } else {
            "Au moins"
        }
        $ratioChoice = [string]$script:Settings.customRatio
    }
    else {
        $screen = Get-PrimaryResolution
        $width = [int]$screen.Width
        $height = [int]$screen.Height
        $source = "Automatique"
        $matchMode = "Au moins"
        $ratioChoice = "Automatique"
    }

    if ($width -le 0 -or $height -le 0) {
        $width = 1920
        $height = 1080
        $source = "Secours"
        $matchMode = "Au moins"
        $ratioChoice = "Automatique"
    }

    $ratio = Convert-WallhavenRatioChoice `
        -Choice $ratioChoice `
        -Width $width `
        -Height $height

    [pscustomobject]@{
        Width = $width
        Height = $height
        Ratio = $ratio
        Source = $source
        MatchMode = $matchMode
        RatioChoice = $ratioChoice
        IsExact = ($matchMode -eq "Exacte")
        Label = "$width×$height · $($ratio.Replace('x', ':'))"
    }
}

function Get-ResolutionQueryParameters {
    param(
        $Target,
        [bool]$UseResolution
    )

    $result = [ordered]@{}

    if ($Target -and -not [string]::IsNullOrWhiteSpace([string]$Target.Ratio)) {
        $result["ratios"] = [string]$Target.Ratio
    }

    if ($Target -and [int]$Target.Width -gt 0 -and [int]$Target.Height -gt 0) {
        if ([bool]$Target.IsExact) {
            $result["resolutions"] = "$([int]$Target.Width)x$([int]$Target.Height)"
        }
        elseif ($UseResolution) {
            $result["atleast"] = "$([int]$Target.Width)x$([int]$Target.Height)"
        }
    }

    return $result
}

function Test-ResolutionFallbackAllowed {
    param(
        $Target,
        [bool]$UseResolution
    )

    return (
        $UseResolution -and
        $Target -and
        -not [bool]$Target.IsExact
    )
}

function Load-WallpaperHistory {
    $list = New-Object 'System.Collections.Generic.List[string]'

    if (-not (Test-Path $HistoryPath)) {
        # Keep the generic List object intact. PowerShell otherwise enumerates
        # collection output and an empty list becomes $null to the caller.
        Write-Output -NoEnumerate $list
        return
    }

    try {
        $raw = Get-Content -Path $HistoryPath -Raw | ConvertFrom-Json
        $ids = @()

        if ($raw.PSObject.Properties["ids"]) {
            $ids = @($raw.ids)
        }
        elseif ($raw -is [System.Array]) {
            $ids = @($raw)
        }

        foreach ($id in $ids) {
            $s = [string]$id
            if (-not [string]::IsNullOrWhiteSpace($s)) {
                $list.Add($s)
            }
        }

        while ($list.Count -gt $HistoryMaxIds) {
            $list.RemoveAt(0)
        }
    }
    catch {
        Write-Log "WARN" "Historique illisible ; nouveau fichier créé : $($_.Exception.Message)"
        $list.Clear()
    }

    # Always return the List object itself, even when it contains 0 or 1 item.
    Write-Output -NoEnumerate $list
}

function Save-WallpaperHistory {
    try {
        $ids = @()
        foreach ($id in $script:HistoryIds) {
            $ids += [string]$id
        }

        [ordered]@{
            version = 1
            maxIds = $HistoryMaxIds
            updatedAt = [DateTime]::Now.ToString("o")
            ids = $ids
        } |
            ConvertTo-Json -Depth 3 |
            Set-Content -Path $HistoryPath -Encoding UTF8
    }
    catch {
        Write-Log "WARN" "Impossible d'enregistrer l'historique : $($_.Exception.Message)"
    }
}

function Add-WallpaperToHistory {
    param([string]$Id)

    if ([string]::IsNullOrWhiteSpace($Id)) {
        return
    }

    # Defensive recovery for upgrades or a corrupted initialization state.
    if ($null -eq $script:HistoryIds) {
        $script:HistoryIds = New-Object 'System.Collections.Generic.List[string]'
    }

    while ($script:HistoryIds.Contains($Id)) {
        [void]$script:HistoryIds.Remove($Id)
    }

    $script:HistoryIds.Add($Id)

    while ($script:HistoryIds.Count -gt $HistoryMaxIds) {
        $script:HistoryIds.RemoveAt(0)
    }

    Save-WallpaperHistory
}

function Get-HistoryTail {
    param([int]$Count)

    $result = @()
    $start = [math]::Max(0, $script:HistoryIds.Count - $Count)

    for ($i = $start; $i -lt $script:HistoryIds.Count; $i++) {
        $result += [string]$script:HistoryIds[$i]
    }

    return $result
}

function Get-SelectionPageLimit {
    switch ([string]$script:Settings.sort) {
        "Tendance"   { return 20 }   # ~480 candidats potentiels
        "Populaires" { return 60 }   # ~1 440 candidats potentiels
        "Nouveaux"   { return 100 }  # ~2 400 candidats potentiels
        default       { return 1 }    # Wallhaven randomise déjà côté serveur
    }
}

function Get-SelectionPage {
    $configuredLimit = Get-SelectionPageLimit

    if ($configuredLimit -le 1) {
        $script:ApiCurrentPage = 1
        return 1
    }

    # On the first request for a filter combination, ask page 1 so Wallhaven
    # can tell us meta.last_page. Subsequent requests randomize only inside
    # the actual page range, avoiding pointless empty-page retries.
    $limit = 1
    if (
        $script:ApiQueryKey -and
        $script:PageCeilings.ContainsKey($script:ApiQueryKey)
    ) {
        $lastPage = [int]$script:PageCeilings[$script:ApiQueryKey]
        $limit = [math]::Max(1, [math]::Min($configuredLimit, $lastPage))
    }

    if ($limit -le 1) {
        $script:ApiCurrentPage = 1
        if ($script:PagesTried -notcontains 1) { $script:PagesTried += 1 }
        return 1
    }

    for ($try = 0; $try -lt 25; $try++) {
        $page = Get-Random -Minimum 1 -Maximum ($limit + 1)
        if ($script:PagesTried -notcontains $page) {
            $script:PagesTried += $page
            $script:ApiCurrentPage = $page
            return $page
        }
    }

    $page = Get-Random -Minimum 1 -Maximum ($limit + 1)
    $script:ApiCurrentPage = $page
    return $page
}

function Get-ApiUrl {
    param([bool]$UseResolution)

    $category = switch ([string]$script:Settings.category) {
        "Général"   { "100" }
        "Anime"     { "010" }
        "Personnes" { "001" }
        default     { "111" }
    }

    $params = [ordered]@{
        categories = $category
        purity = "100"
        order = "desc"
    }

    switch ([string]$script:Settings.sort) {
        "Tendance" {
            $params["sorting"] = "toplist"
            $params["topRange"] = "1d"
        }
        "Populaires" {
            $params["sorting"] = "toplist"
            $params["topRange"] = "1M"
        }
        "Nouveaux" {
            $params["sorting"] = "date_added"
        }
        default {
            $params["sorting"] = "random"
        }
    }

    $target = Get-TargetDisplayFilter
    $resolutionParams = Get-ResolutionQueryParameters `
        -Target $target `
        -UseResolution $UseResolution

    foreach ($key in $resolutionParams.Keys) {
        $params[$key] = [string]$resolutionParams[$key]
    }

    $script:ApiQueryKey = "{0}|{1}|{2}|{3}|{4}|{5}x{6}" -f `
        [string]$script:Settings.sort,
        [string]$script:Settings.category,
        [string]$target.Ratio,
        [string]$target.MatchMode,
        [bool]$UseResolution,
        [int]$target.Width,
        [int]$target.Height

    $pageLimit = Get-SelectionPageLimit
    if ($pageLimit -gt 1) {
        $params["page"] = [string](Get-SelectionPage)
    }
    else {
        $script:ApiCurrentPage = 1
    }

    "$ApiBase`?$(ConvertTo-QueryString -Parameters $params)"
}

function Set-WindowsWallpaper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $desktopKey = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $desktopKey -Name "WallpaperStyle" -Value "10"
    Set-ItemProperty -Path $desktopKey -Name "TileWallpaper" -Value "0"

    $ok = [WallpaperNativeV40]::SystemParametersInfo(
        20,
        0,
        $Path,
        (1 -bor 2)
    )

    if (-not $ok) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Windows a refusé le changement de fond d'écran (Win32 $code)."
    }
}

function Trim-WallpaperCache {
    param([string]$KeepPath)

    try {
        $files = @(
            Get-ChildItem -Path $CacheDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "wallhaven-*" } |
                Sort-Object LastWriteTime -Descending
        )

        if ($files.Count -eq 0) {
            return
        }

        [int64]$totalBytes = 0
        foreach ($file in $files) {
            $totalBytes += [int64]$file.Length
        }

        $remainingCount = $files.Count
        $removedCount = 0
        [int64]$removedBytes = 0

        # Supprime les plus anciens jusqu'à respecter les DEUX limites.
        for ($i = $files.Count - 1; $i -ge 0; $i--) {
            if (
                $remainingCount -le $CacheMaxFiles -and
                $totalBytes -le $CacheMaxBytes
            ) {
                break
            }

            $file = $files[$i]
            if ($KeepPath -and $file.FullName -eq $KeepPath) {
                continue
            }

            try {
                $length = [int64]$file.Length
                Remove-Item -Path $file.FullName -Force -ErrorAction Stop
                $remainingCount--
                $totalBytes -= $length
                $removedCount++
                $removedBytes += $length
            }
            catch {}
        }

        if ($removedCount -gt 0) {
            $removedMiB = [math]::Round($removedBytes / 1MB, 1)
            $remainingMiB = [math]::Round($totalBytes / 1MB, 1)
            Write-Log "INFO" "Cache nettoyé : $removedCount fichier(s) / $removedMiB MiB supprimés ; reste=$remainingCount fichier(s), $remainingMiB MiB."
        }
    }
    catch {
        Write-Log "WARN" "Nettoyage cache impossible : $($_.Exception.Message)"
    }
}

function Test-ImageBytes {
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 4) {
        return $false
    }

    $jpeg = ($Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xD8)
    $png = (
        $Bytes[0] -eq 0x89 -and
        $Bytes[1] -eq 0x50 -and
        $Bytes[2] -eq 0x4E -and
        $Bytes[3] -eq 0x47
    )

    return ($jpeg -or $png)
}

function Get-AutostartCommand {
    if (
        (Test-Path $WScriptPath) -and
        (Test-Path $LauncherPath)
    ) {
        return '"{0}" //B //Nologo "{1}" autostart' -f `
            $WScriptPath,
            $LauncherPath
    }

    return 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Autostart' -f $PSCommandPath
}

function Test-RunAtLogon {
    try {
        $value = (Get-ItemProperty `
            -Path $RunKey `
            -Name $RunValueName `
            -ErrorAction Stop).$RunValueName

        return -not [string]::IsNullOrWhiteSpace([string]$value)
    }
    catch {
        return $false
    }
}

function Set-RunAtLogon {
    param([bool]$Enabled)

    try {
        if ($Enabled) {
            New-Item -Path $RunKey -Force | Out-Null
            Set-ItemProperty `
                -Path $RunKey `
                -Name $RunValueName `
                -Value (Get-AutostartCommand)
        }
        else {
            Remove-ItemProperty `
                -Path $RunKey `
                -Name $RunValueName `
                -ErrorAction SilentlyContinue
        }

        return $true
    }
    catch {
        Write-Log "ERROR" "Modification du lancement automatique refusée : $($_.Exception.Message)"
        return $false
    }
}

function Get-DeepErrorMessage {
    param($ErrorRecord)

    try {
        $ex = $ErrorRecord.Exception
        while ($null -ne $ex.InnerException) {
            $ex = $ex.InnerException
        }

        if ($ex.Message) {
            return [string]$ex.Message
        }
    } catch {}

    return [string]$ErrorRecord
}


function Test-IsNewerVersion {
    param(
        [string]$Candidate,
        [string]$Current = $script:AppVersion
    )

    try {
        return ([version]$Candidate -gt [version]$Current)
    }
    catch {
        return $false
    }
}

function Get-SignedSetupAssetName {
    param([string]$Version)
    return "WallhavenRotator-Setup-v$Version.exe"
}

function Test-ExpectedUpdatePublisher {
    param([string]$Subject)

    if ([string]::IsNullOrWhiteSpace($Subject)) {
        return $false
    }

    $cn = [regex]::Escape($ExpectedUpdateSignerCn)
    $org = [regex]::Escape($ExpectedUpdateSignerOrg)

    return (
        $Subject -match "(^|,\s*)$cn(,|$)" -and
        $Subject -match "(^|,\s*)$org(,|$)"
    )
}

function Get-ExpectedHashFromChecksumText {
    param(
        [string]$Text,
        [string]$FileName
    )

    if (
        [string]::IsNullOrWhiteSpace($Text) -or
        [string]::IsNullOrWhiteSpace($FileName)
    ) {
        return $null
    }

    $escapedName = [regex]::Escape($FileName)
    $match = [regex]::Match(
        $Text,
        "(?im)^([0-9a-f]{64})\s+[* ]?$escapedName\s*$"
    )

    if (-not $match.Success) {
        return $null
    }

    return $match.Groups[1].Value.ToLowerInvariant()
}

function Show-UpdateNotification {
    param([string]$Version)

    if (
        $script:UpdateNotifiedVersion -eq $Version -or
        [string]$script:Settings.lastNotifiedUpdate -eq $Version
    ) {
        return
    }

    $script:UpdateNotifiedVersion = $Version
    $script:Settings.lastNotifiedUpdate = $Version
    Save-Settings

    try {
        $notifyIcon.BalloonTipTitle = "Wallhaven Rotator $Version disponible"
        $notifyIcon.BalloonTipText = "Une nouvelle version est disponible. Ouvrez Wallhaven Rotator pour la mettre à jour."
        $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $notifyIcon.ShowBalloonTip(6000)
    } catch {}
}

function Update-UpdateUi {
    if ($null -ne $script:UpdateInfo -and (Test-IsNewerVersion -Candidate $script:UpdateInfo.Version)) {
        $VersionText.Text = "v$($script:AppVersion) · MAJ $($script:UpdateInfo.Version)"
        $VersionText.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(169, 233, 195))
        $UpdateBanner.Visibility = [System.Windows.Visibility]::Visible
        $UpdateBannerTitle.Text = "Mise à jour $($script:UpdateInfo.Version) disponible"

        if ($script:UpdateInfo.SignedAssetAvailable) {
            if (-not $script:UpdateInfo.HashAvailable) {
                $UpdateBannerText.Text = "Setup signé disponible, mais somme SHA-256 absente : installation automatique désactivée."
                $UpdateActionButton.Content = "Voir la release"
            }
            elseif ($script:UpdateReadyPath) {
                $UpdateBannerText.Text = "Setup SignPath vérifié et prêt à installer."
                $UpdateActionButton.Content = "Installer"
            }
            elseif ($script:UpdateStage -in @("Hash", "Binary")) {
                $UpdateBannerText.Text = "Téléchargement et vérification en cours…"
                $UpdateActionButton.Content = "Patientez…"
            }
            else {
                $UpdateBannerText.Text = "Setup signé publié ; cliquez pour le télécharger puis vérifier SHA-256 et Authenticode."
                $UpdateActionButton.Content = "Mettre à jour"
            }
        }
        else {
            $UpdateBannerText.Text = "La release existe, mais aucun setup signé n'est encore disponible."
            $UpdateActionButton.Content = "Voir la release"
        }
    }
    else {
        $VersionText.Text = "v$($script:AppVersion)"
        $VersionText.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(168, 177, 181))
        $UpdateBanner.Visibility = [System.Windows.Visibility]::Collapsed
    }

    if ($UpdateStateText) {
        if ($script:UpdateStage -in @("Check", "Hash", "Binary")) {
            $UpdateStateText.Text = "Vérification en cours…"
        }
        elseif ($null -ne $script:UpdateInfo -and (Test-IsNewerVersion -Candidate $script:UpdateInfo.Version)) {
            $signedText = if (-not $script:UpdateInfo.SignedAssetAvailable) {
                "signature en attente"
            }
            elseif (-not $script:UpdateInfo.HashAvailable) {
                "setup signé · checksum absent"
            }
            elseif ($script:UpdateReadyPath) {
                "setup vérifié"
            }
            else {
                "setup signé à vérifier"
            }
            $UpdateStateText.Text = "Disponible : $($script:UpdateInfo.Version) · $signedText"
        }
        else {
            $UpdateStateText.Text = "Version installée : $($script:AppVersion)"
        }
    }
}

function Start-UpdateCheck {
    param([switch]$Force)

    if (-not [bool]$script:Settings.checkUpdates -and -not $Force) {
        return
    }

    if ($script:UpdateStage -ne "Idle") {
        return
    }

    try {
        $script:UpdateStage = "Check"
        $script:UpdateCheckTask = $script:HttpClient.GetStringAsync($GitHubLatestReleaseApi)
        $script:NextUpdateCheck = [DateTime]::Now.Add($UpdateCheckInterval)
        Write-Log "INFO" "UPDATE CHECK $GitHubLatestReleaseApi"
        Update-UpdateUi
    }
    catch {
        $script:UpdateStage = "Idle"
        Write-Log "WARN" "Vérification mise à jour impossible : $(Get-DeepErrorMessage $_)"
    }
}

function Start-UpdateDownload {
    if ($null -eq $script:UpdateInfo -or -not $script:UpdateInfo.SignedAssetAvailable) {
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$script:UpdateInfo.HashUrl)) {
        Write-Log "WARN" "Mise à jour automatique refusée : SHA256SUMS.txt absent de la release."
        return
    }

    if ($script:UpdateStage -ne "Idle") {
        return
    }

    try {
        $script:UpdateStage = "Hash"
        $script:UpdateHashTask = $script:HttpClient.GetStringAsync([string]$script:UpdateInfo.HashUrl)
        Write-Log "INFO" "UPDATE HASH GET $($script:UpdateInfo.HashUrl)"
        Update-UpdateUi
    }
    catch {
        $script:UpdateStage = "Idle"
        Write-Log "WARN" "Téléchargement checksum impossible : $(Get-DeepErrorMessage $_)"
    }
}

function Test-DownloadedUpdate {
    param(
        [string]$Path,
        [string]$ExpectedHash
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $ExpectedHash.ToLowerInvariant()) {
            Write-Log "ERROR" "Mise à jour rejetée : SHA-256 inattendu ($actual)."
            return $false
        }

        $signature = Get-AuthenticodeSignature -FilePath $Path
        if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
            Write-Log "WARN" "Mise à jour automatique rejetée : signature Authenticode non valide ($($signature.Status))."
            return $false
        }

        $subject = [string]$signature.SignerCertificate.Subject
        if (-not (Test-ExpectedUpdatePublisher -Subject $subject)) {
            Write-Log "ERROR" "Mise à jour rejetée : éditeur Authenticode inattendu ($subject)."
            return $false
        }

        Write-Log "INFO" "Mise à jour vérifiée : SHA-256 + chaîne Authenticode valides ; éditeur=$subject ; issuer=$($signature.SignerCertificate.Issuer)"
        return $true
    }
    catch {
        Write-Log "WARN" "Validation de la mise à jour impossible : $(Get-DeepErrorMessage $_)"
        return $false
    }
}

function Invoke-SilentUpdate {
    if ([string]::IsNullOrWhiteSpace([string]$script:UpdateReadyPath) -or -not (Test-Path $script:UpdateReadyPath)) {
        if ($script:UpdateInfo -and $script:UpdateInfo.ReleaseUrl) {
            Start-Process ([string]$script:UpdateInfo.ReleaseUrl)
        }
        return
    }

    try {
        $autostartArg = if (Test-RunAtLogon) { "--autostart=1" } else { "--autostart=0" }

        Write-Log "INFO" "Lancement mise à jour silencieuse : $($script:UpdateReadyPath) ; $autostartArg"
        Start-Process `
            -FilePath $script:UpdateReadyPath `
            -ArgumentList @("--silent-update", $autostartArg)

        $script:Exiting = $true
        try { $script:Timer.Stop() } catch {}
        try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {}
        try { if ($script:TrayIconObject) { $script:TrayIconObject.Dispose() } } catch {}
        try { $script:HttpClient.Dispose() } catch {}
        try { $handler.Dispose() } catch {}
        try { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } catch {}
        try { $window.Close() } catch {}
        [System.Windows.Application]::Current.Shutdown()
    }
    catch {
        Write-Log "ERROR" "Lancement de la mise à jour impossible : $(Get-DeepErrorMessage $_)"
    }
}

function Process-UpdateState {
    if ($script:UpdateStage -eq "Check" -and $script:UpdateCheckTask -and $script:UpdateCheckTask.IsCompleted) {
        try {
            $json = $script:UpdateCheckTask.GetAwaiter().GetResult()
            $release = $json | ConvertFrom-Json
            $version = ([string]$release.tag_name).TrimStart([char[]]"vV")

            if (-not [string]::IsNullOrWhiteSpace($version) -and (Test-IsNewerVersion -Candidate $version)) {
                $previousVersion = if ($script:UpdateInfo) { [string]$script:UpdateInfo.Version } else { "" }
                if ($previousVersion -and $previousVersion -ne $version) {
                    $script:UpdateReadyPath = $null
                    $script:UpdateExpectedHash = $null
                }

                $signedName = Get-SignedSetupAssetName -Version $version
                $signedAsset = @($release.assets | Where-Object { [string]$_.name -eq $signedName } | Select-Object -First 1)
                $hashAsset = @($release.assets | Where-Object { [string]$_.name -in @("SHA256-SIGNED.txt", "SHA256SUMS.txt") } | Sort-Object { if ([string]$_.name -eq "SHA256-SIGNED.txt") { 0 } else { 1 } } | Select-Object -First 1)

                $script:UpdateInfo = [pscustomobject]@{
                    Version = $version
                    ReleaseUrl = [string]$release.html_url
                    SignedAssetAvailable = ($signedAsset.Count -gt 0)
                    HashAvailable = ($hashAsset.Count -gt 0)
                    SetupUrl = if ($signedAsset.Count -gt 0) { [string]$signedAsset[0].browser_download_url } else { $null }
                    HashUrl = if ($hashAsset.Count -gt 0) { [string]$hashAsset[0].browser_download_url } else { $null }
                    SetupName = $signedName
                }

                Write-Log "INFO" "Mise à jour détectée : $version ; signé=$($script:UpdateInfo.SignedAssetAvailable)"
                Show-UpdateNotification -Version $version
            }
            else {
                $script:UpdateInfo = $null
                $script:UpdateReadyPath = $null
                $script:UpdateExpectedHash = $null
                Write-Log "DEBUG" "Aucune mise à jour disponible ; courant=$($script:AppVersion), latest=$version"
            }
        }
        catch {
            Write-Log "WARN" "Réponse GitHub Releases invalide : $(Get-DeepErrorMessage $_)"
        }
        finally {
            $script:UpdateCheckTask = $null
            $script:UpdateStage = "Idle"
            Update-UpdateUi
        }

        if (
            $script:UpdateInfo -and
            $script:UpdateInfo.SignedAssetAvailable -and
            $script:UpdateInfo.HashAvailable -and
            [bool]$script:Settings.autoUpdate
        ) {
            Start-UpdateDownload
        }
        return
    }

    if ($script:UpdateStage -eq "Hash" -and $script:UpdateHashTask -and $script:UpdateHashTask.IsCompleted) {
        try {
            $hashText = $script:UpdateHashTask.GetAwaiter().GetResult()
            $expectedHash = Get-ExpectedHashFromChecksumText `
                -Text $hashText `
                -FileName ([string]$script:UpdateInfo.SetupName)

            if ([string]::IsNullOrWhiteSpace($expectedHash)) {
                throw "Le fichier de sommes SHA-256 ne contient pas $($script:UpdateInfo.SetupName)."
            }

            $script:UpdateExpectedHash = $expectedHash
            $script:UpdateStage = "Binary"
            $script:UpdateBinaryTask = $script:HttpClient.GetByteArrayAsync([string]$script:UpdateInfo.SetupUrl)
            Write-Log "INFO" "UPDATE BINARY GET $($script:UpdateInfo.SetupUrl)"
        }
        catch {
            Write-Log "WARN" "Checksum mise à jour invalide : $(Get-DeepErrorMessage $_)"
            $script:UpdateStage = "Idle"
        }
        finally {
            $script:UpdateHashTask = $null
            Update-UpdateUi
        }
        return
    }

    if ($script:UpdateStage -eq "Binary" -and $script:UpdateBinaryTask -and $script:UpdateBinaryTask.IsCompleted) {
        try {
            [byte[]]$bytes = $script:UpdateBinaryTask.GetAwaiter().GetResult()
            if ($bytes.Length -lt 100000) {
                throw "Setup téléchargé anormalement petit."
            }

            $path = Join-Path $UpdateDir ([string]$script:UpdateInfo.SetupName)
            [IO.File]::WriteAllBytes($path, $bytes)

            if (Test-DownloadedUpdate -Path $path -ExpectedHash $script:UpdateExpectedHash) {
                $script:UpdateReadyPath = $path
                Write-Log "INFO" "Mise à jour prête : $path"
            }
            else {
                Remove-Item $path -Force -ErrorAction SilentlyContinue
                $script:UpdateReadyPath = $null
            }
        }
        catch {
            Write-Log "WARN" "Téléchargement mise à jour impossible : $(Get-DeepErrorMessage $_)"
        }
        finally {
            $script:UpdateBinaryTask = $null
            $script:UpdateStage = "Idle"
            Update-UpdateUi
        }

        if ($script:UpdateReadyPath -and [bool]$script:Settings.autoUpdate) {
            Invoke-SilentUpdate
        }
    }
}

function Remove-StaleUpdateFiles {
    try {
        $cutoff = [DateTime]::Now.AddDays(-1 * $UpdateRetentionDays)
        Get-ChildItem -Path $UpdateDir -File -Filter "WallhavenRotator-Setup-v*.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {}
}

Remove-StaleUpdateFiles

# HttpClient asynchrone.
$handler = New-Object System.Net.Http.HttpClientHandler

try {
    $handler.AutomaticDecompression = (
        [System.Net.DecompressionMethods]::GZip -bor
        [System.Net.DecompressionMethods]::Deflate
    )
} catch {}

try {
    $handler.UseProxy = $true
    $handler.Proxy = [System.Net.WebRequest]::DefaultWebProxy

    if ($handler.PSObject.Properties["DefaultProxyCredentials"]) {
        $handler.DefaultProxyCredentials = [System.Net.CredentialCache]::DefaultCredentials
    }
} catch {}

$script:HttpClient = New-Object System.Net.Http.HttpClient -ArgumentList $handler
$script:HttpClient.Timeout = [TimeSpan]::FromSeconds(65)

try {
    $script:HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd(
        ("WallhavenWallpaperRotator/{0}" -f $script:AppVersion)
    )
} catch {}

$script:Settings = Load-Settings
$script:Running = [bool]$script:Settings.autoRotation
$script:NextChange = $null
$script:State = "Idle"
$script:ApiTask = $null
$script:DownloadTask = $null
$script:Candidate = $null
$script:ApiUsedResolution = $true
$script:ApiAttempt = 0
$script:ApiCurrentPage = 1
$script:PagesTried = @()
$script:PageCeilings = @{}
$script:ApiQueryKey = $null
$script:PendingManual = $false
$script:HistoryIds = Load-WallpaperHistory
if ($null -eq $script:HistoryIds) {
    # Should not happen after Load-WallpaperHistory's -NoEnumerate return,
    # but keep startup resilient to future changes.
    $script:HistoryIds = New-Object 'System.Collections.Generic.List[string]'
}
$script:LastWallpaperId = $null
$script:LastWallpaperUrl = $null
$script:LastWallpaperFilePath = $null
$script:LastStatus = ""
$script:Exiting = $false
$script:UpdateStage = "Idle"
$script:UpdateCheckTask = $null
$script:UpdateHashTask = $null
$script:UpdateBinaryTask = $null
$script:UpdateInfo = $null
$script:UpdateExpectedHash = $null
$script:UpdateReadyPath = $null
$script:UpdateNotifiedVersion = [string]$script:Settings.lastNotifiedUpdate
$script:NextUpdateCheck = [DateTime]::Now.AddSeconds(5)

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Wallhaven Rotator"
    Width="560"
    SizeToContent="Height"
    MinHeight="430"
    MaxHeight="900"
    WindowStartupLocation="CenterScreen"
    WindowStyle="None"
    ResizeMode="NoResize"
    Background="#22282C"
    Foreground="#F4F7F5"
    FontFamily="Segoe UI"
    ShowInTaskbar="False">

    <Window.Resources>
        <SolidColorBrush x:Key="Accent" Color="#71D69A"/>
        <SolidColorBrush x:Key="AccentDim" Color="#3B8059"/>
        <SolidColorBrush x:Key="Panel" Color="#2B3237"/>
        <SolidColorBrush x:Key="Panel2" Color="#30383D"/>
        <SolidColorBrush x:Key="Stroke" Color="#465158"/>
        <SolidColorBrush x:Key="Muted" Color="#A8B1B5"/>

        <Style TargetType="Button">
            <Setter Property="Foreground" Value="#F4F7F5"/>
            <Setter Property="Background" Value="#343D42"/>
            <Setter Property="BorderBrush" Value="{StaticResource AccentDim}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="13,8"/>
            <Setter Property="Cursor" Value="Hand"/>
        </Style>

        <Style TargetType="ComboBox">
            <Setter Property="MinHeight" Value="32"/>
            <Setter Property="Padding" Value="8,3"/>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="MinHeight" Value="32"/>
            <Setter Property="Padding" Value="8,5"/>
        </Style>

        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="#F4F7F5"/>
        </Style>
    </Window.Resources>

    <Border BorderBrush="#4C585E"
            BorderThickness="1"
            CornerRadius="12"
            Background="#22282C">
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="48"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Grid x:Name="DragSurface"
                  Grid.Row="0"
                  Background="#252C30">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="42"/>
                </Grid.ColumnDefinitions>

                <StackPanel Orientation="Horizontal"
                            VerticalAlignment="Center"
                            Margin="16,0,0,0">
                    <Ellipse Width="9"
                             Height="9"
                             Fill="{StaticResource Accent}"
                             Margin="0,0,9,0"/>
                    <TextBlock Text="Wallhaven Rotator"
                               FontWeight="SemiBold"
                               FontSize="15"
                               VerticalAlignment="Center"/>
                    <TextBlock x:Name="VersionText" Text="v1.1.0"
                               Foreground="{StaticResource Muted}"
                               FontSize="11"
                               Margin="9,2,0,0"
                               VerticalAlignment="Center"/>
                </StackPanel>

                <Button x:Name="HideButton"
                        Grid.Column="1"
                        Content="×"
                        FontSize="18"
                        Padding="0"
                        Background="Transparent"
                        BorderThickness="0"/>
            </Grid>

            <StackPanel Grid.Row="1"
                        Margin="18">

                <Border Background="{StaticResource Panel}"
                        BorderBrush="{StaticResource Stroke}"
                        BorderThickness="1"
                        CornerRadius="10"
                        Padding="14">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <StackPanel>
                            <StackPanel Orientation="Horizontal">
                                <Ellipse x:Name="StateDot"
                                         Width="9"
                                         Height="9"
                                         Fill="{StaticResource Accent}"
                                         Margin="0,5,8,0"/>
                                <TextBlock x:Name="StateText"
                                           Text="Actif"
                                           FontWeight="SemiBold"
                                           FontSize="14"/>
                            </StackPanel>

                            <TextBlock x:Name="StatusText"
                                       Text="Initialisation..."
                                       Foreground="{StaticResource Muted}"
                                       FontSize="11.5"
                                       TextWrapping="Wrap"
                                       Margin="17,5,0,0"/>
                        </StackPanel>

                        <TextBlock x:Name="NextChangeText"
                                   Grid.Column="1"
                                   Foreground="{StaticResource Muted}"
                                   FontSize="11"
                                   VerticalAlignment="Center"
                                   Margin="15,0,0,0"/>
                    </Grid>
                </Border>

                <Border x:Name="UpdateBanner"
                        Visibility="Collapsed"
                        Background="#24372E"
                        BorderBrush="#478463"
                        BorderThickness="1"
                        CornerRadius="9"
                        Padding="12"
                        Margin="0,10,0,0">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <StackPanel>
                            <TextBlock x:Name="UpdateBannerTitle"
                                       Text="Mise à jour disponible"
                                       FontWeight="SemiBold"
                                       Foreground="#A9E9C3"/>
                            <TextBlock x:Name="UpdateBannerText"
                                       Text="Une nouvelle version est disponible."
                                       Foreground="{StaticResource Muted}"
                                       FontSize="10.5"
                                       Margin="0,3,8,0"
                                       TextWrapping="Wrap"/>
                        </StackPanel>
                        <Button x:Name="UpdateActionButton"
                                Grid.Column="1"
                                Content="Mettre à jour"
                                Padding="12,6"
                                VerticalAlignment="Center"/>
                    </Grid>
                </Border>

                <Grid Margin="0,15,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0">
                        <TextBlock Text="Sélection"
                                   Foreground="{StaticResource Muted}"
                                   FontSize="11"
                                   Margin="1,0,0,5"/>
                        <ComboBox x:Name="SortCombo"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2">
                        <TextBlock Text="Catégorie"
                                   Foreground="{StaticResource Muted}"
                                   FontSize="11"
                                   Margin="1,0,0,5"/>
                        <ComboBox x:Name="CategoryCombo"/>
                    </StackPanel>
                </Grid>

                <Grid Margin="0,13,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="12"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <StackPanel Grid.Column="0">
                        <TextBlock Text="Changer toutes les"
                                   Foreground="{StaticResource Muted}"
                                   FontSize="11"
                                   Margin="1,0,0,5"/>
                        <TextBox x:Name="IntervalText"/>
                    </StackPanel>

                    <StackPanel Grid.Column="2">
                        <TextBlock Text="Unité"
                                   Foreground="{StaticResource Muted}"
                                   FontSize="11"
                                   Margin="1,0,0,5"/>
                        <ComboBox x:Name="UnitCombo"/>
                    </StackPanel>
                </Grid>

                <CheckBox x:Name="AutoRotationCheck"
                          Content="Rotation automatique"
                          Margin="1,14,0,0"
                          IsChecked="True"/>

                <Grid Margin="0,14,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Button x:Name="ChangeNowButton"
                            Grid.Column="0"
                            Content="Changer maintenant"/>

                    <Button x:Name="PauseButton"
                            Grid.Column="2"
                            Content="Mettre en pause"/>
                </Grid>

                <Expander x:Name="AdvancedExpander"
                          Header="Options"
                          Margin="0,15,0,0"
                          Foreground="#F4F7F5">
                    <ScrollViewer x:Name="OptionsScrollViewer"
                                  VerticalScrollBarVisibility="Auto"
                                  HorizontalScrollBarVisibility="Disabled"
                                  PanningMode="VerticalOnly">
                    <Border Background="{StaticResource Panel2}"
                            BorderBrush="{StaticResource Stroke}"
                            BorderThickness="1"
                            CornerRadius="9"
                            Padding="13"
                            Margin="0,8,0,0">
                        <StackPanel>
                            <CheckBox x:Name="RunAtLogonCheck"
                                      Content="Lancer automatiquement avec Windows"/>

                            <TextBlock Text="Le démarrage utilise un lanceur silencieux : aucune fenêtre PowerShell ne doit rester ouverte."
                                       Foreground="{StaticResource Muted}"
                                       FontSize="10.5"
                                       TextWrapping="Wrap"
                                       Margin="22,6,0,0"/>

                            <Border Background="#293238"
                                    BorderBrush="{StaticResource Stroke}"
                                    BorderThickness="1"
                                    CornerRadius="8"
                                    Padding="10"
                                    Margin="0,12,0,0">
                                <StackPanel>
                                    <TextBlock Text="AFFICHAGE"
                                               Foreground="{StaticResource Accent}"
                                               FontWeight="SemiBold"
                                               FontSize="10"/>
                                    <Grid Margin="0,8,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="10"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Mode" Foreground="{StaticResource Muted}" FontSize="10" Margin="0,0,0,4"/>
                                            <ComboBox x:Name="ResolutionModeCombo"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="2">
                                            <TextBlock Text="Résolution personnalisée" Foreground="{StaticResource Muted}" FontSize="10" Margin="0,0,0,4"/>
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition Width="*"/>
                                                    <ColumnDefinition Width="24"/>
                                                    <ColumnDefinition Width="*"/>
                                                </Grid.ColumnDefinitions>
                                                <TextBox x:Name="CustomWidthText" Grid.Column="0"/>
                                                <TextBlock Grid.Column="1" Text="×" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{StaticResource Muted}"/>
                                                <TextBox x:Name="CustomHeightText" Grid.Column="2"/>
                                            </Grid>
                                        </StackPanel>
                                    </Grid>
                                    <Grid Margin="0,8,0,0">
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="10"/>
                                            <ColumnDefinition Width="*"/>
                                        </Grid.ColumnDefinitions>
                                        <StackPanel Grid.Column="0">
                                            <TextBlock Text="Correspondance" Foreground="{StaticResource Muted}" FontSize="10" Margin="0,0,0,4"/>
                                            <ComboBox x:Name="ResolutionMatchCombo"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="2">
                                            <TextBlock Text="Ratio" Foreground="{StaticResource Muted}" FontSize="10" Margin="0,0,0,4"/>
                                            <ComboBox x:Name="CustomRatioCombo"/>
                                        </StackPanel>
                                    </Grid>
                                    <TextBlock x:Name="ResolutionInfoText"
                                               Foreground="{StaticResource Muted}"
                                               FontSize="10.5"
                                               Margin="0,7,0,0"
                                               TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>

                            <Border Background="#293238"
                                    BorderBrush="{StaticResource Stroke}"
                                    BorderThickness="1"
                                    CornerRadius="8"
                                    Padding="10"
                                    Margin="0,9,0,0">
                                <StackPanel>
                                    <TextBlock Text="MISES À JOUR"
                                               Foreground="{StaticResource Accent}"
                                               FontWeight="SemiBold"
                                               FontSize="10"/>
                                    <CheckBox x:Name="CheckUpdatesCheck"
                                              Content="Vérifier automatiquement les nouvelles versions"
                                              Margin="0,8,0,0"/>
                                    <CheckBox x:Name="AutoUpdateCheck"
                                              Content="Installer automatiquement les mises à jour signées"
                                              Margin="0,6,0,0"/>
                                    <TextBlock x:Name="UpdateStateText"
                                               Text="Version installée"
                                               Foreground="{StaticResource Muted}"
                                               FontSize="10.5"
                                               Margin="22,6,0,0"/>
                                    <Button x:Name="CheckUpdateNowButton"
                                            Content="Vérifier maintenant"
                                            Margin="0,9,0,0"/>
                                </StackPanel>
                            </Border>

                            <TextBlock Text="Anti-répétition : 1 000 fonds mémorisés entre les redémarrages · sélection étendue sur plusieurs pages Wallhaven."
                                       Foreground="{StaticResource Muted}"
                                       FontSize="10.5"
                                       TextWrapping="Wrap"
                                       Margin="22,8,0,0"/>

                            <TextBlock Text="Cache local borné : 50 images maximum et 500 MiB maximum."
                                       Foreground="{StaticResource Muted}"
                                       FontSize="10.5"
                                       TextWrapping="Wrap"
                                       Margin="22,5,0,0"/>

                            <Grid Margin="0,12,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="8"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <Button x:Name="OpenLogsButton"
                                        Grid.Column="0"
                                        Content="Ouvrir les logs"/>

                                <Button x:Name="OpenFolderButton"
                                        Grid.Column="2"
                                        Content="Dossier de l'app"/>
                            </Grid>

                            <Button x:Name="CurrentWallpaperButton"
                                    Content="Voir le fond actuel sur Wallhaven"
                                    Margin="0,8,0,0"
                                    IsEnabled="False"/>
                        </StackPanel>
                    </Border>
                    </ScrollViewer>
                </Expander>

                <Grid Margin="0,16,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="10"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>

                    <Button x:Name="SaveButton"
                            Grid.Column="0"
                            Content="Enregistrer"/>

                    <Button x:Name="CloseButton"
                            Grid.Column="2"
                            Content="Fermer"/>
                </Grid>

                <TextBlock Text="Wallhaven public · SFW uniquement · aucun droit administrateur"
                           Foreground="#758087"
                           FontSize="10"
                           HorizontalAlignment="Center"
                           Margin="0,13,0,0"/>
            </StackPanel>
        </Grid>
    </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$DragSurface = $window.FindName("DragSurface")
$VersionText = $window.FindName("VersionText")
$HideButton = $window.FindName("HideButton")
$StateDot = $window.FindName("StateDot")
$StateText = $window.FindName("StateText")
$StatusText = $window.FindName("StatusText")
$NextChangeText = $window.FindName("NextChangeText")
$SortCombo = $window.FindName("SortCombo")
$CategoryCombo = $window.FindName("CategoryCombo")
$IntervalText = $window.FindName("IntervalText")
$UnitCombo = $window.FindName("UnitCombo")
$AutoRotationCheck = $window.FindName("AutoRotationCheck")
$ChangeNowButton = $window.FindName("ChangeNowButton")
$PauseButton = $window.FindName("PauseButton")
$AdvancedExpander = $window.FindName("AdvancedExpander")
$OptionsScrollViewer = $window.FindName("OptionsScrollViewer")
$UpdateBanner = $window.FindName("UpdateBanner")
$UpdateBannerTitle = $window.FindName("UpdateBannerTitle")
$UpdateBannerText = $window.FindName("UpdateBannerText")
$UpdateActionButton = $window.FindName("UpdateActionButton")
$RunAtLogonCheck = $window.FindName("RunAtLogonCheck")
$ResolutionModeCombo = $window.FindName("ResolutionModeCombo")
$ResolutionMatchCombo = $window.FindName("ResolutionMatchCombo")
$CustomWidthText = $window.FindName("CustomWidthText")
$CustomHeightText = $window.FindName("CustomHeightText")
$CustomRatioCombo = $window.FindName("CustomRatioCombo")
$ResolutionInfoText = $window.FindName("ResolutionInfoText")
$CheckUpdatesCheck = $window.FindName("CheckUpdatesCheck")
$AutoUpdateCheck = $window.FindName("AutoUpdateCheck")
$UpdateStateText = $window.FindName("UpdateStateText")
$CheckUpdateNowButton = $window.FindName("CheckUpdateNowButton")
$OpenLogsButton = $window.FindName("OpenLogsButton")
$OpenFolderButton = $window.FindName("OpenFolderButton")
$CurrentWallpaperButton = $window.FindName("CurrentWallpaperButton")
$SaveButton = $window.FindName("SaveButton")
$CloseButton = $window.FindName("CloseButton")
$VersionText.Text = "v$($script:AppVersion)"

foreach ($item in $SortNames) {
    [void]$SortCombo.Items.Add($item)
}
foreach ($item in $CategoryNames) {
    [void]$CategoryCombo.Items.Add($item)
}
foreach ($item in $UnitNames) {
    [void]$UnitCombo.Items.Add($item)
}
foreach ($item in $ResolutionModeNames) {
    [void]$ResolutionModeCombo.Items.Add($item)
}
foreach ($item in $ResolutionMatchNames) {
    [void]$ResolutionMatchCombo.Items.Add($item)
}
foreach ($item in $CustomRatioNames) {
    [void]$CustomRatioCombo.Items.Add($item)
}

function Set-Status {
    param([string]$Text)

    $script:LastStatus = $Text
    $StatusText.Text = $Text
}

function Update-OptionsViewport {
    try {
        $workArea = [System.Windows.SystemParameters]::WorkArea

        # Keep a small visible margin around the window and let only the
        # variable Options content scroll when vertical room is limited.
        $maxWindowHeight = [math]::Max(
            460.0,
            [double]$workArea.Height - 20.0
        )

        $window.MaxHeight = $maxWindowHeight

        # Roughly 500 DIPs are occupied by the title bar, main controls,
        # Options header, action buttons and footer. The remainder belongs
        # to the scrollable Options body.
        $optionsHeight = [math]::Max(
            140.0,
            $maxWindowHeight - 500.0
        )

        $OptionsScrollViewer.MaxHeight = $optionsHeight
    }
    catch {
        # Conservative fallback for unusual display/DPI environments.
        $window.MaxHeight = 900
        $OptionsScrollViewer.MaxHeight = 380
    }
}

function Refresh-ResolutionUi {
    $customEnabled = ([string]$ResolutionModeCombo.SelectedItem -eq "Personnalisé")

    $CustomWidthText.IsEnabled = $customEnabled
    $CustomHeightText.IsEnabled = $customEnabled
    $ResolutionMatchCombo.IsEnabled = $customEnabled
    $CustomRatioCombo.IsEnabled = $customEnabled

    try {
        if ($customEnabled) {
            $w = 0
            $h = 0
            if (
                [int]::TryParse([string]$CustomWidthText.Text, [ref]$w) -and
                [int]::TryParse([string]$CustomHeightText.Text, [ref]$h) -and
                $w -gt 0 -and
                $h -gt 0
            ) {
                $choice = [string]$CustomRatioCombo.SelectedItem
                $ratio = Convert-WallhavenRatioChoice -Choice $choice -Width $w -Height $h
                $match = if ($ResolutionMatchCombo.SelectedItem) {
                    [string]$ResolutionMatchCombo.SelectedItem
                } else {
                    "Au moins"
                }

                $ResolutionInfoText.Text = "Cible personnalisée : $w×$h · $($ratio.Replace('x', ':')) · $($match.ToLowerInvariant())"
            }
            else {
                $ResolutionInfoText.Text = "Saisissez une largeur et une hauteur valides."
            }
        }
        else {
            $screen = Get-PrimaryResolution
            $ratio = Get-WallhavenRatioForSize -Width $screen.Width -Height $screen.Height
            $ResolutionInfoText.Text = "Écran principal : $($screen.Width)×$($screen.Height) · $($ratio.Replace('x', ':')) · au moins"
        }
    }
    catch {
        $ResolutionInfoText.Text = "Filtre d'affichage indisponible."
    }
}

function Sync-UiFromSettings {
    $SortCombo.SelectedItem = [string]$script:Settings.sort
    $CategoryCombo.SelectedItem = [string]$script:Settings.category
    $IntervalText.Text = [string][int]$script:Settings.value
    $UnitCombo.SelectedItem = [string]$script:Settings.unit
    $AutoRotationCheck.IsChecked = [bool]$script:Settings.autoRotation
    $RunAtLogonCheck.IsChecked = Test-RunAtLogon
    $ResolutionModeCombo.SelectedItem = [string]$script:Settings.resolutionMode
    $ResolutionMatchCombo.SelectedItem = [string]$script:Settings.resolutionMatch
    $CustomWidthText.Text = [string][int]$script:Settings.customWidth
    $CustomHeightText.Text = [string][int]$script:Settings.customHeight
    $CustomRatioCombo.SelectedItem = [string]$script:Settings.customRatio
    $CheckUpdatesCheck.IsChecked = [bool]$script:Settings.checkUpdates
    $AutoUpdateCheck.IsChecked = [bool]$script:Settings.autoUpdate
    $AutoUpdateCheck.IsEnabled = [bool]$script:Settings.checkUpdates

    Refresh-ResolutionUi
    Update-UpdateUi
}

function Save-UiSettings {
    param([bool]$ShowValidation = $true)

    $value = 0
    if (
        -not [int]::TryParse([string]$IntervalText.Text, [ref]$value) -or
        $value -lt 1 -or
        $value -gt 999
    ) {
        if ($ShowValidation) {
            [System.Windows.MessageBox]::Show(
                "L'intervalle doit être compris entre 1 et 999.",
                "Wallhaven Rotator",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
        }
        return $false
    }

    if (
        $null -eq $SortCombo.SelectedItem -or
        $null -eq $CategoryCombo.SelectedItem -or
        $null -eq $UnitCombo.SelectedItem -or
        $null -eq $ResolutionModeCombo.SelectedItem -or
        $null -eq $ResolutionMatchCombo.SelectedItem -or
        $null -eq $CustomRatioCombo.SelectedItem
    ) {
        return $false
    }

    $customWidth = 0
    $customHeight = 0
    if ([string]$ResolutionModeCombo.SelectedItem -eq "Personnalisé") {
        if (
            -not [int]::TryParse([string]$CustomWidthText.Text, [ref]$customWidth) -or
            -not [int]::TryParse([string]$CustomHeightText.Text, [ref]$customHeight) -or
            $customWidth -lt 640 -or $customWidth -gt 15360 -or
            $customHeight -lt 480 -or $customHeight -gt 8640
        ) {
            if ($ShowValidation) {
                [System.Windows.MessageBox]::Show(
                    "La résolution personnalisée doit être comprise entre 640×480 et 15360×8640.",
                    "Wallhaven Rotator",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                ) | Out-Null
            }
            return $false
        }
    }
    else {
        $customWidth = [int]$script:Settings.customWidth
        $customHeight = [int]$script:Settings.customHeight
    }

    $script:Settings.sort = [string]$SortCombo.SelectedItem
    $script:Settings.category = [string]$CategoryCombo.SelectedItem
    $script:Settings.value = $value
    $script:Settings.unit = [string]$UnitCombo.SelectedItem
    $script:Settings.autoRotation = [bool]$AutoRotationCheck.IsChecked
    $script:Settings.resolutionMode = [string]$ResolutionModeCombo.SelectedItem
    $script:Settings.resolutionMatch = [string]$ResolutionMatchCombo.SelectedItem
    $script:Settings.customWidth = $customWidth
    $script:Settings.customHeight = $customHeight
    $script:Settings.customRatio = [string]$CustomRatioCombo.SelectedItem
    $script:Settings.checkUpdates = [bool]$CheckUpdatesCheck.IsChecked
    $script:Settings.autoUpdate = [bool]$AutoUpdateCheck.IsChecked

    $script:Running = [bool]$script:Settings.autoRotation
    Save-Settings

    Refresh-ResolutionUi

    if ([bool]$script:Settings.checkUpdates) {
        $script:NextUpdateCheck = [DateTime]::Now
    }
    else {
        $script:NextUpdateCheck = [DateTime]::MaxValue
    }

    $wantedAutostart = [bool]$RunAtLogonCheck.IsChecked
    if ($wantedAutostart -ne (Test-RunAtLogon)) {
        if (-not (Set-RunAtLogon -Enabled $wantedAutostart)) {
            $RunAtLogonCheck.IsChecked = Test-RunAtLogon
        }
    }

    if ($script:Running -and $script:State -eq "Idle") {
        Schedule-NextChange
    }
    elseif (-not $script:Running) {
        $script:NextChange = $null
    }

    return $true
}

function Show-SettingsWindow {
    Sync-UiFromSettings
    Update-OptionsViewport
    $window.ShowInTaskbar = $true
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
}

function Hide-SettingsWindow {
    $window.Hide()
    $window.ShowInTaskbar = $false
}

$AdvancedExpander.Add_Expanded({
    Update-OptionsViewport
})

$ResolutionModeCombo.Add_SelectionChanged({
    Refresh-ResolutionUi
})
$ResolutionMatchCombo.Add_SelectionChanged({
    Refresh-ResolutionUi
})
$CustomRatioCombo.Add_SelectionChanged({
    Refresh-ResolutionUi
})
$CustomWidthText.Add_TextChanged({
    Refresh-ResolutionUi
})
$CustomHeightText.Add_TextChanged({
    Refresh-ResolutionUi
})

$CheckUpdatesCheck.Add_Checked({
    $AutoUpdateCheck.IsEnabled = $true
})
$CheckUpdatesCheck.Add_Unchecked({
    $AutoUpdateCheck.IsEnabled = $false
})

$CheckUpdateNowButton.Add_Click({
    Start-UpdateCheck -Force
})

$UpdateActionButton.Add_Click({
    if ($script:UpdateReadyPath) {
        Invoke-SilentUpdate
    }
    elseif (
        $script:UpdateInfo -and
        $script:UpdateInfo.SignedAssetAvailable -and
        $script:UpdateInfo.HashAvailable
    ) {
        Start-UpdateDownload
    }
    elseif ($script:UpdateInfo -and $script:UpdateInfo.ReleaseUrl) {
        Start-Process ([string]$script:UpdateInfo.ReleaseUrl)
    }
    else {
        Start-Process $GitHubReleasesUrl
    }
})

$DragSurface.Add_MouseLeftButtonDown({
    try {
        if (
            [System.Windows.Input.Mouse]::LeftButton -eq
            [System.Windows.Input.MouseButtonState]::Pressed
        ) {
            $window.DragMove()
        }
    } catch {}
})

$HideButton.Add_Click({ Hide-SettingsWindow })
$CloseButton.Add_Click({ Hide-SettingsWindow })

$window.Add_Closing({
    param($sender, $e)

    if (-not $script:Exiting) {
        $e.Cancel = $true
        Hide-SettingsWindow
    }
})

# Systray.
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

$menuHeader = New-Object System.Windows.Forms.ToolStripMenuItem
$menuHeader.Text = "Wallhaven Rotator"
$menuHeader.Enabled = $false
[void]$trayMenu.Items.Add($menuHeader)

[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$menuChange = New-Object System.Windows.Forms.ToolStripMenuItem
$menuChange.Text = "Changer le fond maintenant"
[void]$trayMenu.Items.Add($menuChange)

$menuPause = New-Object System.Windows.Forms.ToolStripMenuItem
$menuPause.Text = "Mettre en pause"
[void]$trayMenu.Items.Add($menuPause)

$menuSettings = New-Object System.Windows.Forms.ToolStripMenuItem
$menuSettings.Text = "Paramètres..."
[void]$trayMenu.Items.Add($menuSettings)

[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$menuCurrent = New-Object System.Windows.Forms.ToolStripMenuItem
$menuCurrent.Text = "Voir le fond actuel sur Wallhaven"
$menuCurrent.Enabled = $false
[void]$trayMenu.Items.Add($menuCurrent)

$menuFolder = New-Object System.Windows.Forms.ToolStripMenuItem
$menuFolder.Text = "Ouvrir le dossier de l'application"
[void]$trayMenu.Items.Add($menuFolder)

$menuLog = New-Object System.Windows.Forms.ToolStripMenuItem
$menuLog.Text = "Ouvrir les logs"
[void]$trayMenu.Items.Add($menuLog)

[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$menuAutostart = New-Object System.Windows.Forms.ToolStripMenuItem
$menuAutostart.Text = "Lancer avec Windows"
$menuAutostart.CheckOnClick = $true
[void]$trayMenu.Items.Add($menuAutostart)

[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))

$menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
$menuExit.Text = "Quitter"
[void]$trayMenu.Items.Add($menuExit)

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Text = "Wallhaven Rotator"
$notifyIcon.ContextMenuStrip = $trayMenu

if (Test-Path $IconPath) {
    try {
        $script:TrayIconObject = New-Object System.Drawing.Icon -ArgumentList $IconPath
        $notifyIcon.Icon = $script:TrayIconObject
    }
    catch {
        $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
        Write-Log "WARN" "Icône systray non chargée : $($_.Exception.Message)"
    }
}
else {
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
}

$notifyIcon.Visible = $true

function Start-ApiRequest {
    param([bool]$UseResolution)

    try {
        $script:ApiAttempt++
        $url = Get-ApiUrl -UseResolution $UseResolution
        $script:ApiUsedResolution = $UseResolution
        $script:State = "Api"
        $script:ApiTask = $script:HttpClient.GetStringAsync($url)

        if ((Get-SelectionPageLimit) -gt 1) {
            Set-Status "Recherche Wallhaven · page $($script:ApiCurrentPage)..."
        }
        else {
            Set-Status "Recherche d'un fond sur Wallhaven..."
        }

        $target = Get-TargetDisplayFilter
        Write-Log "INFO" "API GET $url ; tentative=$($script:ApiAttempt) ; historique=$($script:HistoryIds.Count)/$HistoryMaxIds ; cible=$($target.Width)x$($target.Height) ratio=$($target.Ratio) mode=$($target.Source) match=$($target.MatchMode)"
    }
    catch {
        Handle-RequestFailure -Message (Get-DeepErrorMessage $_)
    }
}

function Retry-ApiSelection {
    param([string]$Reason)

    if ($script:ApiAttempt -lt $ApiSelectionAttemptsPerMode) {
        Write-Log "DEBUG" "Nouvel essai de sélection : $Reason"
        $script:ApiTask = $null
        $script:State = "Idle"
        Start-ApiRequest -UseResolution ([bool]$script:ApiUsedResolution)
        return $true
    }

    $target = Get-TargetDisplayFilter
    if (Test-ResolutionFallbackAllowed -Target $target -UseResolution ([bool]$script:ApiUsedResolution)) {
        Write-Log "INFO" "Sélection difficile avec résolution minimale ; nouvel essai sans minimum mais en conservant le ratio $($target.Ratio)."
        $script:ApiAttempt = 0
        $script:PagesTried = @()
        $script:ApiTask = $null
        $script:State = "Idle"
        Start-ApiRequest -UseResolution $false
        return $true
    }

    if ([bool]$target.IsExact) {
        Write-Log "INFO" "Mode résolution exacte : aucun élargissement automatique du filtre."
    }

    return $false
}

function Start-WallpaperChange {
    param(
        [ValidateSet("Auto", "Manual", "Startup")]
        [string]$Reason = "Auto"
    )

    if ($script:State -ne "Idle") {
        if ($Reason -eq "Manual") {
            $script:PendingManual = $true
            Set-Status "Un changement est déjà en cours ; demande mise en attente."
        }
        return
    }

    $script:ApiAttempt = 0
    $script:PagesTried = @()
    Start-ApiRequest -UseResolution $true
}

function Handle-RequestFailure {
    param([string]$Message)

    $script:State = "Idle"
    $script:ApiTask = $null
    $script:DownloadTask = $null
    $script:Candidate = $null

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "Erreur réseau inconnue."
    }

    Set-Status "Erreur : $Message"
    Write-Log "ERROR" $Message

    if ($script:Running) {
        # Au logon, le proxy / réseau d'entreprise peut ne pas être prêt.
        $script:NextChange = [DateTime]::Now.AddMinutes(1)
    }

    if ($script:PendingManual) {
        $script:PendingManual = $false
        Start-WallpaperChange -Reason "Manual"
    }
}

function Complete-Wallpaper {
    param(
        [string]$FilePath,
        $Candidate
    )

    try {
        Set-WindowsWallpaper -Path $FilePath

        $id = [string]$Candidate.id
        Add-WallpaperToHistory -Id $id

        $script:LastWallpaperId = $id
        if ($Candidate.url) {
            $script:LastWallpaperUrl = [string]$Candidate.url
        }
        else {
            $script:LastWallpaperUrl = "https://wallhaven.cc/w/$id"
        }

        $resolution = [string]$Candidate.resolution
        $category = [string]$Candidate.category

        $script:LastWallpaperFilePath = $FilePath
        Set-Status "Fond changé · $resolution · $category · $id"
        Write-Log "INFO" "Fond appliqué : $id $resolution $category"

        Trim-WallpaperCache -KeepPath $FilePath

        $script:State = "Idle"
        $script:Candidate = $null
        $script:DownloadTask = $null
        $script:ApiTask = $null

        if ($script:Running) {
            Schedule-NextChange
        }
        else {
            $script:NextChange = $null
        }

        $menuCurrent.Enabled = $true
        $CurrentWallpaperButton.IsEnabled = $true
    }
    catch {
        Handle-RequestFailure -Message (Get-DeepErrorMessage $_)
        return
    }

    if ($script:PendingManual) {
        $script:PendingManual = $false
        Start-WallpaperChange -Reason "Manual"
    }
}

function Process-AsyncState {
    if (
        $script:State -eq "Api" -and
        $null -ne $script:ApiTask -and
        $script:ApiTask.IsCompleted
    ) {
        try {
            $json = $script:ApiTask.GetAwaiter().GetResult()

            if ([string]::IsNullOrWhiteSpace($json)) {
                throw "Wallhaven a renvoyé une réponse vide."
            }

            $response = $json | ConvertFrom-Json
            $data = @($response.data)

            try {
                $lastPage = [int]$response.meta.last_page
                if ($script:ApiQueryKey -and $lastPage -gt 0) {
                    $script:PageCeilings[$script:ApiQueryKey] = $lastPage
                }
            } catch {}

            if ($data.Count -eq 0) {
                if (Retry-ApiSelection -Reason "page vide") {
                    return
                }

                throw "Wallhaven n'a trouvé aucun fond correspondant après plusieurs pages."
            }

            $available = @(
                $data |
                    Where-Object {
                        $script:HistoryIds -notcontains [string]$_.id
                    }
            )

            if ($available.Count -eq 0) {
                if (Retry-ApiSelection -Reason "page entièrement présente dans l'historique") {
                    return
                }

                # Si le pool choisi est réellement épuisé, on n'autorise qu'un
                # fond qui n'a pas été vu dans les 200 derniers changements.
                $recentGuard = @(Get-HistoryTail -Count $HistoryRecentFallbackIds)
                $available = @(
                    $data |
                        Where-Object {
                            $recentGuard -notcontains [string]$_.id
                        }
                )

                if ($available.Count -eq 0) {
                    $available = $data
                }

                Write-Log "WARN" "Pool inédit épuisé après plusieurs pages ; répétition ancienne autorisée (garde récente=$HistoryRecentFallbackIds)."
            }

            $candidate = Get-Random -InputObject $available
            $script:Candidate = $candidate

            $imageUri = [Uri]::new([string]$candidate.path)
            $ext = [IO.Path]::GetExtension($imageUri.AbsolutePath).ToLowerInvariant()

            if ($ext -notin @(".jpg", ".jpeg", ".png")) {
                if ([string]$candidate.file_type -eq "image/png") {
                    $ext = ".png"
                }
                else {
                    $ext = ".jpg"
                }
            }

            $filePath = Join-Path $CacheDir (
                "wallhaven-{0}{1}" -f $candidate.id, $ext
            )

            $script:Candidate |
                Add-Member `
                    -NotePropertyName LocalFilePath `
                    -NotePropertyValue $filePath `
                    -Force

            if (Test-Path $filePath) {
                try {
                    (Get-Item $filePath).LastWriteTime = [DateTime]::Now
                } catch {}

                Write-Log "INFO" "CACHE HIT $($candidate.id) -> $filePath"
                $script:State = "Idle"
                $script:ApiTask = $null
                Complete-Wallpaper `
                    -FilePath $filePath `
                    -Candidate $candidate
                return
            }

            Set-Status "Téléchargement de $($candidate.resolution)..."
            Write-Log "INFO" "CACHE MISS $($candidate.id) ; IMAGE GET $($candidate.path)"

            $script:DownloadTask = $script:HttpClient.GetByteArrayAsync(
                [string]$candidate.path
            )

            $script:ApiTask = $null
            $script:State = "Download"
        }
        catch {
            Handle-RequestFailure -Message (Get-DeepErrorMessage $_)
        }

        return
    }

    if (
        $script:State -eq "Download" -and
        $null -ne $script:DownloadTask -and
        $script:DownloadTask.IsCompleted
    ) {
        try {
            [byte[]]$bytes = $script:DownloadTask.GetAwaiter().GetResult()

            if ($bytes.Length -lt 10240) {
                throw "Le fichier reçu est anormalement petit ($($bytes.Length) octets)."
            }

            if (-not (Test-ImageBytes -Bytes $bytes)) {
                throw "Le serveur n'a pas renvoyé une image JPEG/PNG valide."
            }

            $filePath = [string]$script:Candidate.LocalFilePath
            $tempPath = "$filePath.download"

            [IO.File]::WriteAllBytes($tempPath, $bytes)
            Move-Item -Path $tempPath -Destination $filePath -Force

            $script:DownloadTask = $null
            $script:State = "Idle"

            Complete-Wallpaper `
                -FilePath $filePath `
                -Candidate $script:Candidate
        }
        catch {
            try {
                if (
                    $script:Candidate -and
                    $script:Candidate.LocalFilePath
                ) {
                    Remove-Item `
                        "$($script:Candidate.LocalFilePath).download" `
                        -Force `
                        -ErrorAction SilentlyContinue
                }
            } catch {}

            Handle-RequestFailure -Message (Get-DeepErrorMessage $_)
        }
    }
}

function Pause-Rotation {
    $script:Running = $false
    $script:Settings.autoRotation = $false
    $script:NextChange = $null
    Save-Settings
    Set-Status "Rotation en pause. Le fond actuel est conservé."
}

function Resume-Rotation {
    $script:Running = $true
    $script:Settings.autoRotation = $true
    Save-Settings
    Set-Status "Rotation reprise."
    Start-WallpaperChange -Reason "Manual"
}

function Toggle-Pause {
    if ($script:Running) {
        Pause-Rotation
    }
    else {
        Resume-Rotation
    }
}

function Update-UiState {
    $activeBrush = [Windows.Media.SolidColorBrush]::new(
        [Windows.Media.Color]::FromRgb(113, 214, 154)
    )
    $pausedBrush = [Windows.Media.SolidColorBrush]::new(
        [Windows.Media.Color]::FromRgb(229, 184, 92)
    )
    $busyBrush = [Windows.Media.SolidColorBrush]::new(
        [Windows.Media.Color]::FromRgb(114, 167, 255)
    )

    if ($script:State -ne "Idle") {
        $StateText.Text = "En cours"
        $StateText.Foreground = $busyBrush
        $StateDot.Fill = $busyBrush
        $notifyIcon.Text = "Wallhaven Rotator - téléchargement"
    }
    elseif ($script:Running) {
        $StateText.Text = "Actif"
        $StateText.Foreground = $activeBrush
        $StateDot.Fill = $activeBrush
        $notifyIcon.Text = "Wallhaven Rotator - actif"
    }
    else {
        $StateText.Text = "En pause"
        $StateText.Foreground = $pausedBrush
        $StateDot.Fill = $pausedBrush
        $notifyIcon.Text = "Wallhaven Rotator - pause"
    }

    if ($script:Running) {
        $PauseButton.Content = "Mettre en pause"
        $menuPause.Text = "Mettre en pause"
    }
    else {
        $PauseButton.Content = "Reprendre"
        $menuPause.Text = "Reprendre"
    }

    $menuAutostart.Checked = Test-RunAtLogon

    if (
        $script:Running -and
        $null -ne $script:NextChange
    ) {
        $remaining = $script:NextChange - [DateTime]::Now

        if ($remaining.TotalSeconds -le 0) {
            $NextChangeText.Text = "maintenant"
        }
        elseif ($remaining.TotalMinutes -lt 1) {
            $NextChangeText.Text = "{0}s" -f [math]::Ceiling($remaining.TotalSeconds)
        }
        elseif ($remaining.TotalHours -lt 1) {
            $NextChangeText.Text = "{0} min" -f [math]::Ceiling($remaining.TotalMinutes)
        }
        else {
            $NextChangeText.Text = $script:NextChange.ToString("HH:mm")
        }
    }
    elseif ($script:Running) {
        $NextChangeText.Text = Format-Interval
    }
    else {
        $NextChangeText.Text = "pause"
    }

    Update-UpdateUi
}

$ChangeNowButton.Add_Click({
    Start-WallpaperChange -Reason "Manual"
})

$PauseButton.Add_Click({
    Toggle-Pause
    Sync-UiFromSettings
})

$SaveButton.Add_Click({
    if (Save-UiSettings -ShowValidation $true) {
        Set-Status "Paramètres enregistrés."
        Update-UiState
    }
})

$OpenLogsButton.Add_Click({
    Start-Process explorer.exe -ArgumentList "`"$LogDir`""
})

$OpenFolderButton.Add_Click({
    Start-Process explorer.exe -ArgumentList "`"$BaseDir`""
})

$CurrentWallpaperButton.Add_Click({
    if ($script:LastWallpaperUrl) {
        Start-Process $script:LastWallpaperUrl
    }
})

$menuChange.Add_Click({
    Start-WallpaperChange -Reason "Manual"
})

$menuPause.Add_Click({
    Toggle-Pause
    Sync-UiFromSettings
})

$menuSettings.Add_Click({
    Show-SettingsWindow
})

$menuCurrent.Add_Click({
    if ($script:LastWallpaperUrl) {
        Start-Process $script:LastWallpaperUrl
    }
})

$menuFolder.Add_Click({
    Start-Process explorer.exe -ArgumentList "`"$BaseDir`""
})

$menuLog.Add_Click({
    Start-Process explorer.exe -ArgumentList "`"$LogDir`""
})

$menuAutostart.Add_Click({
    $wanted = [bool]$menuAutostart.Checked

    if (-not (Set-RunAtLogon -Enabled $wanted)) {
        $menuAutostart.Checked = -not $wanted
    }

    $RunAtLogonCheck.IsChecked = Test-RunAtLogon
})

$notifyIcon.Add_DoubleClick({
    Show-SettingsWindow
})

$menuExit.Add_Click({
    $script:Exiting = $true

    try { $script:Timer.Stop() } catch {}

    try {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    } catch {}

    try {
        if ($script:TrayIconObject) {
            $script:TrayIconObject.Dispose()
        }
    } catch {}

    try { $script:HttpClient.Dispose() } catch {}
    try { $handler.Dispose() } catch {}

    try {
        $script:Mutex.ReleaseMutex()
        $script:Mutex.Dispose()
    } catch {}

    try { $window.Close() } catch {}

    [System.Windows.Application]::Current.Shutdown()
})

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(300)

$script:Timer.Add_Tick({
    Process-AsyncState
    Process-UpdateState

    if (
        [bool]$script:Settings.checkUpdates -and
        $script:UpdateStage -eq "Idle" -and
        [DateTime]::Now -ge $script:NextUpdateCheck
    ) {
        Start-UpdateCheck
    }

    if (Test-Path $ShowRequestPath) {
        try {
            Remove-Item `
                $ShowRequestPath `
                -Force `
                -ErrorAction SilentlyContinue
        } catch {}

        Show-SettingsWindow
    }

    if (
        $script:Running -and
        $script:State -eq "Idle" -and
        $null -ne $script:NextChange -and
        [DateTime]::Now -ge $script:NextChange
    ) {
        Start-WallpaperChange -Reason "Auto"
    }

    Update-UiState
})

Sync-UiFromSettings
Set-Status "Initialisation..."
Update-UiState
$script:Timer.Start()

$startupMethod = try {
    (Get-ItemProperty `
        -Path $RunKey `
        -Name $RunValueName `
        -ErrorAction Stop).$RunValueName
} catch {
    "<aucun>"
}

$startupTarget = Get-TargetDisplayFilter
Write-Log "INFO" (
    "Wallhaven Rotator v{0} démarré. Auto={1}; PID={2}; Run={3}; historique={4}/{5}; cacheMax={6} fichiers/{7} MiB; cible={8}x{9}; ratio={10}; match={11}; updates={12}; autoUpdate={13}" -f `
    $script:AppVersion,
    [bool]$Autostart,
    $PID,
    $startupMethod,
    $script:HistoryIds.Count,
    $HistoryMaxIds,
    $CacheMaxFiles,
    [int]($CacheMaxBytes / 1MB),
    $startupTarget.Width,
    $startupTarget.Height,
    $startupTarget.Ratio,
    $startupTarget.MatchMode,
    [bool]$script:Settings.checkUpdates,
    [bool]$script:Settings.autoUpdate
)

if ($script:Running) {
    Start-WallpaperChange -Reason "Startup"
}
else {
    Set-Status "Rotation en pause."
}

if (-not $Autostart) {
    Show-SettingsWindow
}

$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
[void]$app.Run()
