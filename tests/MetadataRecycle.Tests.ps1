$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1"
$Policy = Join-Path $Root "src\Wallhaven-SharedPolicy.ps1"
$testRoot = Join-Path $env:TEMP ("wallhaven-metadata-recycle-" + [guid]::NewGuid().ToString("N"))
$env:WALLHAVEN_SHARED_BASE_DIR = $testRoot
$env:WALLHAVEN_SHARED_MUTEX_NAME = "Local\WallhavenMetadataRecycle-" + [guid]::NewGuid().ToString("N")
$env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH = Join-Path $testRoot "old-rotator-history.json"
$env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH = Join-Path $testRoot "old-screensaver-history.json"
[void][IO.Directory]::CreateDirectory($testRoot)

try {
    . $Policy

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Source, [ref]$tokens, [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw "Runtime source does not parse: $($parseErrors[0].Message)"
    }

    foreach ($name in @(
        "Load-MetadataCache",
        "Get-CachedContentDecision",
        "Remember-WallhavenMetadata",
        "Save-MetadataCache",
        "Begin-CandidateEvaluation",
        "Start-RecycleSelection"
    )) {
        $fn = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
        }, $true) | Select-Object -First 1
        if ($null -eq $fn) { throw "Missing function: $name" }
        Invoke-Expression $fn.Extent.Text
    }

    # No actual GUI or network calls: isolate the selection functions.
    function Write-Log { param([string]$Level, [string]$Message) }
    function Set-Status { param([string]$Message) }
    function Write-CandidateDiagnostic { param($Kind, $Id, $Detail) }
    function Start-ApiRequest {
        param([bool]$UseResolution)
        $script:RequestedResolution = $UseResolution
        $script:StartApiCalls++
    }
    function Get-TargetDisplayFilter {
        return [pscustomobject]@{ Ratio = "32x9"; MatchMode = "Au moins"; IsExact = $false }
    }
    function Test-ResolutionFallbackAllowed {
        param($Target, [bool]$UseResolution)
        return $UseResolution
    }
    function Begin-CandidateDownload {
        $script:Downloaded = [string]$script:Candidate.id
    }
    function Finish-NoEligibleCandidate {
        param([string]$Reason)
        $script:Finished = $Reason
    }
    $MetadataCachePath = Join-Path $testRoot "metadata-cache.json"
    $MetadataCacheMaxAgeDays = 7
    $MetadataCacheMaxEntries = 1200
    $MetadataChecksPerSelection = 16

    Load-MetadataCache
    if ($script:MetadataCache.Count -ne 0) { throw "Fresh cache should be empty." }

    Remember-WallhavenMetadata -Id "safe1" -Category "general" -Tags @("forest", "mountains")
    Remember-WallhavenMetadata -Id "unsafe1" -Category "general" -Tags @("women", "portrait")
    if (-not (Get-CachedContentDecision -Id "safe1" -Mode Strict).Allowed) {
        throw "Strict must accept cached safe scenery."
    }
    if ((Get-CachedContentDecision -Id "unsafe1" -Mode Strict).Allowed) {
        throw "Strict must reject cached female subjects."
    }
    if (-not (Get-CachedContentDecision -Id "unsafe1" -Mode Reduced).Allowed) {
        throw "Changing policy must recalculate cached tags, not reuse an old reject verdict."
    }

    Save-MetadataCache
    if (-not (Test-Path $MetadataCachePath)) { throw "Cache was not persisted." }
    $script:MetadataCache = @{}
    Load-MetadataCache
    if (-not (Get-CachedContentDecision -Id "safe1" -Mode Strict).Allowed) {
        throw "Persisted safe metadata was lost."
    }

    # Expired entries must never be reused.
    $script:MetadataCache["safe1"].checkedAt = [DateTime]::UtcNow.AddDays(-8).ToString("o")
    if ($null -ne (Get-CachedContentDecision -Id "safe1" -Mode Strict)) {
        throw "Expired metadata was reused."
    }
    Remember-WallhavenMetadata -Id "safe1" -Category "general" -Tags @("forest", "mountains")

    # An already-validated image must still work when the online metadata
    # budget is exhausted; Strict is evaluated on its cached raw tags.
    $script:Settings = [pscustomobject]@{ contentFilter = "Strict" }
    $script:MetadataChecks = 16
    $script:AllowRecentHistoryRecycle = $true
    $script:ReservedCandidateId = $null
    $script:CandidateQueue = @(
        [pscustomobject]@{ id = "unsafe1" },
        [pscustomobject]@{ id = "safe1" }
    )
    $script:Downloaded = $null
    Begin-CandidateEvaluation
    if ($script:Downloaded -ne "safe1" -or $script:MetadataChecks -ne 16) {
        throw "Cached safe candidate must be usable without extra metadata calls."
    }
    Release-SharedWallpaperReservation -Id "safe1"
    $script:ReservedCandidateId = $null

    # A non-cached candidate past the limit must stop, not be classified
    # as unsafe or cause thousands of retries.
    $script:CandidateQueue = @([pscustomobject]@{ id = "uncached1" })
    $script:MetadataChecks = 16
    $script:AllowRecentHistoryRecycle = $true
    $script:Finished = $null
    Begin-CandidateEvaluation
    if ($script:Finished -notmatch "budget de métadonnées" -or $script:MetadataChecks -ne 16) {
        throw "Exhausted recycle budget must terminate selection immediately."
    }

    # The actual recycling transition gives a fresh budget and preserves
    # the 32:9 ratio while allowing only the minimum-size fallback.
    $script:AllowRecentHistoryRecycle = $false
    $script:MetadataChecks = 16
    $script:ApiUsedResolution = $true
    $script:ReservedCandidateId = $null
    $script:StartApiCalls = 0
    $script:RequestedResolution = $true
    Start-RecycleSelection -Reason "test quota"
    if (
        -not $script:AllowRecentHistoryRecycle -or
        $script:MetadataChecks -ne 0 -or
        $script:StartApiCalls -ne 1 -or
        $script:RequestedResolution
    ) {
        throw "Recycling did not restart metadata budget with same ratio and relaxed minimum."
    }

    Write-Host "Metadata-cache / exhausted-budget / Strict recycling tests: OK" -ForegroundColor Green
}
finally {
    Remove-Item Env:WALLHAVEN_SHARED_BASE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_SHARED_MUTEX_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
