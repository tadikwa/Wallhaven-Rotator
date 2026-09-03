param(
    [switch]$Autostart
)

# Wallhaven Rotator
# Version épurée : rotation du wallpaper Wallhaven uniquement.

$ErrorActionPreference = "Stop"
$script:AppVersion = "1.0.0"

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

$IconPath = Join-Path $PSScriptRoot "Wallhaven-Rotator.ico"
$LauncherPath = Join-Path $PSScriptRoot "Wallhaven-Rotator-Launcher.vbs"
$WScriptPath = Join-Path $env:WINDIR "System32\wscript.exe"

$ApiBase = "https://wallhaven.cc/api/v1/search"
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

function Get-DefaultSettings {
    [pscustomobject]@{
        sort = "Aléatoire"
        category = "Toutes"
        value = 1
        unit = "Minutes"
        autoRotation = $true
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

        return [pscustomobject]@{
            sort = $sort
            category = $category
            value = $value
            unit = $unit
            autoRotation = $auto
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

function Load-WallpaperHistory {
    $list = New-Object 'System.Collections.Generic.List[string]'

    if (-not (Test-Path $HistoryPath)) {
        return $list
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

    return $list
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
    $limit = Get-SelectionPageLimit

    if ($limit -le 1) {
        $script:ApiCurrentPage = 1
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

    $pageLimit = Get-SelectionPageLimit
    if ($pageLimit -gt 1) {
        $params["page"] = [string](Get-SelectionPage)
    }
    else {
        $script:ApiCurrentPage = 1
    }

    if ($UseResolution) {
        $screen = Get-PrimaryResolution
        if ($screen.Width -gt 0 -and $screen.Height -gt 0) {
            $params["atleast"] = "$($screen.Width)x$($screen.Height)"
        }
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
$script:PendingManual = $false
$script:HistoryIds = Load-WallpaperHistory
$script:LastWallpaperId = $null
$script:LastWallpaperUrl = $null
$script:LastWallpaperFilePath = $null
$script:LastStatus = ""
$script:Exiting = $false

[xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Wallhaven Rotator"
    Width="560"
    SizeToContent="Height"
    MinHeight="430"
    MaxHeight="760"
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
                    <TextBlock x:Name="VersionText" Text="v1.0.0"
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
$RunAtLogonCheck = $window.FindName("RunAtLogonCheck")
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

function Set-Status {
    param([string]$Text)

    $script:LastStatus = $Text
    $StatusText.Text = $Text
}

function Sync-UiFromSettings {
    $SortCombo.SelectedItem = [string]$script:Settings.sort
    $CategoryCombo.SelectedItem = [string]$script:Settings.category
    $IntervalText.Text = [string][int]$script:Settings.value
    $UnitCombo.SelectedItem = [string]$script:Settings.unit
    $AutoRotationCheck.IsChecked = [bool]$script:Settings.autoRotation
    $RunAtLogonCheck.IsChecked = Test-RunAtLogon
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
        $null -eq $UnitCombo.SelectedItem
    ) {
        return $false
    }

    $script:Settings.sort = [string]$SortCombo.SelectedItem
    $script:Settings.category = [string]$CategoryCombo.SelectedItem
    $script:Settings.value = $value
    $script:Settings.unit = [string]$UnitCombo.SelectedItem
    $script:Settings.autoRotation = [bool]$AutoRotationCheck.IsChecked

    $script:Running = [bool]$script:Settings.autoRotation
    Save-Settings

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
    $window.ShowInTaskbar = $true
    $window.Show()
    $window.WindowState = [System.Windows.WindowState]::Normal
    $window.Activate()
}

function Hide-SettingsWindow {
    $window.Hide()
    $window.ShowInTaskbar = $false
}

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

        Write-Log "INFO" "API GET $url ; tentative=$($script:ApiAttempt) ; historique=$($script:HistoryIds.Count)/$HistoryMaxIds"
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

    if ([bool]$script:ApiUsedResolution) {
        Write-Log "INFO" "Sélection difficile avec filtre résolution ; nouvel essai sans filtre minimum."
        $script:ApiAttempt = 0
        $script:PagesTried = @()
        $script:ApiTask = $null
        $script:State = "Idle"
        Start-ApiRequest -UseResolution $false
        return $true
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

Write-Log "INFO" (
    "Wallhaven Rotator v{0} démarré. Auto={1}; PID={2}; Run={3}; historique={4}/{5}; cacheMax={6} fichiers/{7} MiB" -f `
    $script:AppVersion,
    [bool]$Autostart,
    $PID,
    $startupMethod,
    $script:HistoryIds.Count,
    $HistoryMaxIds,
    $CacheMaxFiles,
    [int]($CacheMaxBytes / 1MB)
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
