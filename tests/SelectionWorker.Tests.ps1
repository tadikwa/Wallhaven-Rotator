$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path $env:TEMP ('wallhaven-worker-'+[guid]::NewGuid().ToString('N'))
$env:WALLHAVEN_SHARED_BASE_DIR=$testRoot
$env:WALLHAVEN_SHARED_MUTEX_NAME='Local\WallhavenWorkerTest-'+[guid]::NewGuid().ToString('N')
$env:WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH=Join-Path $testRoot 'none-r'
$env:WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH=Join-Path $testRoot 'none-s'
$worker=$null
try {
    $helper=Join-Path $Root 'src/Wallhaven-Desktop.ps1'
    if(-not (Test-Path $helper)) { throw 'Dedicated selection runspace host is missing.' }
    . $helper
    . (Join-Path $Root 'src/Wallhaven-SharedPolicy.ps1')
    Add-Type -AssemblyName WindowsBase
    $functions=@{
        'New-WallhavenHttpClient'=(Get-Item Function:New-WallhavenHttpClient).ScriptBlock.ToString()
        'Load-MetadataCache'='';'Load-SearchCache'='';'Refresh-SharedHistoryView'=''
        'Start-WallpaperChange'='param($Reason) $script:ReservedCandidateId="worker"; [void](Reserve-SharedWallpaper -Id worker); $script:State="Metadata"; if($script:SimulateApply){$script:LastWallpaperId="applied";$script:AppliedSignal.Set()}; Start-Sleep -Milliseconds 400'
        'Process-AsyncState'='$script:State="Idle"'
        'Stop-SelectionRequests'=''
        'Finish-NoEligibleCandidate'='param($Reason) $script:State="Idle"'
        'Write-Log'='param($Level,$Message)'
    }
    $signal=New-Object Threading.ManualResetEventSlim($false)
    $worker=New-WallhavenSelectionWorker -Functions $functions -Variables @{AppVersion="1.2.0";AppliedSignal=$signal} -PolicyPath (Join-Path $Root 'src/Wallhaven-SharedPolicy.ps1')
    $uiThread=[Threading.Thread]::CurrentThread.ManagedThreadId
    if(-not (Start-WallhavenWorkerJob -Worker $worker -SettingsJson '{}' -TargetJson '{}')) { throw 'First selection did not start.' }
    if(Start-WallhavenWorkerJob -Worker $worker -SettingsJson '{}' -TargetJson '{}') { throw 'Concurrent selection was admitted.' }
    $script:beats=0
    $frame=New-Object Windows.Threading.DispatcherFrame
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(15)
    $timer.Add_Tick({
        $script:beats++
        if($worker.Async.IsCompleted) { $frame.Continue=$false }
        if($script:beats -gt 300) { $frame.Continue=$false }
    })
    $timer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
    $timer.Stop()
    $result=Receive-WallhavenWorkerJob -Worker $worker
    if($result.error) { throw "Worker failed: $($result.error)" }
    Write-Host ("Worker thread={0}; UI={1}; beats={2}" -f $result.threadId,$uiThread,$script:beats)
    if(-not $result -or $result.threadId -eq $uiThread -or $script:beats -lt 10) { throw 'Selection blocked Dispatcher or ran on its thread.' }
    if((Get-SharedHistorySnapshot).PendingCount -ne 0) { throw 'Completed worker leaked a reservation.' }
    if(-not (Start-WallhavenWorkerJob -Worker $worker -SettingsJson '{}' -TargetJson '{}')) { throw 'Worker could not be reused.' }
    $script:SelectionWorker=$worker; $script:Exiting=$false; $script:closed=$false
    function Hide-SettingsWindow {}
    function Complete-DesktopExit { $script:closed=$true }
    function Set-Status { param($Text) }
    function Write-Log { param($Level,$Message) }
    function Refresh-DiagnosticsUi {}
    $script:Running=$false
    Request-DesktopExit
    if($script:closed) { throw 'Exit released resources before the worker finished.' }
    $timeout=[Diagnostics.Stopwatch]::StartNew()
    while(-not $worker.Async.IsCompleted -and $timeout.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 15 }
    Receive-DesktopSelection
    $cancelled=$script:DesktopDiagnostics
    if(-not $script:closed) { throw 'Exit did not complete after worker cleanup.' }
    if(-not $cancelled.cancelled -or (Get-SharedHistorySnapshot).PendingCount -ne 0) { throw 'Cancellation did not finish and release its reservation.' }
    $worker.Runspace.SessionStateProxy.SetVariable('SimulateApply',$true)
    [void](Start-WallhavenWorkerJob -Worker $worker -SettingsJson '{}' -TargetJson '{}')
    if(-not $signal.Wait(5000)) { throw 'Apply boundary fixture did not start.' }
    Stop-WallhavenWorkerJob -Worker $worker
    [void]$worker.Async.AsyncWaitHandle.WaitOne(10000)
    $afterApply=Receive-WallhavenWorkerJob -Worker $worker
    if($afterApply.status -notlike 'Changement terminé*') { throw 'Cancellation after apply claimed the wallpaper was preserved.' }
    Close-WallhavenSelectionWorker -Worker $worker
    $worker=$null
    $signal.Dispose()
    Write-Host "Dedicated runspace, single selection, Dispatcher heartbeat ($script:beats), reuse and cancellation: OK"
}
finally {
    if($worker) {
        Stop-WallhavenWorkerJob -Worker $worker
        if($worker.Async) { [void]$worker.Async.AsyncWaitHandle.WaitOne(10000); [void](Receive-WallhavenWorkerJob -Worker $worker) }
        Close-WallhavenSelectionWorker -Worker $worker
    }
    foreach($name in @('WALLHAVEN_SHARED_BASE_DIR','WALLHAVEN_SHARED_MUTEX_NAME','WALLHAVEN_LEGACY_ROTATOR_HISTORY_PATH','WALLHAVEN_LEGACY_SCREENSAVER_HISTORY_PATH')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    if($testRoot.StartsWith([IO.Path]::GetFullPath($env:TEMP),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
