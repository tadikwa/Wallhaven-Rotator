$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1"
$Policy = Join-Path $Root "src\Wallhaven-SharedPolicy.ps1"

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $Source,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Runtime source does not parse: $($parseErrors[0].Message)"
}

$testRoot = Join-Path $env:TEMP ("wallhaven-history-init-" + [guid]::NewGuid().ToString("N"))
$env:WALLHAVEN_SHARED_BASE_DIR = $testRoot
$env:WALLHAVEN_SHARED_MUTEX_NAME = "Local\WallhavenHistoryInit-" + [guid]::NewGuid().ToString("N")
$env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH = Join-Path $testRoot "legacy-rotator-history.json"
$env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH = Join-Path $testRoot "legacy-screensaver-history.json"

try {
    . $Policy
    Set-SharedHistoryTestNow "2026-09-06T12:00:00Z"

    foreach ($name in @(
        "Get-SharedHistoryOrderedIds",
        "Load-WallpaperHistory",
        "Refresh-SharedHistoryView",
        "Save-WallpaperHistory",
        "Add-WallpaperToHistory",
        "Get-HistoryTail"
    )) {
        $fn = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
        }, $true) | Select-Object -First 1

        if ($null -eq $fn) {
            throw "Function '$name' not found in runtime source."
        }

        Invoke-Expression $fn.Extent.Text
    }

    $HistoryMaxIds = 5000
    $script:HistoryIds = Load-WallpaperHistory

    if ($null -eq $script:HistoryIds) {
        throw "Fresh shared history initialization returned `$null."
    }

    if ($script:HistoryIds -isnot [System.Collections.Generic.List[string]]) {
        throw "Fresh history has unexpected type: $($script:HistoryIds.GetType().FullName)"
    }

    if ($script:HistoryIds.Count -ne 0) {
        throw "Fresh shared history should contain 0 IDs."
    }

    Add-WallpaperToHistory -Id "abc123"

    if ($script:HistoryIds.Count -ne 1 -or $script:HistoryIds[0] -ne "abc123") {
        throw "First shared history commit failed."
    }

    # Exercise the existing-destination atomic replacement path more than once.
    Add-WallpaperToHistory -Id "def456"
    if ($script:HistoryIds.Count -ne 2 -or -not $script:HistoryIds.Contains("abc123") -or -not $script:HistoryIds.Contains("def456")) {
        throw "Repeated shared history replacement failed."
    }

    $leftovers = @(
        Get-ChildItem -Path $testRoot -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "history.*.tmp" -or $_.Name -like "history.*.bak" }
    )
    if ($leftovers.Count -ne 0) {
        throw "Atomic history writer left temporary/backup files behind: $($leftovers.Name -join ', ')"
    }

    $snapshot = Get-SharedHistorySnapshot
    foreach ($id in @("abc123", "def456")) {
        if (-not $snapshot.History.Contains($id)) {
            throw "Shared persisted history does not contain $id."
        }
        if (-not $snapshot.SeenToday.Contains($id)) {
            throw "Successful commit was not added to seenToday: $id."
        }
    }

    Write-Host "Shared history initialization regression test: OK" -ForegroundColor Green
}
finally {
    Set-SharedHistoryTestNow $null
    Remove-Item Env:WALLHAVEN_SHARED_BASE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_SHARED_MUTEX_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
