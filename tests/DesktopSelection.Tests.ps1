param([string]$BaselineRuntime='',[string]$BaselinePolicy='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'SelectionEngine.Tests.ps1') -LoadFixtureOnly -RuntimeSource $BaselineRuntime
$worker=$null
try {
    . (Join-Path $Root 'src/Wallhaven-Desktop.ps1')
    foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)) {
        if($fn.Name -in @('Refresh-SharedHistoryView','Get-CurrentLogPath','Remove-ExpiredLogs','Trim-WallpaperCache','Write-CandidateDiagnostic')) { Invoke-Expression $fn.Extent.Text }
    }
    if($BaselinePolicy) { . $BaselinePolicy }
    Reset-Fixture
    $script:Settings.contentFilter='Strict'
    $AppVersion='1.2.0'; $LogDir=Join-Path $testRoot 'logs'
    [void][IO.Directory]::CreateDirectory($LogDir)
    $CacheMaxFiles=50; $CacheMaxBytes=524288000; $HistoryMaxIds=5000
    $LogRetentionDays=7; $LogMaxBytes=2097152; $BaseDir=$testRoot
    $state=New-EmptySharedHistoryState
    $state.migrations.rotatorV1=$true; $state.migrations.screensaverV1=$true
    $state.entries=@(foreach($i in 1..5000) { [pscustomobject]@{wallhavenId=$(if($i -eq 1){'warmone'}elseif($i -eq 2){'warmtwo'}else{"old$i"});shownAt=[DateTimeOffset]::Now.AddDays(-1).ToString('o')} })
    Write-SharedHistoryStateUnlocked $state
    $script:State='Idle'
    $script:CandidateDiagnostics=@{daily=0;recent=0;pending=0;strict=0;accepted=0}
    Set-SharedHistoryTestNow $null
    foreach($id in @('warmone','warmtwo')) {
        $candidate=Candidate $id
        Remember-WallhavenMetadata -Id $id -Category general -Tags @('forest')
        $script:MetadataCache[$id]|Add-Member candidate $candidate
        $script:MetadataCache[$id]|Add-Member selectionKey (Get-LocalSelectionKey)
        [IO.File]::WriteAllBytes((Join-Path $CacheDir "wallhaven-$id.jpg"),$fixtureImage)
    }
    Save-MetadataCache
    if($BaselineRuntime) {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Start-WallpaperChange -Reason Manual
        $clock.Stop()
        if(-not $script:LastWallpaperId) { Write-Host ($script:Logs -join "`n") }
        Assert ($script:LastWallpaperId -in @('warmone','warmtwo')) 'Baseline warm selection failed.'
        Write-Host "Baseline warm 5000-entry local selection real_ms=$($clock.Elapsed.TotalMilliseconds) API=$($script:HttpClient.Requests.Count)"
    }
    else {
        $variables=@{}
        foreach($name in @('AppVersion','BaseDir','CacheDir','LogDir','MetadataCachePath','SearchCachePath',
            'MetadataCacheMaxEntries','MetadataCacheMaxAgeDays','MetadataChecksPerSelection','SearchRequestsPerSelection',
            'ApiSelectionAttemptsPerMode','ApiBase','HistoryMaxIds','CacheMaxFiles','CacheMaxBytes','LogRetentionDays','LogMaxBytes','HttpClient')) {
            $variables[$name]=Get-Variable -Name $name -ValueOnly
        }
        $worker=New-WallhavenSelectionWorker -Functions (Get-WallhavenEngineFunctions) -Variables $variables -PolicyPath (Join-Path $Root 'src/Wallhaven-SharedPolicy.ps1')
        $script:SelectionWorker=$worker
        $script:Exiting=$false
        $script:DesktopDiagnostics=$null
        $clock=[Diagnostics.Stopwatch]::StartNew()
        Start-DesktopWallpaperChange -Reason Manual
        $enqueueMs=$clock.Elapsed.TotalMilliseconds
        foreach($click in 1..100) { Start-DesktopWallpaperChange -Reason Manual }
        $selections=@()
        $timeout=[Diagnostics.Stopwatch]::StartNew()
        while($worker.Async -and $timeout.Elapsed.TotalSeconds -lt 30) {
            if($worker.Async.IsCompleted) { Receive-DesktopSelection; $selections+=([double]$script:DesktopDiagnostics.elapsedMs) }
            Start-Sleep -Milliseconds 10
        }
        Assert ($selections.Count -eq 2 -and (Get-SharedHistorySnapshot).SeenTodayCount -eq 2) 'Coalesced desktop selections or daily commits failed.'
        Assert ($script:HttpClient.Requests.Count -eq 0) 'Warm desktop selection emitted unnecessary network calls.'
        Assert ((Get-SharedHistorySnapshot).PendingCount -eq 0) 'Desktop selection leaked reservations.'
        Write-Host "Worker warm 5000-entry real_ms=$(ConvertTo-Json -Compress -InputObject $selections) UI_enqueue_ms=$enqueueMs API=0"
        # The cached view never bypasses the authoritative reservation after another client commits.
        $script:SelectionHistorySnapshot=$null
        $snapshot=Get-SelectionHistorySnapshot
        Commit-SharedWallpaperShown -Id external -Owner screensaver
        $again=Get-SelectionHistorySnapshot
        Assert ([object]::ReferenceEquals($snapshot,$again)) 'Repeated selection consultation reparsed history.'
        Assert (-not (Reserve-SharedWallpaper -Id external).Reserved) 'Cached snapshot bypassed a new Screensaver daily exclusion.'
        $script:HttpClient.Replies.Enqueue('ERROR:429 1800')
        Start-DesktopWallpaperChange -Reason Manual
        $timeout.Restart()
        while($worker.Async -and $timeout.Elapsed.TotalSeconds -lt 15) { Receive-DesktopSelection; Start-Sleep -Milliseconds 10 }
        Assert ($script:HttpClient.Requests.Count -eq 1 -and $script:NextChange -gt [DateTime]::Now.AddMinutes(29)) 'Worker lost 429 or its UI scheduling deadline.'
        Assert ($script:DesktopDiagnostics.todayCount -eq 3) 'Worker returned counters preceding the external Screensaver commit.'
        Start-DesktopWallpaperChange -Reason Manual
        foreach($click in 1..100) { Start-DesktopWallpaperChange -Reason Manual }
        $timeout.Restart()
        while($worker.Async -and $timeout.Elapsed.TotalSeconds -lt 15) { Receive-DesktopSelection; Start-Sleep -Milliseconds 10 }
        Assert ($script:HttpClient.Requests.Count -eq 1) 'Manual worker requests bypassed persisted 429.'
        Close-WallhavenSelectionWorker -Worker $worker
        $worker=$null
        Write-Host 'Real engine in dedicated worker, 100 manual clicks coalesced, warm cache and shared-history race: OK'
    }
}
finally {
    if($worker) { Stop-WallhavenWorkerJob $worker; if($worker.Async){[void]$worker.Async.AsyncWaitHandle.WaitOne(10000);[void](Receive-WallhavenWorkerJob $worker)};Close-WallhavenSelectionWorker $worker }
    Set-SharedHistoryTestNow $null
    foreach($name in @('WALLHAVEN_SHARED_BASE_DIR','WALLHAVEN_SHARED_MUTEX_NAME','WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH','WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    if($testRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
