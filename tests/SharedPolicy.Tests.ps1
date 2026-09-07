$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Policy = Join-Path $Root "src\Wallhaven-SharedPolicy.ps1"

$testRoot = Join-Path $env:TEMP ("wallhaven-shared-policy-" + [guid]::NewGuid().ToString("N"))
$env:WALLHAVEN_SHARED_BASE_DIR = $testRoot
$env:WALLHAVEN_SHARED_MUTEX_NAME = "Local\WallhavenSharedTest-" + [guid]::NewGuid().ToString("N")
$env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH = Join-Path $testRoot "legacy-rotator-history.json"
$env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH = Join-Path $testRoot "legacy-screensaver-history.json"

[void][IO.Directory]::CreateDirectory($testRoot)

try {
    . $Policy

    # Content Filter Policy v5
    if ((Get-EffectiveWallhavenQuery -UserQuery "+nature -people" -Mode Standard) -ne "+nature -people") {
        throw "Standard must preserve the user query unchanged."
    }

    $strictQuery = Get-EffectiveWallhavenQuery -UserQuery "+nature" -Mode Strict
    if ($strictQuery -notmatch "\+nature" -or $strictQuery -notmatch "-cleavage") {
        throw "Strict query composition failed."
    }

    if ((Get-EffectiveWallhavenQuery -UserQuery "id:123" -Mode Strict) -ne "id:123") {
        throw "Exact id query must remain unchanged."
    }

    $standard = Get-ContentFilterDecision -WallhavenCategory "anime" -Tags @("anime girls", "blue hair") -Mode Standard
    if (-not $standard.Allowed) {
        throw "Standard must not apply Strict local rejection."
    }

    $reducedNeutral = Get-ContentFilterDecision -WallhavenCategory "anime" -Tags @("anime girls", "blue hair") -Mode Reduced
    if (-not $reducedNeutral.Allowed) {
        throw "Reduced must keep ordinary female/anime metadata."
    }

    $reducedAdult = Get-ContentFilterDecision -WallhavenCategory "people" -Tags @("women", "pornstar") -Mode Reduced
    if ($reducedAdult.Allowed) {
        throw "Reduced must reject strong adult metadata."
    }

    $strictAnime = Get-ContentFilterDecision -WallhavenCategory "anime" -Tags @("samurai", "armor", "sword") -Mode Strict
    if ($strictAnime.Allowed -or $strictAnime.Reasons -notcontains "strict:anime_unclassified") {
        throw "Strict must fail closed for sparse Anime metadata."
    }

    $strictPeople = Get-ContentFilterDecision -WallhavenCategory "people" -Tags @("portrait display", "studio") -Mode Strict
    if ($strictPeople.Allowed -or $strictPeople.Reasons -notcontains "strict:people_unclassified") {
        throw "Strict must fail closed for sparse People metadata."
    }

    if ((Get-ContentFilterDecision -WallhavenCategory "general" -Tags @("women", "digital art") -Mode Strict).Allowed) {
        throw "Strict must reject female-focused metadata."
    }

    if ((Get-ContentFilterDecision -WallhavenCategory "general" -Tags @("open shirt") -Mode Strict).Allowed) {
        throw "Strict must hard-block exposure tags."
    }

    $risk = Get-ContentFilterDecision -WallhavenCategory "general" -Tags @("kneeling", "bare shoulders", "parted lips") -Mode Strict
    if ($risk.Allowed -or $risk.Score -lt 4) {
        throw "Strict weak-signal score did not reject."
    }

    if (-not (Get-ContentFilterDecision -WallhavenCategory "anime" -Tags @("anime boys", "male character") -Mode Strict).Allowed) {
        throw "Strict must allow explicit male Anime metadata."
    }

    if (-not (Get-ContentFilterDecision -WallhavenCategory "anime" -Tags @("mecha", "robot", "space art") -Mode Strict).Allowed) {
        throw "Strict must allow clearly non-human Anime scenery."
    }

    # Controlled legacy migration: test fixtures only, never the user's real
    # %LOCALAPPDATA% history.
    $fixtureEncoding = New-Object Text.UTF8Encoding($true)

    $rotatorFixture = @{
        ids = @("legacy-rotator-1", "legacy-shared")
    } | ConvertTo-Json
    [IO.File]::WriteAllText(
        $env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH,
        [string]$rotatorFixture,
        $fixtureEncoding
    )

    $screensaverFixture = ConvertTo-Json -InputObject @(
        "legacy-screen-1",
        "legacy-shared"
    )
    [IO.File]::WriteAllText(
        $env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH,
        [string]$screensaverFixture,
        $fixtureEncoding
    )

    Set-SharedHistoryTestNow "2026-09-06T12:00:00Z"
    $migrated = Get-SharedHistorySnapshot

    foreach ($legacyId in @("legacy-rotator-1", "legacy-screen-1", "legacy-shared")) {
        if (-not $migrated.History.Contains($legacyId)) {
            throw "Controlled legacy migration missed '$legacyId'."
        }
        if ($migrated.SeenToday.Contains($legacyId)) {
            throw "Legacy ID '$legacyId' was incorrectly fabricated as seen today."
        }
    }

    $persistedMigration = Get-Content `
        -Path (Join-Path $testRoot "history.json") `
        -Raw |
        ConvertFrom-Json

    if (
        -not [bool]$persistedMigration.migrations.rotatorV1 -or
        -not [bool]$persistedMigration.migrations.screensaverV1
    ) {
        throw "Legacy migration markers were not persisted."
    }

    # Reset only the isolated test state so subsequent anti-repeat assertions
    # start from a known empty state.
    Reset-SharedWallpaperHistory

    # Shared hard daily anti-repeat.
    Set-SharedHistoryTestNow "2026-09-06T12:00:00Z"
    $r = Reserve-SharedWallpaper -Id "daily1" -Owner "test-a"
    if (-not $r.Reserved) { throw "Initial reservation failed." }

    Commit-SharedWallpaperShown -Id "daily1" -Owner "test-a"
    $snapshot = Get-SharedHistorySnapshot
    if (-not $snapshot.SeenToday.Contains("daily1")) {
        throw "Successful display was not added to seenToday."
    }

    $again = Reserve-SharedWallpaper -Id "daily1" -Owner "test-b"
    if ($again.Reserved -or $again.Reason -ne "daily_repeat") {
        throw "Same-day repeat was not hard-rejected."
    }

    # Reload from disk.
    $snapshot = Get-SharedHistorySnapshot
    if (-not $snapshot.History.Contains("daily1")) {
        throw "History did not survive reload."
    }

    # Local-date rollover keeps long history but removes daily ban.
    Set-SharedHistoryTestNow "2026-09-07T12:00:00Z"
    $nextDay = Get-SharedHistorySnapshot
    if ($nextDay.SeenToday.Contains("daily1")) {
        throw "Yesterday's ID remained in seenToday."
    }
    if (-not $nextDay.History.Contains("daily1")) {
        throw "Yesterday's ID disappeared from long-term history."
    }
    $r = Reserve-SharedWallpaper -Id "daily1" -Owner "test-next-day"
    if (-not $r.Reserved) {
        throw "Old ID should be eligible for controlled long-term recycling on a new day."
    }
    Release-SharedWallpaperReservation -Id "daily1" -Owner "test-next-day"

    # Cross-pool pending dedup.
    Set-SharedHistoryTestNow "2026-09-07T10:00:00Z"
    if (-not (Reserve-SharedWallpaper -Id "pending1" -Owner "pool-a").Reserved) {
        throw "First pending reservation failed."
    }
    $other = Reserve-SharedWallpaper -Id "pending1" -Owner "pool-b"
    if ($other.Reserved -or $other.Reason -ne "pending_duplicate") {
        throw "Cross-pool pending duplicate was not rejected."
    }
    Release-SharedWallpaperReservation -Id "pending1" -Owner "pool-a"

    # Pending reservations expire and cannot block an ID forever.
    Set-SharedHistoryTestNow "2026-09-07T10:10:00Z"
    if (-not (Reserve-SharedWallpaper -Id "expires1" -Owner "pool-a").Reserved) {
        throw "Expiry test reservation failed."
    }
    Set-SharedHistoryTestNow "2026-09-07T10:16:00Z"
    $expiredRetry = Reserve-SharedWallpaper -Id "expires1" -Owner "pool-b"
    if (-not $expiredRetry.Reserved) {
        throw "Expired pending reservation still blocked another owner."
    }
    Release-SharedWallpaperReservation -Id "expires1" -Owner "pool-b"

    # Normalization keeps at most 5,000 older IDs but NEVER trims IDs from today.
    Set-SharedHistoryTestNow "2026-09-07T12:00:00Z"
    $normalizeState = New-EmptySharedHistoryState
    $normalizeState.migrations.rotatorV1 = $true
    $normalizeState.migrations.screensaverV1 = $true
    $normalizeState.entries = @(
        for ($i = 1; $i -le 5005; $i++) {
            [pscustomobject]@{
                wallhavenId = "old-$i"
                shownAt = ([DateTimeOffset]::Parse("2026-09-06T12:00:00Z").AddSeconds($i)).ToString("o")
            }
        }
    ) + @(
        [pscustomobject]@{ wallhavenId = "today-a"; shownAt = "2026-09-07T11:00:00Z" },
        [pscustomobject]@{ wallhavenId = "today-b"; shownAt = "2026-09-07T11:01:00Z" }
    )
    Normalize-SharedHistoryEntriesUnlocked $normalizeState
    $normalizedIds = @($normalizeState.entries | ForEach-Object { [string]$_.wallhavenId })
    if ($normalizedIds.Count -ne 5002) {
        throw "History normalization count is wrong: $($normalizedIds.Count) instead of 5002."
    }
    if ($normalizedIds -notcontains "today-a" -or $normalizedIds -notcontains "today-b") {
        throw "Today's hard history was trimmed by long-term normalization."
    }
    if ($normalizedIds -contains "old-1" -or $normalizedIds -contains "old-5") {
        throw "Oldest long-term history entries were not trimmed first."
    }

    # Failed display/download = release only, never history.
    if (-not (Reserve-SharedWallpaper -Id "failure1" -Owner "failure-test").Reserved) {
        throw "Failure test reservation failed."
    }
    Release-SharedWallpaperReservation -Id "failure1" -Owner "failure-test"
    if ((Get-SharedHistorySnapshot).History.Contains("failure1")) {
        throw "Failed display incorrectly consumed the ID."
    }

    Write-Host "Shared history + Content Filter Policy v5 tests: OK" -ForegroundColor Green
}
finally {
    Set-SharedHistoryTestNow $null
    Remove-Item Env:WALLHAVEN_SHARED_BASE_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_SHARED_MUTEX_NAME -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
