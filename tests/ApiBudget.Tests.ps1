$ErrorActionPreference='Stop'
$testRoot=Join-Path $env:TEMP ('wallhaven-budget-'+[guid]::NewGuid().ToString('N'))
$env:WALLHAVEN_SHARED_BASE_DIR=$testRoot
$env:WALLHAVEN_SHARED_MUTEX_NAME='Local\WallhavenBudgetTest-'+[guid]::NewGuid().ToString('N')
try {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Wallhaven-SharedPolicy.ps1')
    function Assert($ok,$message) { if(-not $ok) { throw $message } }
    $calls=@()
    $anchor=[DateTimeOffset]::Parse('2026-10-23T12:00:00Z')
    for($i=0;$i -lt 1200;$i++) {
        Set-SharedHistoryTestNow ($anchor.AddMilliseconds($i*100).ToString('o'))
        $p=Get-WallhavenApiPermit -RequestKey "search:$i" -Client Rotator
        if($p.Granted) { $calls+=Get-SharedHistoryNow }
    }
    Assert ($calls.Count -gt 0) 'No permit was ever granted.'
    foreach($t in $calls) {
        Assert (@($calls | Where-Object { $_ -ge $t.AddSeconds(-60) -and $_ -le $t }).Count -le 12) 'Rotator exceeded 12 calls in a sliding 60s window.'
    }
    # Reload the policy just as a fresh process does; receipt state is on disk.
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Wallhaven-SharedPolicy.ps1')
    Set-SharedHistoryTestNow ($anchor.AddSeconds(119.9).ToString('o'))
    Assert (-not (Get-WallhavenApiPermit -RequestKey restart -Client Rotator).Granted) 'Restart bypassed persistent budget.'
    $until=$anchor.AddHours(1)
    Set-WallhavenApiCooldown -Until $until
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Wallhaven-SharedPolicy.ps1')
    Set-SharedHistoryTestNow ($anchor.AddMinutes(10).ToString('o'))
    $p=Get-WallhavenApiPermit -RequestKey after429 -Client Rotator
    Assert (-not $p.Granted -and $p.RetryAt -ge $until) '429 cooldown did not survive restart.'
    Set-SharedHistoryTestNow ($until.AddSeconds(1).ToString('o'))
    Assert ((Get-WallhavenApiPermit -RequestKey recovered -Client Rotator).Granted) 'Cooldown never recovered.'
    # A rollback of wall time keeps future receipts, rather than clearing them.
    Set-SharedHistoryTestNow ($anchor.ToString('o'))
    Assert (-not (Get-WallhavenApiPermit -RequestKey rollback -Client Rotator).Granted) 'Clock rollback bypassed budget.'
    [IO.File]::WriteAllText((Join-Path $testRoot 'api-budget.json'),'{corrupt')
    Assert (-not (Get-WallhavenApiPermit -RequestKey corrupt -Client Rotator).Granted) 'Corrupt budget failed open.'
    [IO.File]::WriteAllText($script:WallhavenApiBudgetPath,'{"schema":1,"notBefore":"","requests":[]}')
    $mixed=@()
    for($i=0;$i -lt 2400;$i++) {
        Set-SharedHistoryTestNow ($anchor.AddMilliseconds($i*50).ToString('o'))
        $client=if($i%2 -eq 0){'Rotator'}else{'Screensaver'}
        $p=Get-WallhavenApiPermit -RequestKey "mixed:$i" -Client $client
        if($p.Granted) { $mixed += [pscustomobject]@{at=(Get-SharedHistoryNow);client=$client} }
    }
    foreach($event in $mixed) {
        $window=@($mixed | Where-Object {$_.at -ge $event.at.AddSeconds(-60) -and $_.at -le $event.at})
        Assert ($window.Count -le 24) 'Cooperating clients exceeded the shared cap.'
        Assert (@($window | Where-Object {$_.client -eq 'Rotator'}).Count -le 12) 'Rotator headroom cap was bypassed by another client.'
    }
    # Real child processes contend on the same file/mutex at a fixed virtual instant.
    $child=Join-Path $testRoot 'budget-child.ps1'
    $module=Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Wallhaven-SharedPolicy.ps1'
    $childText=@'
$ErrorActionPreference='Stop'
. '@module'
Set-SharedHistoryTestNow '2026-10-24T15:00:00Z'
$grants=0
foreach($i in 1..50) { if((Get-WallhavenApiPermit -RequestKey ("child:"+$PID+":"+$i) -Client Screensaver).Granted) { $grants++ } }
Write-Output $grants
'@
    [IO.File]::WriteAllText($child,$childText.Replace('@module',$module.Replace("'","''")),(New-Object Text.UTF8Encoding($true)))
    $processes=@(foreach($i in 1..2) {
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$child+'"'
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        [Diagnostics.Process]::Start($start)
    })
    $total=0
    foreach($process in $processes) {
        $stdout=$process.StandardOutput.ReadToEnd(); $stderr=$process.StandardError.ReadToEnd()
        $process.WaitForExit()
        Assert ($process.ExitCode -eq 0) ("Concurrent client failed: "+$stderr)
        $total += [int]$stdout.Trim()
        $process.Dispose()
    }
    Assert ($total -eq 1) 'Concurrent clients received more than one permit at the same instant.'
    Write-Host 'Persistent API budget tests: OK'
}
finally {
    Remove-Item Env:WALLHAVEN_SHARED_BASE_DIR,Env:WALLHAVEN_SHARED_MUTEX_NAME -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
