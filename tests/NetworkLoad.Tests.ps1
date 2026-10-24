param([string]$BaselineRuntime='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SelectionEngine.Tests.ps1') -LoadFixtureOnly -RuntimeSource $BaselineRuntime
try {
    $MetadataChecksPerSelection=if($BaselineRuntime){16}else{6}
    $rows=@()
    function Drain-Selection {
        for($tick=0;$tick -lt 600 -and $script:State -ne 'Idle';$tick++) {
            Process-AsyncState
            Advance-FixtureClock -Seconds 0.1
        }
        Assert ($script:State -eq 'Idle') 'Selection did not terminate within 60 virtual seconds.'
    }
    function Supply-Page([int]$Count=24,[switch]$Warm,[switch]$Reject) {
        $data=@(foreach($i in 1..$Count) { Candidate "load$i" })
        $page=ConvertTo-Json -Depth 5 -InputObject @{data=$data;meta=@{last_page=1}}
        foreach($resolution in @($true,$false)) {
            foreach($policy in @($true,$false)) {
                $url=Get-ApiUrl -UseResolution $resolution -UsePolicyQuery $policy
                $script:HttpClient.UrlReplies[$url]=$page
            }
        }
        $script:HttpClient.DownloadBytes=$fixtureImage
        foreach($item in $data) {
            $tags=@(if($Reject){'women'}else{'forest'})
            $script:HttpClient.UrlReplies["https://wallhaven.cc/api/v1/w/$($item.id)"] = ConvertTo-Json -Depth 5 -InputObject @{data=@{id=$item.id;category='general';tags=@(@{name=$tags[0]})}}
            if($Warm) {
                Remember-WallhavenMetadata -Id $item.id -Category general -Tags $tags
                $entry=$script:MetadataCache[$item.id]
                $entry | Add-Member candidate $item
                $entry | Add-Member selectionKey (Get-LocalSelectionKey)
                [IO.File]::WriteAllBytes((Join-Path $CacheDir "wallhaven-$($item.id).jpg"),$fixtureImage)
            }
        }
    }
    function Measure-Scenario([string]$Name,[int]$Rotations,[double]$Interval,[switch]$Warm,[switch]$Reject,[switch]$Saturated) {
        Reset-Fixture
        $CacheDir=Join-Path $testRoot $Name
        [void][IO.Directory]::CreateDirectory($CacheDir)
        Supply-Page -Warm:$Warm -Reject:$Reject
        if($Saturated) {
            $state=New-EmptySharedHistoryState
            $state.migrations.rotatorV1=$true; $state.migrations.screensaverV1=$true
            $state.entries=@(foreach($i in 1..5000) {
                [pscustomobject]@{wallhavenId=$(if($i -le 24){"load$i"}else{"old$i"});shownAt='2026-10-22T10:00:00Z'}
            })
            Write-SharedHistoryStateUnlocked $state
        }
        $perChange=@(); $durations=@(); $hits=0; $metadata=0; $searchHits=0
        foreach($rotation in 1..$Rotations) {
            $before=$script:HttpClient.Times.Count
            $selectionStart=Get-SharedHistoryNow
            Start-WallpaperChange -Reason $(if($Interval -ge 60){'Auto'}else{'Manual'})
            Drain-Selection
            $perChange+=($script:HttpClient.Times.Count-$before)
            $durations+=((Get-SharedHistoryNow)-$selectionStart).TotalSeconds
            if(-not $BaselineRuntime) {
                $s=$script:SelectionStats
                Assert ($s.searches -le 2 -and $s.metadata -le 6) 'Per-change search/metadata allowance exceeded.'
                $hits+=$s.metadataHits; $metadata+=$s.metadata; $searchHits+=$s.searchHits
            }
            Advance-FixtureClock -Seconds ([Math]::Max(0.1,$Interval-((Get-SharedHistoryNow)-$selectionStart).TotalSeconds))
        }
        $api=@(foreach($ticks in $script:HttpClient.Times) { [DateTimeOffset]::new($ticks,[TimeSpan]::Zero) })
        $max=0
        foreach($t in $api) { $max=[Math]::Max($max,@($api | Where-Object { $_ -ge $t.AddSeconds(-60) -and $_ -le $t }).Count) }
        if(-not $BaselineRuntime) {
            Assert ($max -le 12) "Sliding-window budget exceeded in $Name."
            Assert (($perChange|Measure-Object -Maximum).Maximum -le 8) 'More than 8 API calls per change.'
            if($Reject) { Assert ($script:Applied.Count -eq 0) 'Strict was relaxed to produce a result.' }
            else { Assert ($script:Applied.Count -ge [Math]::Min(20,$Rotations)) "Selection starved in $Name." }
            Assert (@($script:Logs | Where-Object {$_ -like 'API GET *'}).Count -eq $api.Count) 'API diagnostics do not match actual transport calls.'
        }
        $cachePercent=if($BaselineRuntime){$null}elseif($hits+$metadata -gt 0){[Math]::Round(100.0*$hits/($hits+$metadata),1)}else{0}
        Write-Host ("Completed {0}: applied={1}, API={2}, max60={3}" -f $Name,$script:Applied.Count,$api.Count,$max)
        return [pscustomobject]@{scenario=$Name;rotations=$Rotations;applied=$script:Applied.Count;
            search=@($script:HttpClient.Requests|Where-Object{$_ -like '*/search?*'}).Count;
            metadata=@($script:HttpClient.Requests|Where-Object{$_ -like '*/api/v1/w/*'}).Count;
            max60=$max;firstChange=$perChange[0];maxPerChange=($perChange|Measure-Object -Maximum).Maximum;
            strictCachePercent=$cachePercent;searchCacheUses=$searchHits;
            selectionMedianVirtualSeconds=(@($durations|Sort-Object))[[int][Math]::Floor(($durations.Count-1)/2)];
            selectionMaxVirtualSeconds=($durations|Measure-Object -Maximum).Maximum}
    }
    $rows+=Measure-Scenario -Name cold_manual -Rotations 20 -Interval 0.1
    $rows+=Measure-Scenario -Name warm_manual -Rotations 20 -Interval 0.1 -Warm
    $rows+=Measure-Scenario -Name cold_auto -Rotations 60 -Interval 60
    $rows+=Measure-Scenario -Name saturated_auto -Rotations 30 -Interval 60 -Saturated
    $rows+=Measure-Scenario -Name rejected_manual -Rotations 20 -Interval 0.1 -Reject
    if($BaselineRuntime) {
        Assert ($rows[0].max60 -gt 12) 'Baseline unexpectedly already obeyed the new budget.'
    }
    else {
        Reset-Fixture
        Supply-Page
        Start-WallpaperChange -Reason Manual
        foreach($click in 1..200) { Start-WallpaperChange -Reason Manual }
        Drain-Selection
        Assert ($script:Applied.Count -eq 2 -and $script:HttpClient.Times.Count -le 3) 'Busy clicks were not coalesced or triggered redundant searches.'

        Reset-Fixture
        $script:HttpClient.Replies.Enqueue('ERROR:429 1800')
        Start-WallpaperChange; Drain-Selection
        $until=$script:ApiRetryAfter
        $script:ApiRetryAfter=$null
        $script:MetadataCache=@{}; $script:SearchCache=@{}
        Load-MetadataCache; Load-SearchCache
        foreach($click in 1..100) { Start-WallpaperChange -Reason Manual; Drain-Selection; Advance-FixtureClock -Seconds 0.1 }
        Assert ($script:HttpClient.Times.Count -eq 1) 'Restart/manual click bypassed persisted Retry-After.'
        Set-SharedHistoryTestNow (([DateTimeOffset]$until).AddSeconds(1).ToString('o'))
        $script:HttpClient.NowTicks=(Get-SharedHistoryNow).UtcTicks
        Supply-Page
        Start-WallpaperChange; Drain-Selection
        Assert ($script:Applied.Count -eq 1) 'Engine did not recover after Retry-After.'
        Write-Host 'In-flight click coalescing and persisted 429 recovery: OK'

        Reset-Fixture
        Supply-Page
        Start-WallpaperChange; Drain-Selection
        $before=$script:HttpClient.Times.Count
        $script:MetadataCache=@{}; $script:SearchCache=@{}
        Load-MetadataCache; Load-SearchCache
        Start-WallpaperChange; Drain-Selection
        Assert ($script:HttpClient.Times.Count-$before -eq 1) 'Restart did not reuse search discoveries (only new candidate metadata is needed).'
        $before=$script:HttpClient.Times.Count
        $script:Settings.query='different user query'
        Start-WallpaperChange; Drain-Selection
        Assert ($script:HttpClient.Times.Count -eq $before+1) 'Changed query reused unrelated discoveries.'
        Advance-FixtureClock -Seconds 961
        Load-SearchCache
        Assert ($script:SearchCache.Count -eq 0) 'Expired search cache was reused.'
        [IO.File]::WriteAllText($SearchCachePath,'{bad')
        Load-SearchCache
        Assert ($script:SearchCache.Count -eq 0) 'Corrupted search cache was trusted.'
        Write-Host 'Search cache restart, query isolation, expiry and corruption: OK'
        $invalid=Candidate wrongratio
        $invalid.dimension_x=2560
        $invalid.dimension_y=1440
        Assert (@(Get-EligibleCandidates -Data @($invalid)).Count -eq 0) 'Invalid 16:9 cache/search candidate passed the active 32:9 constraint.'

        foreach($stage in @('Api','Metadata','Download','ApiWait')) {
            Reset-Fixture
            Initialize-SelectionCycle
            $token=$script:SelectionCancellation.Token
            $script:Candidate=Candidate stalled
            $reservation=Reserve-SharedWallpaper -Id stalled
            $script:ReservedCandidateId='stalled'
            $pending=New-Object 'Threading.Tasks.TaskCompletionSource[string]'
            $script:State=$stage
            if($stage -eq 'Api') { $script:ApiTask=$pending.Task }
            if($stage -eq 'Metadata') { $script:MetadataTask=$pending.Task }
            if($stage -eq 'Download') { $script:DownloadTask=$pending.Task }
            if($stage -eq 'ApiWait') { $script:DeferredApiRequest=[pscustomobject]@{retryAt=(Get-SharedHistoryNow).AddSeconds(90);selectionKey=(Get-LocalSelectionKey)} }
            Advance-FixtureClock -Seconds 46
            Process-AsyncState
            Assert ($script:State -eq 'Idle' -and (Get-SharedHistorySnapshot).PendingCount -eq 0) "Deadline did not stop $stage and release reservation."
            Assert ($token.IsCancellationRequested) 'Expired selection was not cancelled at the transport boundary.'
        }
        Reset-Fixture
        $script:HttpClient.Replies.Enqueue('ERROR:429 1800')
        Start-WallpaperChange
        Advance-FixtureClock -Seconds 46
        Process-AsyncState
        $script:ApiRetryAfter=$null
        Start-WallpaperChange; Drain-Selection
        Assert ($script:HttpClient.Times.Count -eq 1) 'An already received 429 was discarded at the deadline.'

        Reset-Fixture
        $fn=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-CandidateDiagnostic'},$true)|Select-Object -First 1
        Invoke-Expression $fn.Extent.Text
        $script:CandidateDiagnostics=@{daily=0;recent=0;pending=0;strict=0;accepted=0}
        Initialize-SelectionCycle
        foreach($i in 1..5000) { Write-CandidateDiagnostic -Kind strict -Id "rejected$i" }
        Write-SelectionSummary -Outcome none
        Assert ($script:Logs.Count -eq 1 -and $script:Logs[0] -match 'strict=5000') 'Repeated diagnostics were not aggregated.'
    }
    $rows | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    $outputDirectory=Join-Path $Root 'dist'
    [void][IO.Directory]::CreateDirectory($outputDirectory)
    $report=Join-Path $outputDirectory $(if($BaselineRuntime){'network-budget-baseline.json'}else{'network-budget-results.json'})
    [IO.File]::WriteAllText($report,(ConvertTo-Json -Depth 6 -InputObject @{method='virtual clock, real engine, fake HTTP/native wallpaper, inclusive sliding windows';baseline=[bool]$BaselineRuntime;rows=$rows}),(New-Object Text.UTF8Encoding($true)))
    Write-Host 'Network load tests: OK'
}
finally {
    Set-SharedHistoryTestNow $null
    foreach($name in @('WALLHAVEN_SHARED_BASE_DIR','WALLHAVEN_SHARED_MUTEX_NAME','WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH','WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
