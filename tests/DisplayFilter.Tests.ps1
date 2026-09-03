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
    "Get-WallhavenRatioForSize",
    "Convert-WallhavenRatioChoice",
    "Get-TargetDisplayFilter",
    "Get-ResolutionQueryParameters",
    "Test-ResolutionFallbackAllowed"
)) {
    $fn = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true) | Select-Object -First 1

    if ($null -eq $fn) {
        throw "Function '$name' not found."
    }

    Invoke-Expression $fn.Extent.Text
}

$ResolutionMatchNames = @("Au moins", "Exacte")
$CustomRatioNames = @(
    "Automatique",
    "16:9", "16:10", "21:9", "32:9", "48:9",
    "4:3", "5:4", "3:2", "1:1",
    "10:16", "9:16", "9:18"
)

$cases = @(
    @{ W = 2560; H = 1440; Expected = "16x9" },
    @{ W = 1920; H = 1200; Expected = "16x10" },
    @{ W = 3440; H = 1440; Expected = "21x9" },
    @{ W = 3840; H = 1600; Expected = "21x9" },
    @{ W = 5120; H = 1440; Expected = "32x9" },
    @{ W = 7680; H = 1440; Expected = "48x9" },
    @{ W = 1600; H = 1200; Expected = "4x3" },
    @{ W = 1280; H = 1024; Expected = "5x4" },
    @{ W = 1080; H = 1920; Expected = "9x16" }
)

foreach ($case in $cases) {
    $actual = Get-WallhavenRatioForSize -Width $case.W -Height $case.H
    if ($actual -ne $case.Expected) {
        throw "Ratio mismatch for $($case.W)x$($case.H): got '$actual', expected '$($case.Expected)'."
    }
}

# Custom / at least / automatic ratio.
$script:Settings = [pscustomobject]@{
    resolutionMode = "Personnalisé"
    resolutionMatch = "Au moins"
    customWidth = 1920
    customHeight = 1200
    customRatio = "Automatique"
}

$target = Get-TargetDisplayFilter
if ($target.Ratio -ne "16x10" -or $target.MatchMode -ne "Au moins" -or $target.IsExact) {
    throw "Unexpected custom at-least target: $($target | Out-String)"
}

$params = Get-ResolutionQueryParameters -Target $target -UseResolution $true
if ($params["ratios"] -ne "16x10" -or $params["atleast"] -ne "1920x1200" -or $params.Contains("resolutions")) {
    throw "At-least query parameters are incorrect."
}
if (-not (Test-ResolutionFallbackAllowed -Target $target -UseResolution $true)) {
    throw "At-least mode should allow dropping only the minimum resolution during fallback."
}

# Custom / exact / explicit ratio.
$script:Settings = [pscustomobject]@{
    resolutionMode = "Personnalisé"
    resolutionMatch = "Exacte"
    customWidth = 3440
    customHeight = 1440
    customRatio = "21:9"
}

$target = Get-TargetDisplayFilter
if ($target.Ratio -ne "21x9" -or -not $target.IsExact) {
    throw "Unexpected custom exact target."
}

$params = Get-ResolutionQueryParameters -Target $target -UseResolution $true
if ($params["ratios"] -ne "21x9" -or $params["resolutions"] -ne "3440x1440" -or $params.Contains("atleast")) {
    throw "Exact query parameters are incorrect."
}

# Exact mode must remain exact even when a caller asks for a no-minimum retry.
$paramsNoMinimum = Get-ResolutionQueryParameters -Target $target -UseResolution $false
if ($paramsNoMinimum["resolutions"] -ne "3440x1440") {
    throw "Exact mode must never drop the exact resolution constraint."
}
if (Test-ResolutionFallbackAllowed -Target $target -UseResolution $true) {
    throw "Exact mode must not allow resolution fallback."
}

Write-Host "Display resolution/ratio tests: OK" -ForegroundColor Green
