param(
    [switch]$Autostart
)

# Wallhaven Rotator
# Version épurée : rotation du wallpaper Wallhaven uniquement.

$ErrorActionPreference = "Stop"
$script:AppVersion = "1.2.0"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

$SharedPolicyPath = Join-Path $PSScriptRoot "Wallhaven-SharedPolicy.ps1"
if (-not (Test-Path $SharedPolicyPath)) {
    throw "Module Wallhaven-SharedPolicy.ps1 introuvable."
}
. $SharedPolicyPath

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
$MetadataCachePath = Join-Path $BaseDir "metadata-cache.json"
$SearchCachePath = Join-Path $BaseDir "search-cache.json"
$ShowRequestPath = Join-Path $BaseDir "show.request"
$UpdateDir = Join-Path $BaseDir "updates"

$IconPath = Join-Path $PSScriptRoot "Wallhaven-Rotator.ico"
$LauncherPath = Join-Path $PSScriptRoot "Wallhaven-Rotator-Launcher.vbs"
$WScriptPath = Join-Path $env:WINDIR "System32\wscript.exe"

$ApiBase = "https://wallhaven.cc/api/v1/search"
$GitHubLatestReleaseApi = "https://api.github.com/repos/tadikwa/Wallhaven-Rotator/releases/latest"
$GitHubReleasesUrl = "https://github.com/tadikwa/Wallhaven-Rotator/releases"
$UpdateCheckInterval = [TimeSpan]::FromHours(6)
$UpdateRetentionDays = 7
$LogRetentionDays = 7
$LogMaxBytes = 2097152

# Anti-répétition / cache.
# L'historique global est partagé avec Wallhaven Screensaver et stocke les
# 5 000 derniers IDs + timestamp. seenToday est une exclusion absolue.
$HistoryMaxIds = 5000
$CacheMaxFiles = 50
$CacheMaxBytes = 524288000  # 500 MiB
$ApiSelectionAttemptsPerMode = 4
$MetadataChecksPerSelection = 6
$SearchRequestsPerSelection = 2
$MetadataCacheMaxEntries = 1200
$MetadataCacheMaxAgeDays = 7

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
$ContentFilterNames = @("Standard", "Reduced", "Strict")

function Get-DefaultSettings {
    [pscustomobject]@{
        sort = "Aléatoire"
        category = "Toutes"
        query = ""
        contentFilter = "Reduced"
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

        $query = if ($null -eq $old.query) { "" } else { [string]$old.query }
        $contentFilter = if ([string]$old.contentFilter -in $ContentFilterNames) {
            [string]$old.contentFilter
        } else {
            $defaults.contentFilter
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
            query = $query
            contentFilter = $contentFilter
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
            query = [string]$script:Settings.query
            contentFilter = [string]$script:Settings.contentFilter
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

function Get-SharedHistoryOrderedIds {
    $snapshot = Get-SharedHistorySnapshot
    return @(
        $snapshot.LastShown.GetEnumerator() |
            Sort-Object Value |
            ForEach-Object { [string]$_.Key }
    )
}

function Load-WallpaperHistory {
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in @(Get-SharedHistoryOrderedIds)) {
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            [void]$list.Add($id)
        }
    }
    Write-Output -NoEnumerate $list
}

function Refresh-SharedHistoryView {
    $script:SharedHistorySnapshot = Get-SharedHistorySnapshot
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in @(
        $script:SharedHistorySnapshot.LastShown.GetEnumerator() |
            Sort-Object Value
    )) {
        [void]$list.Add([string]$entry.Key)
    }
    $script:HistoryIds = $list
}

function Save-WallpaperHistory {
    # Compatibility shim. Shared history persists atomically on commit/release.
}

function Add-WallpaperToHistory {
    param([string]$Id)
    if (-not [string]::IsNullOrWhiteSpace($Id)) {
        Commit-SharedWallpaperShown -Id $Id
        Refresh-SharedHistoryView
    }
}

function Get-HistoryTail {
    param([int]$Count)
    $ordered = @(Get-SharedHistoryOrderedIds)
    if ($Count -le 0 -or $ordered.Count -eq 0) { return @() }
    $start = [math]::Max(0, $ordered.Count - $Count)
    return @($ordered[$start..($ordered.Count - 1)])
}


# Store raw Wallhaven tags/category, not a previous Strict verdict. On each
# cache hit the CURRENT content policy is evaluated. A stale entry is ignored.
function Load-MetadataCache {
    $script:MetadataCache = @{}
    $script:MetadataCacheDirty = $false
    if (-not (Test-Path $MetadataCachePath)) { return }

    try {
        $data = Get-Content -Path $MetadataCachePath -Raw | ConvertFrom-Json
        if ([int]$data.schema -ne 1) { return }
        $cutoff = [DateTime]::UtcNow.AddDays(-1 * $MetadataCacheMaxAgeDays)
        foreach ($entry in @($data.entries | Sort-Object checkedAt -Descending)) {
            $id = [string]$entry.id
            $checked = [DateTime]::MinValue
            if (
                [string]::IsNullOrWhiteSpace($id) -or
                -not [DateTime]::TryParse([string]$entry.checkedAt, [ref]$checked) -or
                $checked.ToUniversalTime() -lt $cutoff -or
                $checked.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5) -or
                [string]$entry.category -notin @('general', 'anime', 'people') -or
                $entry.tags -isnot [array] -or
                @($entry.tags | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
            ) { continue }
            $script:MetadataCache[$id] = [pscustomobject]@{
                id = $id
                category = [string]$entry.category
                tags = @($entry.tags | ForEach-Object { [string]$_ })
                checkedAt = $checked.ToUniversalTime().ToString("o")
                candidate = $entry.candidate
                selectionKey = [string]$entry.selectionKey
            }
            if ($script:MetadataCache.Count -ge $MetadataCacheMaxEntries) { break }
        }
    }
    catch {
        Write-Log "WARN" "Cache de métadonnées illisible ; vérifications réseau conservées : $($_.Exception.Message)"
        $script:MetadataCache = @{}
    }
}

function Get-CachedContentDecision {
    param([string]$Id, [string]$Mode)
    if (-not $script:MetadataCache.ContainsKey($Id)) { return $null }

    $entry = $script:MetadataCache[$Id]
    $checked = [DateTime]::MinValue
    if (
        -not [DateTime]::TryParse([string]$entry.checkedAt, [ref]$checked) -or
        $checked.ToUniversalTime() -lt [DateTime]::UtcNow.AddDays(-1 * $MetadataCacheMaxAgeDays) -or
        $checked.ToUniversalTime() -gt [DateTime]::UtcNow.AddMinutes(5)
    ) {
        [void]$script:MetadataCache.Remove($Id)
        $script:MetadataCacheDirty = $true
        return $null
    }
    return (Get-ContentFilterDecision -WallhavenCategory ([string]$entry.category) -Tags @($entry.tags) -Mode $Mode)
}

function Remember-WallhavenMetadata {
    param([string]$Id, [string]$Category, [string[]]$Tags)
    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Category)) { return }
    $script:MetadataCache[$Id] = [pscustomobject]@{
        id = $Id
        category = $Category
        tags = @($Tags)
        checkedAt = [DateTime]::UtcNow.ToString("o")
    }
    $script:MetadataCacheDirty = $true
}

function Save-MetadataCache {
    if (-not $script:MetadataCacheDirty) { return }
    try {
        $cutoff = [DateTime]::UtcNow.AddDays(-1 * $MetadataCacheMaxAgeDays)
        $valid = @(
            $script:MetadataCache.Values |
                Where-Object {
                    $checked = [DateTime]::MinValue
                    [DateTime]::TryParse([string]$_.checkedAt, [ref]$checked) -and
                    $checked.ToUniversalTime() -ge $cutoff
                } |
                Sort-Object checkedAt -Descending |
                Select-Object -First $MetadataCacheMaxEntries
        )
        $content = ConvertTo-Json -InputObject ([pscustomobject]@{
            schema = 1
            entries = $valid
        }) -Depth 6
        # The single-instance mutex owns this cache; replace atomically so a
        # crash cannot truncate the last usable offline metadata.
        $tmp = "$MetadataCachePath.$([guid]::NewGuid().ToString('N')).tmp"
        $backup = "$tmp.bak"
        try {
            [IO.File]::WriteAllText($tmp, $content, (New-Object Text.UTF8Encoding($true)))
            if (Test-Path $MetadataCachePath) {
                [IO.File]::Replace($tmp, $MetadataCachePath, $backup, $true)
            }
            else { [IO.File]::Move($tmp, $MetadataCachePath) }
        }
        finally {
            Remove-Item -LiteralPath $tmp, $backup -Force -ErrorAction SilentlyContinue
        }
        $script:MetadataCache = @{}
        foreach ($entry in $valid) { $script:MetadataCache[[string]$entry.id] = $entry }
        $script:MetadataCacheDirty = $false
    }
    catch {
        Write-Log "WARN" "Impossible de sauvegarder le cache de métadonnées : $($_.Exception.Message)"
    }
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
    param(
        [bool]$UseResolution,
        [bool]$UsePolicyQuery = $true
    )

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

    $query = if ($UsePolicyQuery) {
        Get-EffectiveWallhavenQuery `
            -UserQuery ([string]$script:Settings.query) `
            -Mode ([string]$script:Settings.contentFilter)
    } else {
        ([string]$script:Settings.query).Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($query)) {
        $params["q"] = $query
    }

    $target = Get-TargetDisplayFilter
    $resolutionParams = Get-ResolutionQueryParameters `
        -Target $target `
        -UseResolution $UseResolution

    foreach ($key in $resolutionParams.Keys) {
        $params[$key] = [string]$resolutionParams[$key]
    }

    $script:ApiQueryKey = "{0}|{1}|{2}|{3}|{4}|{5}|{6}|policy{7}|{8}x{9}" -f `
        [string]$script:Settings.sort,
        [string]$script:Settings.category,
        [string]$script:Settings.query,
        [string]$script:Settings.contentFilter,
        [string]$target.Ratio,
        [string]$target.MatchMode,
        [bool]$UseResolution,
        $script:WallhavenContentFilterPolicyVersion,
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

function Get-SetupAssetName {
    param([string]$Version)
    return "WallhavenRotator-Setup-v$Version.exe"
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

        if ($script:UpdateInfo.SetupAssetAvailable) {
            if (-not $script:UpdateInfo.HashAvailable) {
                $UpdateBannerText.Text = "Setup disponible, mais somme SHA-256 absente : installation automatique désactivée."
                $UpdateActionButton.Content = "Voir la release"
            }
            elseif ($script:UpdateReadyPath) {
                $UpdateBannerText.Text = "Setup vérifié par SHA-256 et prêt à installer."
                $UpdateActionButton.Content = "Installer"
            }
            elseif ($script:UpdateStage -in @("Hash", "Binary")) {
                $UpdateBannerText.Text = "Téléchargement et vérification en cours…"
                $UpdateActionButton.Content = "Patientez…"
            }
            else {
                $UpdateBannerText.Text = "Setup publié ; cliquez pour le télécharger et vérifier son SHA-256."
                $UpdateActionButton.Content = "Mettre à jour"
            }
        }
        else {
            $UpdateBannerText.Text = "La release existe, mais aucun setup compatible n'est disponible."
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
            $updateAssetText = if (-not $script:UpdateInfo.SetupAssetAvailable) {
                "setup indisponible"
            }
            elseif (-not $script:UpdateInfo.HashAvailable) {
                "setup · checksum absent"
            }
            elseif ($script:UpdateReadyPath) {
                "setup vérifié"
            }
            else {
                "setup signé à vérifier"
            }
            $UpdateStateText.Text = "Disponible : $($script:UpdateInfo.Version) · $updateAssetText"
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
    if ($null -eq $script:UpdateInfo -or -not $script:UpdateInfo.SetupAssetAvailable) {
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

    try {
        if (
            [string]::IsNullOrWhiteSpace($Path) -or
            -not (Test-Path $Path) -or
            [string]::IsNullOrWhiteSpace($ExpectedHash)
        ) {
            Write-Log "WARN" "Mise à jour rejetée : fichier ou SHA-256 attendu absent."
            return $false
        }

        $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $ExpectedHash.ToLowerInvariant()) {
            Write-Log "ERROR" "Mise à jour rejetée : SHA-256 inattendu ($actual)."
            return $false
        }

        Write-Log "INFO" "Mise à jour vérifiée par SHA-256 : $actual"
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
        # Flush the currently displayed controls before handing off to the
        # updater. This protects selections changed just before an OTA.
        try {
            if (-not (Save-UiSettings -ShowValidation $false)) {
                Write-Log "WARN" "Mise à jour : état UI non persisté car une valeur affichée est invalide."
            }
        }
        catch {
            Write-Log "WARN" "Mise à jour : sauvegarde UI impossible : $(Get-DeepErrorMessage $_)"
        }

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

                $setupName = Get-SetupAssetName -Version $version
                $setupAsset = @($release.assets | Where-Object { [string]$_.name -eq $setupName } | Select-Object -First 1)
                $hashAsset = @($release.assets | Where-Object { [string]$_.name -eq "SHA256SUMS.txt" } | Select-Object -First 1)

                $script:UpdateInfo = [pscustomobject]@{
                    Version = $version
                    ReleaseUrl = [string]$release.html_url
                    SetupAssetAvailable = ($setupAsset.Count -gt 0)
                    HashAvailable = ($hashAsset.Count -gt 0)
                    SetupUrl = if ($setupAsset.Count -gt 0) { [string]$setupAsset[0].browser_download_url } else { $null }
                    HashUrl = if ($hashAsset.Count -gt 0) { [string]$hashAsset[0].browser_download_url } else { $null }
                    SetupName = $setupName
                }

                Write-Log "INFO" "Mise à jour détectée : $version ; setup=$($script:UpdateInfo.SetupAssetAvailable) ; checksum=$($script:UpdateInfo.HashAvailable)"
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
            $script:UpdateInfo.SetupAssetAvailable -and
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
Load-MetadataCache
$script:Running = [bool]$script:Settings.autoRotation
$script:NextChange = $null
$script:State = "Idle"
$script:ApiTask = $null
$script:DownloadTask = $null
$script:MetadataTask = $null
$script:Candidate = $null
$script:CandidateQueue = @()
$script:ReservedCandidateId = $null
$script:MetadataChecks = 0
$script:ApiRetryAfter = $null
$script:ApiSelectionKey = ""
$script:OfflineSelection = $false
$script:DeferredApiRequest = $null
$script:SelectionSearches = 0
$script:SelectionSeenIds = @{}
$script:SelectionUrls = @{}
$script:AllowRecentHistoryRecycle = $false
$script:ApiUsePolicyQuery = $true
$script:CandidateDiagnostics = [ordered]@{
    daily = 0
    recent = 0
    pending = 0
    strict = 0
    accepted = 0
}
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
                                    <TextBlock Text="CONTENU WALLHAVEN"
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
                                            <TextBlock Text="Filtrage" Foreground="{StaticResource Muted}" FontSize="10" Margin="0,0,0,4"/>
                                            <ComboBox x:Name="ContentFilterCombo"/>
                                        </StackPanel>
                                        <StackPanel Grid.Column="2">
                                            <TextBlock Text="Requête Wallhaven" Foreground="{StaticResource Muted}" FontSize="10" Margin="0,0,0,4"/>
                                            <TextBox x:Name="QueryText"/>
                                        </StackPanel>
                                    </Grid>
                                    <TextBlock Text="Strict est volontairement conservateur et utilise les tags/métadonnées Wallhaven ; il ne s'agit pas de reconnaissance d'image."
                                               Foreground="{StaticResource Muted}"
                                               FontSize="10"
                                               TextWrapping="Wrap"
                                               Margin="0,7,0,0"/>
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
                                              Content="Installer automatiquement les mises à jour"
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

                            <TextBlock x:Name="AntiRepeatStatsText"
                                       Text="Anti-répétition : initialisation…"
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
$ContentFilterCombo = $window.FindName("ContentFilterCombo")
$QueryText = $window.FindName("QueryText")
$AntiRepeatStatsText = $window.FindName("AntiRepeatStatsText")
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
foreach ($item in $ContentFilterNames) {
    [void]$ContentFilterCombo.Items.Add($item)
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
    $QueryText.Text = [string]$script:Settings.query
    $ContentFilterCombo.SelectedItem = [string]$script:Settings.contentFilter
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
        $null -eq $ContentFilterCombo.SelectedItem -or
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
    $script:Settings.query = [string]$QueryText.Text
    $script:Settings.contentFilter = [string]$ContentFilterCombo.SelectedItem
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

function Refresh-DiagnosticsUi {
    try {
        $snapshot = Get-SharedHistorySnapshot
        $cacheCount = @(
            Get-ChildItem -Path $CacheDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "wallhaven-*" }
        ).Count

        $AntiRepeatStatsText.Text = (
            "Anti-répétition globale : aujourd'hui={0} · historique={1}/{2} · cache={3} · rejets jour={4} · récents={5} · pending={6} · Strict={7}" -f
            $snapshot.SeenTodayCount,
            $snapshot.HistoryCount,
            $HistoryMaxIds,
            $cacheCount,
            [int]$script:CandidateDiagnostics.daily,
            [int]$script:CandidateDiagnostics.recent,
            [int]$script:CandidateDiagnostics.pending,
            [int]$script:CandidateDiagnostics.strict
        )
    }
    catch {
        $AntiRepeatStatsText.Text = "Anti-répétition globale : diagnostic indisponible."
    }
}

function Show-SettingsWindow {
    Sync-UiFromSettings
    Refresh-DiagnosticsUi
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
        $script:UpdateInfo.SetupAssetAvailable -and
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

function Initialize-SelectionCycle {
    Stop-SelectionRequests
    $script:SelectionCancellation = New-Object Threading.CancellationTokenSource
    $script:SelectionSearches = 0
    $script:MetadataChecks = 0
    $script:SelectionSeenIds = @{}
    $script:SelectionUrls = @{}
    $script:DeferredApiRequest = $null
    $script:ApiCachedJson = $null
    $script:SelectionDeadline = (Get-SharedHistoryNow).AddSeconds(45)
    $script:SelectionSummaryWritten = $false
    $script:SelectionStats = [pscustomobject]@{
        started=(Get-SharedHistoryNow); searches=0; metadata=0; metadataHits=0;
        searchHits=0; localHits=0; rejected=@{}; samples=@()
    }
}

function Stop-SelectionRequests {
    if ($script:SelectionCancellation) {
        try { $script:SelectionCancellation.Cancel() }
        catch { Write-Log 'WARN' "Annulation de sélection : $($_.Exception.Message)" }
        finally { $script:SelectionCancellation.Dispose(); $script:SelectionCancellation = $null }
    }
}

function Write-SelectionSummary {
    param([string]$Outcome)
    if (-not $script:SelectionStats -or $script:SelectionSummaryWritten) { return }
    $script:SelectionSummaryWritten = $true
    $s = $script:SelectionStats
    $rejected = @($s.rejected.Keys | Sort-Object | ForEach-Object { "$_=$($s.rejected[$_])" }) -join ','
    Write-Log 'INFO' ("selection.summary outcome=$Outcome search=$($s.searches) metadata=$($s.metadata) metadata_cache=$($s.metadataHits) search_cache=$($s.searchHits) local=$($s.localHits) elapsed_ms=$([math]::Round(((Get-SharedHistoryNow)-$s.started).TotalMilliseconds)) rejected=[$rejected] samples=[$($s.samples -join ',')]")
}

function Load-SearchCache {
    $script:SearchCache = @{}
    $script:SearchCacheDirty = $false
    if (-not (Test-Path -LiteralPath $SearchCachePath)) { return }
    try {
        if ((Get-Item -LiteralPath $SearchCachePath).Length -gt 4194304) { return }
        $data = Get-Content -LiteralPath $SearchCachePath -Raw | ConvertFrom-Json
        if ([int]$data.schema -ne 1) { return }
        foreach ($entry in @($data.entries | Sort-Object checkedAt -Descending | Select-Object -First 16)) {
            $at = ConvertTo-SharedDateTimeOffset $entry.checkedAt
            if ($at -and $at -ge (Get-SharedHistoryNow).AddMinutes(-15) -and $at -le (Get-SharedHistoryNow) -and $entry.url -and $entry.selectionKey -and $entry.json) {
                try {
                    $page = $entry.json | ConvertFrom-Json
                    if ($page.data -is [array]) { $script:SearchCache[[string]$entry.url] = $entry }
                } catch {}
            }
        }
    }
    catch { Write-Log 'WARN' "Cache de recherches ignoré : $($_.Exception.Message)" }
}

function Save-SearchCache {
    if (-not $script:SearchCacheDirty) { return }
    $tmp = "$SearchCachePath.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$tmp.bak"
    try {
        $valid = @($script:SearchCache.Values | Where-Object {
            $at = ConvertTo-SharedDateTimeOffset $_.checkedAt
            $at -and $at -ge (Get-SharedHistoryNow).AddMinutes(-15) -and $at -le (Get-SharedHistoryNow)
        } | Sort-Object checkedAt -Descending | Select-Object -First 16)
        $json = ConvertTo-Json -Depth 5 -InputObject ([pscustomobject]@{schema=1;entries=$valid})
        [IO.File]::WriteAllText($tmp,$json,(New-Object Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $SearchCachePath) { [IO.File]::Replace($tmp,$SearchCachePath,$backup,$true) }
        else { [IO.File]::Move($tmp,$SearchCachePath) }
        $script:SearchCache = @{}
        foreach ($entry in $valid) { $script:SearchCache[[string]$entry.url] = $entry }
        $script:SearchCacheDirty = $false
    }
    catch { Write-Log 'WARN' "Cache de recherches non sauvegardé : $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $tmp,$backup -Force -ErrorAction SilentlyContinue }
}

function Start-DiscoveredSelection {
    $key = Get-LocalSelectionKey
    $discovered = @(
        foreach ($entry in @($script:SearchCache.Values)) {
            $at = ConvertTo-SharedDateTimeOffset $entry.checkedAt
            if ([string]$entry.selectionKey -ne $key -or -not $at -or $at -lt (Get-SharedHistoryNow).AddMinutes(-15) -or $at -gt (Get-SharedHistoryNow)) { continue }
            try {
                $page = $entry.json | ConvertFrom-Json
                if ($script:SelectionStats) { $script:SelectionStats.searchHits++ }
                foreach ($candidate in @($page.data)) {
                    $candidate | Add-Member -NotePropertyName selectionKey -NotePropertyValue $key -Force
                    $candidate
                }
            } catch {}
        }
        foreach ($entry in @($script:MetadataCache.Values)) {
            if ($entry.candidate -and [string]$entry.selectionKey -eq $key) { $entry.candidate }
        }
    )
    if ($discovered.Count -eq 0) { return $false }
    $script:AllowRecentHistoryRecycle = $true
    $script:CandidateQueue = @(Get-EligibleCandidates -Data $discovered)
    if ($script:CandidateQueue.Count -eq 0) { return $false }
    $script:OfflineSelection = $false
    Begin-CandidateEvaluation
    return $true
}

function Start-WallhavenApiTask {
    param([ValidateSet('Api','Metadata','Download')][string]$Kind,[string]$Url)
    if (($Kind -eq 'Api' -and $script:SelectionSearches -ge $SearchRequestsPerSelection) -or
        ($Kind -eq 'Metadata' -and $script:MetadataChecks -ge $MetadataChecksPerSelection) -or
        (Get-SharedHistoryNow) -gt $script:SelectionDeadline) {
        Finish-NoEligibleCandidate -Reason 'budget total de sélection épuisé'
        return
    }
    if ($Kind -ne 'Download') {
      $key = if ($Kind -eq 'Metadata') { 'metadata:' + [string]$script:Candidate.id } else { $Url }
      $permit = Get-WallhavenApiPermit -RequestKey $key
      if (-not $permit.Granted) {
        if ($permit.RetryAt -gt $script:SelectionDeadline -or -not $permit.Persisted) {
            Finish-NoEligibleCandidate -Reason $permit.Reason
            if ($script:Running -and $permit.RetryAt.LocalDateTime -gt $script:NextChange) { $script:NextChange = $permit.RetryAt.LocalDateTime }
        }
        else {
            $script:DeferredApiRequest = [pscustomobject]@{kind=$Kind;url=$Url;retryAt=$permit.RetryAt;selectionKey=(Get-LocalSelectionKey)}
            $script:State = 'ApiWait'
            Set-Status 'Budget Wallhaven · attente du prochain créneau...'
        }
        return
      }
    }
    $script:DeferredApiRequest = $null
    if (-not $script:SelectionCancellation) { $script:SelectionCancellation = New-Object Threading.CancellationTokenSource }
    if ($Kind -ne 'Download') { Write-Log 'DEBUG' "API GET $Url kind=$Kind" }
    $task = $script:HttpClient.GetAsync($Url, $script:SelectionCancellation.Token)
    if ($Kind -eq 'Api') {
        $script:SelectionSearches++
        if ($script:SelectionStats) { $script:SelectionStats.searches++ }
        $script:ApiTask = $task
    }
    elseif ($Kind -eq 'Metadata') {
        $script:MetadataChecks++
        if ($script:SelectionStats) { $script:SelectionStats.metadata++ }
        $script:MetadataTask = $task
    }
    else { $script:DownloadTask = $task }
    $script:State = $Kind
}

function Write-CandidateDiagnostic {
    param(
        [ValidateSet("daily", "recent", "pending", "strict", "accepted")]
        [string]$Kind,
        [string]$Id,
        [string]$Detail = ""
    )

    $script:CandidateDiagnostics[$Kind] = [int]$script:CandidateDiagnostics[$Kind] + 1
    if ($script:SelectionStats -and $Kind -ne 'accepted') {
        $s = $script:SelectionStats
        $s.rejected[$Kind] = [int]$s.rejected[$Kind] + 1
        if ($s.samples.Count -lt 3) { $s.samples += "$Kind/$Id" }
    }
}

function Start-ApiRequest {
    param([bool]$UseResolution)

    try {
        $script:ApiAttempt++
        $url = Get-ApiUrl `
            -UseResolution $UseResolution `
            -UsePolicyQuery ([bool]$script:ApiUsePolicyQuery)

        $script:ApiUsedResolution = $UseResolution
        $script:ApiSelectionKey = Get-LocalSelectionKey
        if ($script:SelectionUrls.ContainsKey($url)) {
            Finish-NoEligibleCandidate -Reason 'recherche déjà examinée dans ce cycle'
            return
        }
        $script:SelectionUrls[$url] = $true
        $script:ApiRequestUrl = $url
        $cached = $script:SearchCache[$url]
        $at = if ($cached) { ConvertTo-SharedDateTimeOffset $cached.checkedAt } else { $null }
        if ($at -and $at -ge (Get-SharedHistoryNow).AddMinutes(-15) -and $at -le (Get-SharedHistoryNow)) {
            $script:ApiCachedJson = [string]$cached.json
            $script:State = 'Api'
            if ($script:SelectionStats) { $script:SelectionStats.searchHits++ }
        }
        else { Start-WallhavenApiTask -Kind Api -Url $url }
        if ($script:State -ne 'Api') { return }

        if ((Get-SelectionPageLimit) -gt 1) {
            Set-Status "Recherche Wallhaven · page $($script:ApiCurrentPage)..."
        }
        else {
            Set-Status "Recherche d'un fond sur Wallhaven..."
        }

    }
    catch {
        Handle-RequestFailure -Message (Get-DeepErrorMessage $_)
    }
}

function Get-WallhavenResponseJson {
    param($Task,[switch]$AsBytes)
    $response = $Task.GetAwaiter().GetResult()
    try {
        if ([int]$response.StatusCode -eq 429) {
            $script:ApiRetryAfter = (Get-SharedHistoryNow).LocalDateTime.AddMinutes(15)
            $retry = $response.Headers.RetryAfter
            if ($retry) {
                $until = if ($retry.Delta) { (Get-SharedHistoryNow).LocalDateTime.Add($retry.Delta) }
                         elseif ($retry.Date) { $retry.Date.LocalDateTime }
                if ($until -gt $script:ApiRetryAfter) { $script:ApiRetryAfter = $until }
            }
            Set-WallhavenApiCooldown -Until ([DateTimeOffset]$script:ApiRetryAfter)
            throw "Wallhaven HTTP 429 : trop de requêtes."
        }
        [void]$response.EnsureSuccessStatusCode()
        # GetAsync buffers the content before its task completes.
        if ($AsBytes) { return ,$response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() }
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    }
    finally { $response.Dispose() }
}

function Get-EligibleCandidates {
    param([object[]]$Data)

    $snapshot = Get-SharedHistorySnapshot
    $target = Get-TargetDisplayFilter
    $seenLocal = @{}
    $accepted = New-Object System.Collections.Generic.List[object]

    foreach ($item in @($Data)) {
        $id = [string]$item.id
        $width = 0; $height = 0
        if ($id -notmatch '^[a-zA-Z0-9]+$' -or
            -not [int]::TryParse([string]$item.dimension_x,[ref]$width) -or
            -not [int]::TryParse([string]$item.dimension_y,[ref]$height) -or
            $width -le 0 -or $height -le 0 -or
            (Get-WallhavenRatioForSize -Width $width -Height $height) -ne $target.Ratio -or
            ($target.IsExact -and ($width -ne $target.Width -or $height -ne $target.Height))) {
            continue
        }
        if (-not $id -or $seenLocal.ContainsKey($id)) {
            if ($id) { Write-CandidateDiagnostic -Kind pending -Id $id -Detail "source=local_page" }
            continue
        }
        $seenLocal[$id] = $true
        if ($script:SelectionSeenIds.ContainsKey($id)) { continue }
        $decision = Get-CachedContentDecision -Id $id -Mode ([string]$script:Settings.contentFilter)
        if ($null -ne $decision -and -not $decision.Allowed) {
            $script:SelectionSeenIds[$id] = $true
            Write-CandidateDiagnostic -Kind strict -Id $id -Detail 'source=metadata_cache'
            continue
        }

        if ($snapshot.SeenToday.Contains($id)) {
            Write-CandidateDiagnostic -Kind daily -Id $id
            continue
        }

        if ($snapshot.Pending.Contains($id)) {
            Write-CandidateDiagnostic -Kind pending -Id $id -Detail "source=shared"
            continue
        }

        if (-not $script:AllowRecentHistoryRecycle -and $snapshot.History.Contains($id)) {
            Write-CandidateDiagnostic -Kind recent -Id $id
            continue
        }

        [void]$accepted.Add($item)
    }

    if ($script:AllowRecentHistoryRecycle) {
        return @(
            $accepted |
                Sort-Object @{Expression={ Get-QualifiedCandidateRank -Id ([string]$_.id) }},@{Expression={
                    $id = [string]$_.id
                    if ($snapshot.LastShown.ContainsKey($id)) {
                        [DateTimeOffset]$snapshot.LastShown[$id]
                    }
                    else {
                        [DateTimeOffset]::MinValue
                    }
                }}
        )
    }

    return @($accepted | Sort-Object @{Expression={ Get-QualifiedCandidateRank -Id ([string]$_.id) }},@{Expression={ Get-Random }})
}

function Get-QualifiedCandidateRank {
    param([string]$Id)
    $decision = Get-CachedContentDecision -Id $Id -Mode ([string]$script:Settings.contentFilter)
    if ($null -ne $decision -and $decision.Allowed) { return 0 }
    return 1
}

function Finish-NoEligibleCandidate {
    param([string]$Reason)

    if ($script:ReservedCandidateId) {
        Release-SharedWallpaperReservation -Id $script:ReservedCandidateId
        $script:ReservedCandidateId = $null
    }

    $script:State = "Idle"
    Stop-SelectionRequests
    $script:ApiTask = $null
    $script:MetadataTask = $null
    $script:DownloadTask = $null
    $script:Candidate = $null
    $script:CandidateQueue = @()
    $script:DeferredApiRequest = $null
    $script:ApiCachedJson = $null
    $script:PendingManual = $false
    Save-MetadataCache
    Save-SearchCache
    Write-SelectionSummary -Outcome $Reason

    Set-Status "Aucun nouveau fond éligible pour le moment · image actuelle conservée."
    Write-Log "WARN" "Sélection sans candidat : $Reason"

    if ($script:Running) {
        Schedule-NextChange
        if ($script:ApiRetryAfter -and $script:ApiRetryAfter -gt $script:NextChange) { $script:NextChange = $script:ApiRetryAfter }
    }

    Refresh-DiagnosticsUi
}


function Start-RecycleSelection {
    param([string]$Reason = "pool inédit épuisé")

    if ($script:ReservedCandidateId) {
        Release-SharedWallpaperReservation -Id $script:ReservedCandidateId
        $script:ReservedCandidateId = $null
    }

    $script:AllowRecentHistoryRecycle = $true
    # Recycling never replenishes the total per-change network allowance.
    if ($script:MetadataChecks -ge $MetadataChecksPerSelection) {
        if (-not (Start-CachedSelection)) {
            Finish-NoEligibleCandidate -Reason 'budget de métadonnées épuisé pendant le recyclage'
        }
        return
    }
    $script:ApiAttempt = 0
    $script:PagesTried = @()
    $script:ApiTask = $null
    $script:MetadataTask = $null
    $script:CandidateQueue = @()
    $script:Candidate = $null
    $script:State = "Idle"

    $useResolution = [bool]$script:ApiUsedResolution
    $target = Get-TargetDisplayFilter
    if (Test-ResolutionFallbackAllowed -Target $target -UseResolution $useResolution) {
        $useResolution = $false
    }

    Write-Log "INFO" "Recyclage long-terme (oldest-first, vu aujourd'hui interdit) : $Reason"
    Start-ApiRequest -UseResolution $useResolution
}

function Retry-ApiSelection {
    param([string]$Reason)

    if ($script:ReservedCandidateId) {
        Release-SharedWallpaperReservation -Id $script:ReservedCandidateId
        $script:ReservedCandidateId = $null
    }

    if ($script:ApiAttempt -lt $ApiSelectionAttemptsPerMode) {
        Write-Log "DEBUG" "Nouvel essai de sélection : $Reason"
        $script:ApiTask = $null
        $script:MetadataTask = $null
        $script:CandidateQueue = @()
        $script:State = "Idle"
        Start-ApiRequest -UseResolution ([bool]$script:ApiUsedResolution)
        return $true
    }

    $target = Get-TargetDisplayFilter
    if (Test-ResolutionFallbackAllowed -Target $target -UseResolution ([bool]$script:ApiUsedResolution)) {
        Write-Log "INFO" "Nouvel essai sans résolution minimale, ratio conservé=$($target.Ratio)."
        $script:ApiAttempt = 0
        $script:PagesTried = @()
        $script:ApiTask = $null
        $script:MetadataTask = $null
        $script:CandidateQueue = @()
        $script:State = "Idle"
        Start-ApiRequest -UseResolution $false
        return $true
    }

    if (-not $script:AllowRecentHistoryRecycle) {
        Start-RecycleSelection -Reason $Reason
        return $true
    }

    Finish-NoEligibleCandidate -Reason $Reason
    return $false
}

function Begin-CandidateDownload {
    $candidate = $script:Candidate
    if ($null -eq $candidate) {
        Retry-ApiSelection -Reason "candidat absent" | Out-Null
        return
    }
    if ($candidate.selectionKey -and [string]$candidate.selectionKey -ne (Get-LocalSelectionKey)) {
        Finish-NoEligibleCandidate -Reason "réglages modifiés pendant la sélection"
        return
    }

    $imageUri = [Uri]::new([string]$candidate.path)
    if ($imageUri.Scheme -ne 'https' -or $imageUri.Host -ne 'w.wallhaven.cc') { throw 'URL image Wallhaven invalide.' }
    $ext = [IO.Path]::GetExtension($imageUri.AbsolutePath).ToLowerInvariant()
    if ($ext -notin @(".jpg", ".jpeg", ".png")) {
        if ([string]$candidate.file_type -eq "image/png") { $ext = ".png" } else { $ext = ".jpg" }
    }

    $filePath = Join-Path $CacheDir ("wallhaven-{0}{1}" -f $candidate.id, $ext)
    $script:Candidate | Add-Member -NotePropertyName LocalFilePath -NotePropertyValue $filePath -Force

    if ($script:MetadataCache.ContainsKey([string]$candidate.id) -and -not $script:OfflineSelection) {
        $entry = $script:MetadataCache[[string]$candidate.id]
        $key = [string]$candidate.selectionKey
        if (-not $entry.candidate -or [string]$entry.selectionKey -ne $key) {
            $entry | Add-Member -NotePropertyName candidate -NotePropertyValue ($candidate | Select-Object id,path,url,category,resolution,dimension_x,dimension_y,file_type,selectionKey) -Force
            $entry | Add-Member -NotePropertyName selectionKey -NotePropertyValue $key -Force
            $script:MetadataCacheDirty = $true
        }
    }

    if (Test-Path $filePath) {
        if ($script:OfflineSelection) {
            $image = $null
            try {
                $image = [Drawing.Image]::FromFile($filePath)
                if ($image.Width -ne [int]$candidate.dimension_x -or $image.Height -ne [int]$candidate.dimension_y) {
                    throw "Dimensions du fichier local incohérentes."
                }
            }
            catch {
                Write-Log "WARN" "Image locale invalide id=$($candidate.id) : $($_.Exception.Message)"
                Release-SharedWallpaperReservation -Id ([string]$candidate.id)
                $script:ReservedCandidateId = $null
                Begin-CandidateEvaluation
                return
            }
            finally { if ($image) { $image.Dispose() } }
        }
        try { (Get-Item $filePath).LastWriteTime = [DateTime]::Now } catch {}
        if ($script:SelectionStats) { $script:SelectionStats.localHits++ }
        Write-Log "INFO" "CACHE HIT $($candidate.id) -> $filePath"
        $script:State = "Idle"
        Complete-Wallpaper -FilePath $filePath -Candidate $candidate
        return
    }

    if ($script:OfflineSelection) {
        Finish-NoEligibleCandidate -Reason "fichier local devenu indisponible"
        return
    }

    Set-Status "Téléchargement de $($candidate.resolution)..."
    Write-Log "INFO" "CACHE MISS $($candidate.id) ; IMAGE GET $($candidate.path)"
    Start-WallhavenApiTask -Kind Download -Url ([string]$candidate.path)
}

function Begin-CandidateEvaluation {
    $budgetExhausted = $false
    while (@($script:CandidateQueue).Count -gt 0) {
        $candidate = $script:CandidateQueue[0]
        if ($script:CandidateQueue.Count -gt 1) {
            $script:CandidateQueue = @($script:CandidateQueue[1..($script:CandidateQueue.Count - 1)])
        }
        else {
            $script:CandidateQueue = @()
        }

        $id = [string]$candidate.id
        if ($script:SelectionSeenIds.ContainsKey($id)) { continue }
        $requiresMetadata = Test-ContentFilterRequiresMetadata -Mode ([string]$script:Settings.contentFilter)
        $cachedDecision = if ($requiresMetadata) {
            Get-CachedContentDecision -Id $id -Mode ([string]$script:Settings.contentFilter)
        } else { $null }
        if ($null -ne $cachedDecision -and -not $cachedDecision.Allowed) {
            $script:SelectionSeenIds[$id] = $true
            Write-CandidateDiagnostic -Kind strict -Id $id -Detail ("source=metadata_cache reasons=" + ($cachedDecision.Reasons -join "|"))
            continue
        }
        if ($requiresMetadata -and $null -eq $cachedDecision -and $script:MetadataChecks -ge $MetadataChecksPerSelection) {
            # Scan the rest of this page for cache hits without reserving misses.
            $budgetExhausted = $true
            continue
        }
        $reservation = Reserve-SharedWallpaper -Id $id
        if (-not $reservation.Reserved) {
            if ($reservation.Reason -eq "daily_repeat") {
                Write-CandidateDiagnostic -Kind daily -Id $id -Detail "source=reserve"
            }
            else {
                Write-CandidateDiagnostic -Kind pending -Id $id -Detail "source=reserve"
            }
            continue
        }

        $script:Candidate = $candidate
        $script:ReservedCandidateId = $id
        $script:SelectionSeenIds[$id] = $true

        if (-not $requiresMetadata -or $null -ne $cachedDecision) {
            if ($null -ne $cachedDecision -and $script:SelectionStats) { $script:SelectionStats.metadataHits++ }
            Begin-CandidateDownload
            return
        }

        $metadataUrl = "https://wallhaven.cc/api/v1/w/$id"
        Set-Status "Vérification des métadonnées Wallhaven..."
        Start-WallhavenApiTask -Kind Metadata -Url $metadataUrl
        return
    }

    if ($budgetExhausted) {
        if (-not (Start-CachedSelection)) {
            Finish-NoEligibleCandidate -Reason "budget de métadonnées épuisé pendant le recyclage"
        }
    }
    elseif ($script:OfflineSelection) {
        Finish-NoEligibleCandidate -Reason "cache local épuisé"
    }
    else { Retry-ApiSelection -Reason "aucun candidat éligible dans la page" | Out-Null }
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

    Initialize-SelectionCycle
    $script:ApiAttempt = 0
    $script:PagesTried = @()
    $script:AllowRecentHistoryRecycle = $true
    $script:OfflineSelection = $false
    $script:ApiUsePolicyQuery = $true
    $script:CandidateQueue = @()
    $script:Candidate = $null
    $script:ReservedCandidateId = $null
    if (Start-CachedSelection) { return }
    if (Start-DiscoveredSelection) { return }
    Start-ApiRequest -UseResolution $true
}

function Handle-RequestFailure {
    param([string]$Message)

    if ($script:ReservedCandidateId) {
        Release-SharedWallpaperReservation -Id $script:ReservedCandidateId
        $script:ReservedCandidateId = $null
    }

    $script:State = "Idle"
    Stop-SelectionRequests
    $script:ApiTask = $null
    $script:MetadataTask = $null
    $script:DownloadTask = $null
    $script:Candidate = $null
    $script:CandidateQueue = @()
    $script:DeferredApiRequest = $null

    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "Erreur réseau inconnue."
    }

    Set-Status "Erreur : $Message"
    Write-Log "ERROR" $Message
    Save-MetadataCache

    $rateLimited = $Message -match "429|Too Many Requests"
    if ($rateLimited -and (-not $script:ApiRetryAfter -or $script:ApiRetryAfter -lt (Get-SharedHistoryNow).LocalDateTime)) {
        $script:ApiRetryAfter = (Get-SharedHistoryNow).LocalDateTime.AddMinutes(15)
    }
    if ($script:Running) {
        $script:NextChange = if ($rateLimited) { $script:ApiRetryAfter } else { (Get-SharedHistoryNow).LocalDateTime.AddMinutes(1) }
    }
    if ($rateLimited) { Set-WallhavenApiCooldown -Until ([DateTimeOffset]$script:ApiRetryAfter) }

    $script:PendingManual = $false
    if (-not $script:OfflineSelection) { [void](Start-CachedSelection) }
    Write-SelectionSummary -Outcome 'network_failure'
}

function Get-LocalSelectionKey {
    $target = Get-TargetDisplayFilter
    return (ConvertTo-Json -Compress -InputObject @(
        [string]$script:Settings.query, [string]$script:Settings.category,
        [string]$script:Settings.sort, [string]$script:Settings.contentFilter, [string]$target.Ratio,
        [string]$target.MatchMode, [int]$target.Width, [int]$target.Height
    ))
}

function Start-CachedSelection {
    $key = Get-LocalSelectionKey
    $target = Get-TargetDisplayFilter
    $local = @(
        foreach ($entry in @($script:MetadataCache.Values)) {
            $candidate = $entry.candidate
            if (-not $candidate -or [string]$entry.selectionKey -ne $key -or
                [string]$candidate.id -notmatch '^[a-zA-Z0-9]+$' -or
                [string]$candidate.id -ne [string]$entry.id) { continue }
            $decision = Get-CachedContentDecision -Id ([string]$entry.id) -Mode ([string]$script:Settings.contentFilter)
            if ($null -eq $decision -or -not $decision.Allowed) { continue }
            $width = 0; $height = 0; $uri = $null
            if (-not [int]::TryParse([string]$candidate.dimension_x, [ref]$width) -or
                -not [int]::TryParse([string]$candidate.dimension_y, [ref]$height) -or
                $width -le 0 -or $height -le 0 -or
                (Get-WallhavenRatioForSize -Width $width -Height $height) -ne $target.Ratio -or
                ($target.IsExact -and ($width -ne $target.Width -or $height -ne $target.Height)) -or
                -not [Uri]::TryCreate([string]$candidate.path, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https') { continue }
            $ext = [IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
            if ($ext -notin @('.jpg','.jpeg','.png')) { continue }
            if (Test-Path -LiteralPath (Join-Path $CacheDir ("wallhaven-{0}{1}" -f $entry.id,$ext))) { $candidate }
        }
    )
    if ($local.Count -eq 0) { return $false }
    $script:AllowRecentHistoryRecycle = $true
    $script:CandidateQueue = @(Get-EligibleCandidates -Data $local)
    if ($script:CandidateQueue.Count -eq 0) { return $false }
    $script:OfflineSelection = $true
    $script:PendingManual = $false
    Begin-CandidateEvaluation
    return $true
}

function Complete-Wallpaper {
    param(
        [string]$FilePath,
        $Candidate
    )

    $id = [string]$Candidate.id
    try {
        if ((Get-SharedHistoryNow) -gt $script:SelectionDeadline) {
            Finish-NoEligibleCandidate -Reason 'échéance de sélection dépassée'
            return
        }
        if ($Candidate.selectionKey -and [string]$Candidate.selectionKey -ne (Get-LocalSelectionKey)) {
            Finish-NoEligibleCandidate -Reason "réglages modifiés pendant le téléchargement"
            return
        }
        Set-WindowsWallpaper -Path $FilePath

        Commit-SharedWallpaperShown -Id $id
        $script:ReservedCandidateId = $null
        Refresh-SharedHistoryView
        Write-CandidateDiagnostic -Kind accepted -Id $id

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
        Save-MetadataCache
        Save-SearchCache
        Write-SelectionSummary -Outcome 'applied'

        $script:State = "Idle"
        Stop-SelectionRequests
        $script:Candidate = $null
        $script:DownloadTask = $null
        $script:MetadataTask = $null
        $script:ApiTask = $null

        if ($script:Running) { Schedule-NextChange } else { $script:NextChange = $null }

        $menuCurrent.Enabled = $true
        $CurrentWallpaperButton.IsEnabled = $true
        Refresh-DiagnosticsUi
    }
    catch {
        if ($script:ReservedCandidateId) {
            Release-SharedWallpaperReservation -Id $script:ReservedCandidateId
            $script:ReservedCandidateId = $null
        }
        Handle-RequestFailure -Message (Get-DeepErrorMessage $_)
        return
    }

    if ($script:PendingManual) {
        $script:PendingManual = $false
        Start-WallpaperChange -Reason "Manual"
    }
}

function Process-AsyncState {
    if ($script:State -ne 'Idle' -and $script:SelectionDeadline -and (Get-SharedHistoryNow) -gt $script:SelectionDeadline) {
        # A completed 429 remains authoritative even when its selection expired.
        foreach ($task in @($script:ApiTask,$script:MetadataTask,$script:DownloadTask)) {
            if ($task -and $task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled) {
                $response = $task.GetAwaiter().GetResult()
                if ([int]$response.StatusCode -eq 429) {
                    try { [void](Get-WallhavenResponseJson -Task $task) }
                    catch { Write-Log 'WARN' (Get-DeepErrorMessage $_) }
                }
                else { $response.Dispose() }
            }
        }
        Finish-NoEligibleCandidate -Reason 'échéance de sélection dépassée'
        return
    }
    if ($script:State -eq 'ApiWait' -and $script:DeferredApiRequest) {
        $request = $script:DeferredApiRequest
        if ($request.selectionKey -ne (Get-LocalSelectionKey)) {
            Finish-NoEligibleCandidate -Reason 'réglages modifiés pendant attente API'
        }
        elseif ((Get-SharedHistoryNow) -ge $request.retryAt) {
            Start-WallhavenApiTask -Kind $request.kind -Url $request.url
        }
        return
    }
    if (
        $script:State -eq "Api" -and
        ($null -ne $script:ApiCachedJson -or ($null -ne $script:ApiTask -and $script:ApiTask.IsCompleted))
    ) {
        try {
            $fromCache = $null -ne $script:ApiCachedJson
            $json = if ($fromCache) { $script:ApiCachedJson } else { Get-WallhavenResponseJson -Task $script:ApiTask }
            $script:ApiCachedJson = $null
            if ([string]::IsNullOrWhiteSpace($json)) {
                throw "Wallhaven a renvoyé une réponse vide."
            }

            $response = $json | ConvertFrom-Json
            if ($script:ApiSelectionKey -ne (Get-LocalSelectionKey)) {
                Finish-NoEligibleCandidate -Reason "réglages modifiés pendant la recherche"
                return
            }
            $data = @($response.data)
            if ($response.data -isnot [array]) { throw 'Réponse de recherche Wallhaven invalide.' }
            if (-not $fromCache) {
                $script:SearchCache[$script:ApiRequestUrl] = [pscustomobject]@{
                    url=$script:ApiRequestUrl;selectionKey=$script:ApiSelectionKey;
                    checkedAt=(Get-SharedHistoryNow).ToUniversalTime().ToString('o');json=$json
                }
                $script:SearchCacheDirty = $true
                Save-SearchCache
            }

            try {
                $lastPage = [int]$response.meta.last_page
                if ($script:ApiQueryKey -and $lastPage -gt 0) {
                    $script:PageCeilings[$script:ApiQueryKey] = $lastPage
                }
            } catch {}

            if ($data.Count -eq 0) {
                $filtered = Get-EffectiveWallhavenQuery `
                    -UserQuery ([string]$script:Settings.query) `
                    -Mode ([string]$script:Settings.contentFilter)

                if (
                    [string]$script:Settings.contentFilter -ne "Standard" -and
                    $script:ApiUsePolicyQuery -and
                    $filtered -ne ([string]$script:Settings.query).Trim()
                ) {
                    $script:ApiUsePolicyQuery = $false
                    $script:ApiTask = $null
                    $script:State = "Idle"
                    Write-Log "WARN" "Recherche filtrée vide ; nouvel essai avec requête utilisateur seule, filtre local conservé."
                    Start-ApiRequest -UseResolution ([bool]$script:ApiUsedResolution)
                    return
                }

                Retry-ApiSelection -Reason "page vide" | Out-Null
                return
            }

            $script:CandidateQueue = @(Get-EligibleCandidates -Data $data)
            foreach ($candidate in $script:CandidateQueue) {
                $candidate | Add-Member -NotePropertyName selectionKey -NotePropertyValue $script:ApiSelectionKey -Force
            }
            $script:ApiTask = $null
            $script:State = "Idle"

            if ($script:CandidateQueue.Count -eq 0) {
                Retry-ApiSelection -Reason "page sans candidat inédit/éligible" | Out-Null
                return
            }

            Begin-CandidateEvaluation
        }
        catch {
            Handle-RequestFailure -Message (Get-DeepErrorMessage $_)
        }
        return
    }

    if (
        $script:State -eq "Metadata" -and
        $null -ne $script:MetadataTask -and
        $script:MetadataTask.IsCompleted
    ) {
        $id = [string]$script:Candidate.id
        try {
            $metadataJson = Get-WallhavenResponseJson -Task $script:MetadataTask
            $detail = $metadataJson | ConvertFrom-Json
            if ([string]$detail.data.id -ne $id -or
                [string]$detail.data.category -notin @('general','anime','people') -or
                $detail.data.tags -isnot [array] -or
                @($detail.data.tags | Where-Object { $_.name -isnot [string] -or [string]::IsNullOrWhiteSpace($_.name) }).Count -gt 0) {
                throw "Métadonnées Wallhaven incomplètes ou invalides."
            }
            $tags = @(
                @($detail.data.tags) |
                    ForEach-Object { [string]$_.name } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            )

            Remember-WallhavenMetadata -Id $id -Category ([string]$detail.data.category) -Tags $tags

            $decision = Get-ContentFilterDecision `
                -WallhavenCategory ([string]$detail.data.category) `
                -Tags $tags `
                -Mode ([string]$script:Settings.contentFilter)

            Write-Log "DEBUG" (
                "content.metadata_checked id=$id category=$($decision.Category) mode=$($script:Settings.contentFilter) " +
                "tags=$($tags.Count) score=$($decision.Score) accepted=$($decision.Allowed) " +
                "reasons=$($decision.Reasons -join '|')"
            )

            $script:MetadataTask = $null
            $script:State = "Idle"

            if (-not $decision.Allowed) {
                Release-SharedWallpaperReservation -Id $id
                $script:ReservedCandidateId = $null
                Write-CandidateDiagnostic -Kind strict -Id $id -Detail ("reasons=" + ($decision.Reasons -join "|"))
                Begin-CandidateEvaluation
                return
            }

            Begin-CandidateDownload
        }
        catch {
            $message = Get-DeepErrorMessage $_
            Release-SharedWallpaperReservation -Id $id
            $script:ReservedCandidateId = $null
            $script:MetadataTask = $null
            $script:State = "Idle"
            Handle-RequestFailure -Message $message
        }
        return
    }

    if (
        $script:State -eq "Download" -and
        $null -ne $script:DownloadTask -and
        $script:DownloadTask.IsCompleted
    ) {
        try {
            [byte[]]$bytes = Get-WallhavenResponseJson -Task $script:DownloadTask -AsBytes
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
            Complete-Wallpaper -FilePath $filePath -Candidate $script:Candidate
        }
        catch {
            try {
                if ($script:Candidate -and $script:Candidate.LocalFilePath) {
                    Remove-Item "$($script:Candidate.LocalFilePath).download" -Force -ErrorAction SilentlyContinue
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

Load-SearchCache
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
