$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1"

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

foreach ($name in @(
    "Load-WallpaperHistory",
    "Save-WallpaperHistory",
    "Add-WallpaperToHistory"
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

$HistoryMaxIds = 1000
$HistoryPath = Join-Path $env:TEMP (
    "wallhaven-history-test-{0}.json" -f [Guid]::NewGuid().ToString("N")
)

try {
    # Fresh install: no history.json. Must return an actual empty List, never $null.
    Remove-Item $HistoryPath -Force -ErrorAction SilentlyContinue
    $fresh = Load-WallpaperHistory

    if ($null -eq $fresh) {
        throw "Fresh history initialization returned `$null."
    }

    if ($fresh -isnot [System.Collections.Generic.List[string]]) {
        throw "Fresh history has unexpected type: $($fresh.GetType().FullName)"
    }

    if ($fresh.Count -ne 0) {
        throw "Fresh history should contain 0 IDs, got $($fresh.Count)."
    }

    $script:HistoryIds = $fresh
    Add-WallpaperToHistory -Id "abc123"

    if ($script:HistoryIds.Count -ne 1 -or $script:HistoryIds[0] -ne "abc123") {
        throw "Adding the first wallpaper ID failed."
    }

    if (-not (Test-Path $HistoryPath)) {
        throw "history.json was not created after adding an ID."
    }

    $saved = Get-Content $HistoryPath -Raw | ConvertFrom-Json
    if (@($saved.ids).Count -ne 1 -or [string]$saved.ids[0] -ne "abc123") {
        throw "Persisted history does not contain the expected ID."
    }

    # A one-item history must also remain List[string], not collapse to a scalar string.
    $loaded = Load-WallpaperHistory

    if ($loaded -isnot [System.Collections.Generic.List[string]]) {
        throw "One-item history has unexpected type: $($loaded.GetType().FullName)"
    }

    if ($loaded.Count -ne 1 -or $loaded[0] -ne "abc123") {
        throw "One-item history reload failed."
    }

    Write-Host "History initialization regression test: OK" -ForegroundColor Green
}
finally {
    Remove-Item $HistoryPath -Force -ErrorAction SilentlyContinue
}
