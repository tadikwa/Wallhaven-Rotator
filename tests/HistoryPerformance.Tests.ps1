param([switch]$MeasureOnly)
$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('wallhaven-history-perf-'+[guid]::NewGuid().ToString('N'))
$env:WALLHAVEN_SHARED_BASE_DIR=$testRoot
$env:WALLHAVEN_SHARED_MUTEX_NAME='Local\WallhavenHistoryPerf-'+[guid]::NewGuid().ToString('N')
$env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH=Join-Path $testRoot 'legacy-r.json'
$env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH=Join-Path $testRoot 'legacy-s.json'
try {
    . (Join-Path $Root 'src/Wallhaven-SharedPolicy.ps1')
    $state=New-EmptySharedHistoryState
    $state.migrations.rotatorV1=$true; $state.migrations.screensaverV1=$true
    $state.entries=@(foreach($i in 1..5000) {
        [pscustomobject]@{wallhavenId="perf$i";shownAt=(Get-SharedHistoryNow).AddDays(-1).AddSeconds(-$i).ToString('o')}
    })
    $state.entries[0].shownAt=(Get-SharedHistoryNow).ToString('o')
    $state.pending=@([pscustomobject]@{wallhavenId='expired';owner='other';expiresAt=(Get-SharedHistoryNow).AddMinutes(-1).ToString('o')})
    Write-SharedHistoryStateUnlocked $state
    $before=[IO.File]::ReadAllText($script:WallhavenSharedHistoryPath)
    $script:writes=0; $script:normalizations=0
    $script:OriginalWrite=(Get-Item Function:Write-SharedHistoryStateUnlocked).ScriptBlock
    $script:OriginalNormalize=(Get-Item Function:Normalize-SharedHistoryEntriesUnlocked).ScriptBlock
    function Write-SharedHistoryStateUnlocked { param($State) $script:writes++; & $script:OriginalWrite $State }
    function Normalize-SharedHistoryEntriesUnlocked { param($State) $script:normalizations++; & $script:OriginalNormalize $State }
    $durations=@(foreach($i in 1..5) {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $snapshot=Get-SharedHistorySnapshot
        $clock.Stop()
        if($snapshot.HistoryCount -ne 5000 -or $snapshot.SeenTodayCount -ne 1 -or $snapshot.PendingCount -ne 0) { throw 'Snapshot lost daily/history/pending semantics.' }
        $clock.Elapsed.TotalMilliseconds
    })
    $row=[pscustomobject]@{entries=5000;reads=5;writes=$script:writes;normalizations=$script:normalizations;medianMs=($durations|Sort-Object)[2];maxMs=($durations|Measure-Object -Maximum).Maximum}
    $row|ConvertTo-Json -Compress|Write-Host
    if(-not $MeasureOnly) {
        if($script:writes -ne 0 -or $script:normalizations -ne 0) { throw 'Unchanged history reads must not normalize or rewrite 5000 entries.' }
        if([IO.File]::ReadAllText($script:WallhavenSharedHistoryPath) -ne $before) { throw 'Read changed user history bytes.' }
        $state=New-EmptySharedHistoryState
        Write-SharedHistoryStateUnlocked $state
        [IO.File]::WriteAllText($env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH,'{"ids":["legacy"]}')
        $script:writes=0
        $migrated=Get-SharedHistorySnapshot
        $again=Get-SharedHistorySnapshot
        if(-not $migrated.History.Contains('legacy') -or $script:writes -ne 1) { throw 'Migration must run once and persist.' }
        Write-Host 'History read performance and migration tests: OK'
    }
}
finally {
    foreach($name in @('WALLHAVEN_SHARED_BASE_DIR','WALLHAVEN_SHARED_MUTEX_NAME','WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH','WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    if($testRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
