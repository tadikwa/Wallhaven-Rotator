# Wallhaven shared content filtering + persistent anti-repeat state.
# Compatible with Windows PowerShell 5.1.
# This file is intentionally dependency-free.

$script:WallhavenContentFilterPolicyVersion = 5
$script:WallhavenContentFilterModes = @("Standard", "Reduced", "Strict")
$script:WallhavenSharedHistoryLimit = 5000
$script:WallhavenSharedPendingMinutes = 5
$script:WallhavenSharedMutexName = if ($env:WALLHAVEN_SHARED_MUTEX_NAME) {
    [string]$env:WALLHAVEN_SHARED_MUTEX_NAME
} else {
    "Local\WallhavenSharedHistoryV2"
}

$script:WallhavenSharedBaseDir = if ($env:WALLHAVEN_SHARED_BASE_DIR) {
    [string]$env:WALLHAVEN_SHARED_BASE_DIR
} else {
    Join-Path $env:LOCALAPPDATA "WallhavenShared"
}

$script:WallhavenSharedHistoryPath = Join-Path $script:WallhavenSharedBaseDir "history.json"
$script:WallhavenApiBudgetPath = Join-Path $script:WallhavenSharedBaseDir "api-budget.json"
$script:WallhavenSharedOwner = "rotator:{0}:{1}" -f $PID, ([guid]::NewGuid().ToString("N"))

$script:WallhavenLegacyRotatorHistoryPath = if ($env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH) {
    [string]$env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH
} else {
    Join-Path (Join-Path $env:LOCALAPPDATA "WallhavenWallpaperRotator") "history.json"
}

$script:WallhavenLegacyScreensaverHistoryPath = if ($env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH) {
    [string]$env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH
} else {
    Join-Path (Join-Path $env:LOCALAPPDATA "WallhavenScreensaver") "history.json"
}


$script:WallhavenSharedTestNow = $null

function Get-SharedHistoryNow {
    if ($null -ne $script:WallhavenSharedTestNow) {
        return [DateTimeOffset]$script:WallhavenSharedTestNow
    }
    return [DateTimeOffset]::Now
}

function Set-SharedHistoryTestNow {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        $script:WallhavenSharedTestNow = $null
    } else {
        $script:WallhavenSharedTestNow = [DateTimeOffset]::Parse([string]$Value)
    }
}

# API permits are separate from history. All cooperating clients use this file
# and mutex; writing a permit BEFORE dispatch also counts failed HTTP requests.
function Get-WallhavenApiPermit {
    param(
        [string]$RequestKey,
        [ValidateSet('Rotator','Screensaver')][string]$Client = 'Rotator',
        [Nullable[DateTimeOffset]]$CooldownUntil
    )
    $now = Get-SharedHistoryNow
    $retryAt = $now.AddSeconds(60)
    $mutex = $null; $acquired = $false
    try {
        $mutex = New-Object Threading.Mutex($false, ($script:WallhavenSharedMutexName + '-ApiBudget'))
        try { $acquired = $mutex.WaitOne($(if ($CooldownUntil) { 500 } else { 0 })) }
        catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) {
            return [pscustomobject]@{ Granted=$false; Persisted=$false; RetryAt=$now.AddSeconds(1); Reason='budget_busy' }
        }
        $state = [pscustomobject]@{ schema=1; notBefore=''; requests=@() }
        if (Test-Path -LiteralPath $script:WallhavenApiBudgetPath) {
            if ((Get-Item -LiteralPath $script:WallhavenApiBudgetPath).Length -gt 65536) { throw 'API budget too large.' }
            $state = Get-Content -LiteralPath $script:WallhavenApiBudgetPath -Raw | ConvertFrom-Json
            if ([int]$state.schema -ne 1 -or $state.requests -isnot [array]) { throw 'Invalid API budget schema.' }
        }
        $notBefore = ConvertTo-SharedDateTimeOffset $state.notBefore
        if ($state.notBefore -and -not $notBefore) { throw 'Invalid API cooldown.' }
        $receipts = @(
            foreach ($receipt in $state.requests) {
                $at = ConvertTo-SharedDateTimeOffset $receipt.at
                if (-not $at -or -not $receipt.client -or -not $receipt.key) { throw 'Invalid API receipt.' }
                # Retain future timestamps if the system clock moves backwards.
                if ($at -ge $now.AddSeconds(-60)) { $receipt }
            }
        )
        $changed = $false
        if ($CooldownUntil -and (-not $notBefore -or $CooldownUntil -gt $notBefore)) {
            $notBefore = [DateTimeOffset]$CooldownUntil
            $state.notBefore = $notBefore.ToString('o')
            $changed = $true
        }
        $waitUntil = $now
        if ($notBefore -and $notBefore -gt $waitUntil) { $waitUntil = $notBefore }
        $ordered = @($receipts | Sort-Object at)
        if ($ordered.Count -gt 0) {
            $spacing = ([DateTimeOffset]::Parse($ordered[-1].at)).AddMilliseconds(2600)
            if ($spacing -gt $waitUntil) { $waitUntil = $spacing }
        }
        if ($ordered.Count -ge 24) {
            $until = ([DateTimeOffset]::Parse($ordered[-24].at)).AddMilliseconds(60001)
            if ($until -gt $waitUntil) { $waitUntil = $until }
        }
        $own = @($ordered | Where-Object { $_.client -eq 'Rotator' })
        # Leave headroom for the current, independently limited 30/min Screensaver.
        if ($Client -eq 'Rotator' -and $own.Count -ge 12) {
            $until = ([DateTimeOffset]::Parse($own[-12].at)).AddMilliseconds(60001)
            if ($until -gt $waitUntil) { $waitUntil = $until }
        }
        if ($RequestKey -like 'metadata:*') {
            $same = @($ordered | Where-Object { $_.key -eq $RequestKey })
            if ($same.Count) {
                $until = ([DateTimeOffset]::Parse($same[-1].at)).AddMilliseconds(60001)
                if ($until -gt $waitUntil) { $waitUntil = $until }
            }
        }
        $granted = -not $CooldownUntil -and $waitUntil -le $now
        if ($granted) {
            if ([string]::IsNullOrWhiteSpace($RequestKey)) { throw 'Missing API request key.' }
            $receipts += [pscustomobject]@{ at=$now.ToUniversalTime().ToString('o'); client=$Client; key=$RequestKey }
            $changed = $true
        }
        if ($changed) {
            $state.requests = $receipts
            [void][IO.Directory]::CreateDirectory($script:WallhavenSharedBaseDir)
            $tmp = $script:WallhavenApiBudgetPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            $backup = $tmp + '.bak'
            try {
                [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $state -Depth 5), (New-Object Text.UTF8Encoding($true)))
                if (Test-Path -LiteralPath $script:WallhavenApiBudgetPath) {
                    [IO.File]::Replace($tmp, $script:WallhavenApiBudgetPath, $backup, $true)
                }
                else { [IO.File]::Move($tmp, $script:WallhavenApiBudgetPath) }
            }
            finally { Remove-Item -LiteralPath $tmp,$backup -Force -ErrorAction SilentlyContinue }
        }
        return [pscustomobject]@{ Granted=$granted; Persisted=$true; RetryAt=$waitUntil; Reason=$(if ($notBefore -and $notBefore -gt $now) {'cooldown'} else {'rate_budget'}) }
    }
    catch {
        # A damaged or unwritable ledger must never replenish the API budget.
        return [pscustomobject]@{ Granted=$false; Persisted=$false; RetryAt=$retryAt; Reason=('budget_unavailable: ' + $_.Exception.Message) }
    }
    finally {
        if ($mutex) {
            if ($acquired) { [void]$mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    }
}

function Set-WallhavenApiCooldown {
    param([DateTimeOffset]$Until)
    $result = Get-WallhavenApiPermit -CooldownUntil $Until
    if (-not $result.Persisted) { throw "Impossible de persister la pause API : $($result.Reason)" }
}

$script:FilterQueryExclusions = @(
    "cleavage", "lingerie", "underwear", "panties", "bikini",
    "swimsuit", "ecchi", "schoolgirl", "loli"
)

$script:FilterReducedHardConcepts = @(
    "cleavage", "lingerie", "underwear", "panties", "panty", "bikini",
    "swimsuit", "bra", "sideboob", "underboob", "cameltoe", "ecchi",
    "schoolgirl", "school girl", "school uniform", "loli", "thong",
    "garter", "garter belt", "porn", "pornography", "pornstar", "porn star",
    "adult model", "adult content", "onlyfans", "tushy", "playboy", "playmate",
    "nude", "nudity", "naked", "erotic", "erotica", "sexual", "sex",
    "fetish", "bdsm", "ass", "butt", "buttocks", "booty", "boob", "boobs",
    "big boobs", "breast", "breasts", "big breasts", "large breasts",
    "huge breasts", "busty"
)

$script:FilterStrictHardConcepts = @(
    $script:FilterReducedHardConcepts +
    @(
        "upskirt", "skirt lift", "panty shot", "pantyshot", "no panties",
        "topless", "nipple", "nipples", "areola", "areolas", "bare breasts",
        "see through", "see through clothes", "transparent clothes",
        "transparent clothing", "open shirt", "crotch", "spread legs",
        "legs spread", "micro bikini", "microkini", "micro skirt",
        "sexualized", "sexualised", "seductive", "sensual gaze",
        "lustful look", "provocative"
    )
)

$script:FilterFemaleSubjectWords = @(
    "woman", "women", "girl", "girls", "female", "females",
    "schoolgirl", "schoolgirls"
)

$script:FilterMaleSubjectWords = @(
    "man", "men", "male", "males", "boy", "boys", "guy", "guys",
    "gentleman", "gentlemen", "father", "dad"
)

$script:FilterStrictHumanLikeConcepts = @(
    "samurai", "warrior", "warriors", "knight", "knights", "soldier",
    "soldiers", "person", "human", "human character", "character portrait",
    "model", "celebrity", "singer", "actor", "actress", "cosplay",
    "cosplayer", "witch", "wizard", "maid", "nurse"
)

$script:FilterAnimeSafeNonHumanConcepts = @(
    "mecha", "vehicle", "vehicles", "car", "cars", "motorcycle",
    "motorcycles", "aircraft", "airplane", "airplanes", "spacecraft",
    "spaceship", "spaceships", "ship", "ships", "train", "trains",
    "locomotive", "landscape", "scenery", "architecture", "building",
    "buildings", "abstract", "minimalism", "pattern", "texture",
    "typography", "logo", "planet", "planets", "space art"
)

$script:FilterStrictWeightedSignals = [ordered]@{
    "stockings" = 3
    "fishnet" = 3
    "fishnet stockings" = 3
    "pantyhose" = 3
    "thighhighs" = 3
    "thigh highs" = 3
    "thigh high socks" = 3
    "thighs" = 2
    "miniskirt" = 3
    "short shorts" = 2
    "hot pants" = 3
    "bodysuit" = 3
    "leotard" = 3
    "bunny suit" = 3
    "bunny girl" = 3
    "bare shoulders" = 2
    "bare midriff" = 2
    "midriff" = 2
    "crop top" = 2
    "armpits" = 2
    "barefoot" = 2
    "feet" = 2
    "toes" = 2
    "thigh strap" = 2
    "high heels" = 1
    "kneeling" = 2
    "squatting" = 2
    "bent legs" = 1
    "legs up" = 2
    "rear view" = 2
    "looking back" = 1
    "looking over shoulder" = 2
    "parted lips" = 1
    "blushing" = 1
    "bed" = 2
    "bedroom" = 2
    "pillow" = 1
    "maid outfit" = 2
}

function ConvertTo-FilterNormalizedText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    return (
        $Value.ToLowerInvariant().
            Replace("_", " ").
            Replace("-", " ") -replace "\s+", " "
    ).Trim()
}

function Test-FilterPhrase {
    param(
        [string]$Value,
        [string]$Phrase
    )

    $v = ConvertTo-FilterNormalizedText $Value
    $p = ConvertTo-FilterNormalizedText $Phrase

    if (-not $v -or -not $p) {
        return $false
    }

    return (
        $v -eq $p -or
        $v.StartsWith("$p ") -or
        $v.EndsWith(" $p") -or
        $v.Contains(" $p ")
    )
}

function Test-FilterAnyConcept {
    param(
        [string]$Value,
        [string[]]$Concepts
    )

    foreach ($concept in $Concepts) {
        if (Test-FilterPhrase -Value $Value -Phrase $concept) {
            return $true
        }
    }
    return $false
}

function Test-FilterHasWord {
    param(
        [string]$Value,
        [string[]]$Words
    )

    $parts = @( (ConvertTo-FilterNormalizedText $Value) -split " " )
    foreach ($part in $parts) {
        if ($part -in $Words) {
            return $true
        }
    }
    return $false
}

function Get-EffectiveWallhavenQuery {
    param(
        [string]$UserQuery,
        [ValidateSet("Standard", "Reduced", "Strict")]
        [string]$Mode = "Reduced"
    )

    $q = if ($null -eq $UserQuery) { "" } else { $UserQuery.Trim() }

    if ($q -match "^(?i)id:[0-9]+$") {
        return $q
    }

    if ($Mode -eq "Standard") {
        return $q
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($q) {
        [void]$parts.Add($q)
    }
    foreach ($term in $script:FilterQueryExclusions) {
        [void]$parts.Add("-$term")
    }
    return ($parts -join " ")
}

function Test-ContentFilterRequiresMetadata {
    param(
        [ValidateSet("Standard", "Reduced", "Strict")]
        [string]$Mode
    )
    return ($Mode -ne "Standard")
}

function Get-ContentFilterDecision {
    param(
        [string]$WallhavenCategory,
        [string[]]$Tags,
        [ValidateSet("Standard", "Reduced", "Strict")]
        [string]$Mode = "Reduced"
    )

    $category = ConvertTo-FilterNormalizedText $WallhavenCategory
    if (-not $category) {
        $category = "unknown"
    }

    if ($Mode -eq "Standard") {
        return [pscustomobject]@{
            Allowed = $true
            Category = $category
            Score = 0
            BlockedTags = @()
            Reasons = @()
        }
    }

    $tagPairs = @(
        foreach ($tag in @($Tags)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$tag)) {
                [pscustomobject]@{
                    Original = [string]$tag
                    Normalized = ConvertTo-FilterNormalizedText ([string]$tag)
                }
            }
        }
    )

    $reducedBlocked = @(
        $tagPairs |
            Where-Object {
                Test-FilterAnyConcept -Value $_.Normalized -Concepts $script:FilterReducedHardConcepts
            } |
            ForEach-Object { $_.Original } |
            Select-Object -Unique
    )

    if ($Mode -eq "Reduced") {
        if ($reducedBlocked.Count -eq 0) {
            return [pscustomobject]@{
                Allowed = $true
                Category = $category
                Score = 0
                BlockedTags = @()
                Reasons = @()
            }
        }

        return [pscustomobject]@{
            Allowed = $false
            Category = $category
            Score = 100
            BlockedTags = $reducedBlocked
            Reasons = @($reducedBlocked | ForEach-Object { "hard:$_" })
        }
    }

    $hardBlocked = @(
        $tagPairs |
            Where-Object {
                Test-FilterAnyConcept -Value $_.Normalized -Concepts $script:FilterStrictHardConcepts
            } |
            ForEach-Object { $_.Original } |
            Select-Object -Unique
    )

    if ($hardBlocked.Count -gt 0) {
        return [pscustomobject]@{
            Allowed = $false
            Category = $category
            Score = 100
            BlockedTags = $hardBlocked
            Reasons = @($hardBlocked | ForEach-Object { "hard:$_" })
        }
    }

    $femaleTags = @(
        $tagPairs |
            Where-Object {
                $n = $_.Normalized
                (Test-FilterHasWord -Value $n -Words $script:FilterFemaleSubjectWords) -or
                $n -in @(
                    "anime girl", "anime girls", "video game girl", "video game girls",
                    "female character", "female characters", "fantasy girl", "fox girl",
                    "cat girl", "bunny girl", "horse girls", "girls with guns"
                )
            } |
            ForEach-Object { $_.Original } |
            Select-Object -Unique
    )

    if ($femaleTags.Count -gt 0) {
        return [pscustomobject]@{
            Allowed = $false
            Category = $category
            Score = 10
            BlockedTags = $femaleTags
            Reasons = @("strict:female_subject") + @($femaleTags | ForEach-Object { "subject:$_" })
        }
    }

    $maleSignal = $false
    foreach ($pair in $tagPairs) {
        $n = $pair.Normalized
        if (
            (Test-FilterHasWord -Value $n -Words $script:FilterMaleSubjectWords) -or
            $n -in @("anime boys", "anime boy", "male character", "male characters")
        ) {
            $maleSignal = $true
            break
        }
    }

    $safeAnimeNonHuman = $false
    foreach ($pair in $tagPairs) {
        if (Test-FilterAnyConcept -Value $pair.Normalized -Concepts $script:FilterAnimeSafeNonHumanConcepts) {
            $safeAnimeNonHuman = $true
            break
        }
    }

    if ($category -eq "people" -and -not $maleSignal) {
        return [pscustomobject]@{
            Allowed = $false; Category = $category; Score = 10; BlockedTags = @()
            Reasons = @("strict:people_unclassified")
        }
    }

    if ($category -eq "anime" -and -not $maleSignal -and -not $safeAnimeNonHuman) {
        return [pscustomobject]@{
            Allowed = $false; Category = $category; Score = 10; BlockedTags = @()
            Reasons = @("strict:anime_unclassified")
        }
    }

    if ($category -eq "general") {
        $ambiguousHuman = $false
        foreach ($pair in $tagPairs) {
            if (Test-FilterAnyConcept -Value $pair.Normalized -Concepts $script:FilterStrictHumanLikeConcepts) {
                $ambiguousHuman = $true
                break
            }
        }
        if ($ambiguousHuman -and -not $maleSignal) {
            return [pscustomobject]@{
                Allowed = $false; Category = $category; Score = 10; BlockedTags = @()
                Reasons = @("strict:general_human_unclassified")
            }
        }
    }
    elseif ($category -notin @("people", "anime")) {
        return [pscustomobject]@{
            Allowed = $false; Category = $category; Score = 10; BlockedTags = @()
            Reasons = @("strict:unknown_category")
        }
    }

    $score = 0
    $cues = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pair in $tagPairs) {
        foreach ($entry in $script:FilterStrictWeightedSignals.GetEnumerator()) {
            if (Test-FilterPhrase -Value $pair.Normalized -Phrase ([string]$entry.Key)) {
                $score += [int]$entry.Value
                [void]$cues.Add(("{0}+{1}" -f $pair.Original, [int]$entry.Value))
            }
        }
    }

    if ($score -ge 4) {
        return [pscustomobject]@{
            Allowed = $false
            Category = $category
            Score = $score
            BlockedTags = @($cues | ForEach-Object { ($_ -split "\+")[0] } | Select-Object -Unique)
            Reasons = @("strict:risk_score=$score") + @($cues | ForEach-Object { "cue:$_" })
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Category = $category
        Score = $score
        BlockedTags = @()
        Reasons = @()
    }
}

function New-EmptySharedHistoryState {
    [pscustomobject]@{
        version = 2
        updatedAt = (Get-SharedHistoryNow).ToString("o")
        entries = @()
        pending = @()
        migrations = [pscustomobject]@{
            rotatorV1 = $false
            screensaverV1 = $false
        }
    }
}

function ConvertTo-SharedDateTimeOffset {
    param([object]$Value)

    try {
        if ($null -eq $Value) {
            return $null
        }
        return [DateTimeOffset]::Parse([string]$Value)
    }
    catch {
        return $null
    }
}

function Invoke-WithSharedHistoryLock {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $mutex = $null
    $acquired = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:WallhavenSharedMutexName)
        try {
            $acquired = $mutex.WaitOne(5000)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "Timeout du verrou de l'historique Wallhaven partagé."
        }

        & $Action
    }
    finally {
        if ($mutex) {
            if ($acquired) {
                try { $mutex.ReleaseMutex() } catch {}
            }
            $mutex.Dispose()
        }
    }
}

function Read-SharedHistoryStateUnlocked {
    New-Item -ItemType Directory -Path $script:WallhavenSharedBaseDir -Force | Out-Null

    if (-not (Test-Path $script:WallhavenSharedHistoryPath)) {
        return (New-EmptySharedHistoryState)
    }

    try {
        $state = Get-Content -Path $script:WallhavenSharedHistoryPath -Raw | ConvertFrom-Json
        if ([int]$state.version -ne 2) {
            return (New-EmptySharedHistoryState)
        }
        if ($null -eq $state.entries) {
            $state | Add-Member -NotePropertyName entries -NotePropertyValue @() -Force
        }
        if ($null -eq $state.pending) {
            $state | Add-Member -NotePropertyName pending -NotePropertyValue @() -Force
        }
        if ($null -eq $state.migrations) {
            $state | Add-Member `
                -NotePropertyName migrations `
                -NotePropertyValue ([pscustomobject]@{ rotatorV1 = $false; screensaverV1 = $false }) `
                -Force
        }
        if (-not $state.migrations.PSObject.Properties["rotatorV1"]) {
            $state.migrations | Add-Member -NotePropertyName rotatorV1 -NotePropertyValue $false -Force
        }
        if (-not $state.migrations.PSObject.Properties["screensaverV1"]) {
            $state.migrations | Add-Member -NotePropertyName screensaverV1 -NotePropertyValue $false -Force
        }
        if (-not $state.PSObject.Properties["updatedAt"]) {
            $state | Add-Member -NotePropertyName updatedAt -NotePropertyValue "" -Force
        }
        return $state
    }
    catch {
        throw "Historique Wallhaven partagé illisible : $($_.Exception.Message)"
    }
}

function Write-SharedHistoryStateUnlocked {
    param([Parameter(Mandatory = $true)]$State)

    New-Item -ItemType Directory -Path $script:WallhavenSharedBaseDir -Force | Out-Null

    if (-not $State.PSObject.Properties["updatedAt"]) {
        $State | Add-Member -NotePropertyName updatedAt -NotePropertyValue "" -Force
    }
    $State.updatedAt = (Get-SharedHistoryNow).ToString("o")

    $nonce = [guid]::NewGuid().ToString("N")
    $tmp = Join-Path $script:WallhavenSharedBaseDir ("history.{0}.tmp" -f $nonce)
    $backup = Join-Path $script:WallhavenSharedBaseDir ("history.{0}.bak" -f $nonce)

    try {
        $json = $State | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($true)))

        if (Test-Path $script:WallhavenSharedHistoryPath) {
            # Windows PowerShell 5.1 runs on .NET Framework. Its File.Replace
            # overload rejects a null backup path on some systems. Use a real,
            # same-directory backup path, then remove it after the atomic swap.
            [IO.File]::Replace(
                $tmp,
                $script:WallhavenSharedHistoryPath,
                $backup,
                $true
            )
        }
        else {
            [IO.File]::Move($tmp, $script:WallhavenSharedHistoryPath)
        }
    }
    finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Remove-Item $backup -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ExpiredSharedPendingUnlocked {
    param($State)

    $now = Get-SharedHistoryNow
    $State.pending = @(
        foreach ($item in @($State.pending)) {
            $expires = ConvertTo-SharedDateTimeOffset $item.expiresAt
            if ($expires -and $expires -gt $now) {
                $item
            }
        }
    )
}

function Import-LegacyHistoryUnlocked {
    param(
        $State,
        [string]$LegacyPath,
        [string]$MigrationProperty,
        [ValidateSet("Rotator", "Screensaver")]
        [string]$Format
    )

    if ([bool]$State.migrations.$MigrationProperty) {
        return
    }

    $ids = @()
    if (Test-Path $LegacyPath) {
        try {
            $raw = Get-Content -Path $LegacyPath -Raw | ConvertFrom-Json
            if ($Format -eq "Rotator" -and $raw.PSObject.Properties["ids"]) {
                $ids = @($raw.ids)
            }
            elseif ($Format -eq "Screensaver") {
                $ids = @($raw)
            }
        }
        catch {}
    }

    $existing = @{}
    foreach ($entry in @($State.entries)) {
        $existing[[string]$entry.wallhavenId] = $true
    }

    # Legacy histories do not contain timestamps. Import them before today so they
    # remain a long-term preference but never fabricate a same-day hard exclusion.
    $baseTime = (Get-SharedHistoryNow).Date.AddDays(-1)
    $offset = 0
    foreach ($idValue in $ids) {
        $id = [string]$idValue
        if (-not $id -or $existing.ContainsKey($id)) {
            continue
        }
        $State.entries += [pscustomobject]@{
            wallhavenId = $id
            shownAt = $baseTime.AddSeconds($offset).ToString("o")
        }
        $existing[$id] = $true
        $offset++
    }

    $State.migrations.$MigrationProperty = $true
}

function Invoke-SharedHistoryMigrationUnlocked {
    param($State)

    Import-LegacyHistoryUnlocked `
        -State $State `
        -LegacyPath $script:WallhavenLegacyRotatorHistoryPath `
        -MigrationProperty "rotatorV1" `
        -Format "Rotator"

    Import-LegacyHistoryUnlocked `
        -State $State `
        -LegacyPath $script:WallhavenLegacyScreensaverHistoryPath `
        -MigrationProperty "screensaverV1" `
        -Format "Screensaver"
}

function Normalize-SharedHistoryEntriesUnlocked {
    param($State)

    $latest = @{}
    foreach ($entry in @($State.entries)) {
        $id = [string]$entry.wallhavenId
        $shown = ConvertTo-SharedDateTimeOffset $entry.shownAt
        if (-not $id -or -not $shown) { continue }

        if (-not $latest.ContainsKey($id) -or $shown -gt $latest[$id].Shown) {
            $latest[$id] = [pscustomobject]@{
                Id = $id
                Shown = $shown
            }
        }
    }

    $today = (Get-SharedHistoryNow).LocalDateTime.Date
    $todayItems = @(
        $latest.Values |
            Where-Object { ([DateTimeOffset]$_.Shown).LocalDateTime.Date -eq $today } |
            Sort-Object Shown
    )
    $olderItems = @(
        $latest.Values |
            Where-Object { ([DateTimeOffset]$_.Shown).LocalDateTime.Date -ne $today } |
            Sort-Object Shown |
            Select-Object -Last $script:WallhavenSharedHistoryLimit
    )
    $ordered = @($olderItems + $todayItems | Sort-Object Shown)

    $State.entries = @(
        foreach ($item in $ordered) {
            [pscustomobject]@{
                wallhavenId = [string]$item.Id
                shownAt = ([DateTimeOffset]$item.Shown).ToString("o")
            }
        }
    )
}

function Get-SharedHistorySnapshot {
    Invoke-WithSharedHistoryLock {
        $state = Read-SharedHistoryStateUnlocked
        Invoke-SharedHistoryMigrationUnlocked $state
        Remove-ExpiredSharedPendingUnlocked $state
        Normalize-SharedHistoryEntriesUnlocked $state
        Write-SharedHistoryStateUnlocked $state

        $today = (Get-SharedHistoryNow).LocalDateTime.Date
        # Native PowerShell hashtables are case-insensitive by default and expose
        # Contains(key)/Count. They avoid generic-constructor edge cases on
        # Windows PowerShell 5.1 while keeping the caller contract unchanged.
        $todayIds = @{}
        $historyIds = @{}
        $pendingIds = @{}
        $lastShown = @{}

        foreach ($entry in @($state.entries)) {
            $id = [string]$entry.wallhavenId
            $shown = ConvertTo-SharedDateTimeOffset $entry.shownAt
            if (-not $id -or -not $shown) { continue }

            $historyIds[$id] = $true
            $lastShown[$id] = $shown
            if ($shown.LocalDateTime.Date -eq $today) {
                $todayIds[$id] = $true
            }
        }

        foreach ($reservation in @($state.pending)) {
            $id = [string]$reservation.wallhavenId
            if ($id) { $pendingIds[$id] = $true }
        }

        [pscustomobject]@{
            SeenToday = $todayIds
            History = $historyIds
            Pending = $pendingIds
            LastShown = $lastShown
            SeenTodayCount = $todayIds.Count
            HistoryCount = $historyIds.Count
            PendingCount = $pendingIds.Count
        }
    }
}

function Reserve-SharedWallpaper {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [string]$Owner = $script:WallhavenSharedOwner
    )

    Invoke-WithSharedHistoryLock {
        $state = Read-SharedHistoryStateUnlocked
        Invoke-SharedHistoryMigrationUnlocked $state
        Remove-ExpiredSharedPendingUnlocked $state
        Normalize-SharedHistoryEntriesUnlocked $state

        $today = (Get-SharedHistoryNow).LocalDateTime.Date
        foreach ($entry in @($state.entries)) {
            if ([string]$entry.wallhavenId -ne $Id) { continue }
            $shown = ConvertTo-SharedDateTimeOffset $entry.shownAt
            if ($shown -and $shown.LocalDateTime.Date -eq $today) {
                Write-SharedHistoryStateUnlocked $state
                return [pscustomobject]@{ Reserved = $false; Reason = "daily_repeat" }
            }
        }

        foreach ($reservation in @($state.pending)) {
            if ([string]$reservation.wallhavenId -eq $Id -and [string]$reservation.owner -ne $Owner) {
                Write-SharedHistoryStateUnlocked $state
                return [pscustomobject]@{ Reserved = $false; Reason = "pending_duplicate" }
            }
        }

        $state.pending = @(
            @($state.pending) |
                Where-Object {
                    -not (
                        [string]$_.wallhavenId -eq $Id -and
                        [string]$_.owner -eq $Owner
                    )
                }
        )

        $now = Get-SharedHistoryNow
        $state.pending += [pscustomobject]@{
            wallhavenId = $Id
            owner = $Owner
            reservedAt = $now.ToString("o")
            expiresAt = $now.AddMinutes($script:WallhavenSharedPendingMinutes).ToString("o")
        }

        Write-SharedHistoryStateUnlocked $state
        return [pscustomobject]@{ Reserved = $true; Reason = "reserved" }
    }
}

function Release-SharedWallpaperReservation {
    param(
        [string]$Id,
        [string]$Owner = $script:WallhavenSharedOwner
    )

    if (-not $Id) { return }

    Invoke-WithSharedHistoryLock {
        $state = Read-SharedHistoryStateUnlocked
        Remove-ExpiredSharedPendingUnlocked $state
        $state.pending = @(
            @($state.pending) |
                Where-Object {
                    -not (
                        [string]$_.wallhavenId -eq $Id -and
                        [string]$_.owner -eq $Owner
                    )
                }
        )
        Write-SharedHistoryStateUnlocked $state
    } | Out-Null
}

function Commit-SharedWallpaperShown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [string]$Owner = $script:WallhavenSharedOwner
    )

    Invoke-WithSharedHistoryLock {
        $state = Read-SharedHistoryStateUnlocked
        Invoke-SharedHistoryMigrationUnlocked $state
        Remove-ExpiredSharedPendingUnlocked $state

        $state.pending = @(
            @($state.pending) |
                Where-Object {
                    -not (
                        [string]$_.wallhavenId -eq $Id -and
                        [string]$_.owner -eq $Owner
                    )
                }
        )

        $state.entries = @(
            @($state.entries) |
                Where-Object { [string]$_.wallhavenId -ne $Id }
        )
        $state.entries += [pscustomobject]@{
            wallhavenId = $Id
            shownAt = (Get-SharedHistoryNow).ToString("o")
        }

        Normalize-SharedHistoryEntriesUnlocked $state
        Write-SharedHistoryStateUnlocked $state
    } | Out-Null
}

function Reset-SharedWallpaperHistory {
    Invoke-WithSharedHistoryLock {
        $state = New-EmptySharedHistoryState
        $state.migrations.rotatorV1 = $true
        $state.migrations.screensaverV1 = $true
        Write-SharedHistoryStateUnlocked $state
    } | Out-Null
}
