# PowerShell 5.1: one reusable runspace owns selection state; no WPF objects cross it.
function New-WallhavenSelectionWorker {
    param([hashtable]$Functions,[hashtable]$Variables,[string]$PolicyPath)
    $initial=[Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach($name in $Functions.Keys) {
        $initial.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name,[string]$Functions[$name]))
    }
    foreach($name in $Variables.Keys) {
        $initial.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new($name,$Variables[$name],''))
    }
    $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initial)
    $runspace.ApartmentState='STA'
    $runspace.ThreadOptions='ReuseThread'
    $runspace.Open()
    [pscustomobject]@{Runspace=$runspace;PolicyPath=$PolicyPath;PowerShell=$null;Async=$null;Cancellation=$null;Progress=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]')}
}

function Start-WallhavenWorkerJob {
    param($Worker,[string]$SettingsJson,[string]$TargetJson,[switch]$InitializeOnly)
    if($Worker.Async) { return $false }
    $Worker.Cancellation=New-Object Threading.CancellationTokenSource
    $ps=[PowerShell]::Create()
    $ps.Runspace=$Worker.Runspace
    [void]$ps.AddScript({
        param($policy,$settingsJson,$targetJson,$cancel,$progress,$initializeOnly)
        $ErrorActionPreference='Stop'
        $script:WorkerCancellation=$cancel
        $script:WorkerProgress=$progress
        $script:Settings=$settingsJson|ConvertFrom-Json
        $script:WorkerTarget=$targetJson|ConvertFrom-Json
        $script:Running=$false
        $script:PendingManual=$false
        $script:State='Idle'
        $script:ReservedCandidateId=$null
        $previousId=$script:LastWallpaperId
        function Set-Status { param([string]$Text) $script:LastStatus=$Text; $script:WorkerProgress.Enqueue($Text) }
        function Get-TargetDisplayFilter { $script:WorkerTarget }
        function Schedule-NextChange {}
        function Refresh-DiagnosticsUi {}
        function Publish-WallpaperState {}
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $errorText=$null
        try {
            if(-not $script:WorkerInitialized) {
                . $policy
                Add-Type -AssemblyName System.Net.Http
                Add-Type -AssemblyName System.Drawing
                if(-not $script:HttpClient) { $script:HttpClient=New-WallhavenHttpClient -AppVersion $AppVersion }
                $script:PageCeilings=@{}
                $script:HistoryIds=New-Object 'System.Collections.Generic.List[string]'
                $script:LastLogCleanup=[DateTime]::MinValue
                $script:ApiRetryAfter=$null
                $script:CandidateDiagnostics=@{daily=0;recent=0;pending=0;strict=0;accepted=0}
                Load-MetadataCache
                Load-SearchCache
                Refresh-SharedHistoryView
                $script:WorkerInitialized=$true
            }
            if(-not $initializeOnly -and -not $cancel.IsCancellationRequested) {
                $script:SharedHistorySnapshot=$null
                Start-WallpaperChange -Reason Manual
                while($script:State -ne 'Idle' -and -not $cancel.IsCancellationRequested) {
                    Process-AsyncState
                    [void]$cancel.Token.WaitHandle.WaitOne(20)
                }
            }
        }
        catch { $errorText=$_.Exception.Message; Set-Status "Erreur : $errorText" }
        finally {
            foreach($task in @($script:ApiTask,$script:MetadataTask,$script:DownloadTask)) {
                if($task -and $task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled) {
                    $response=$task.GetAwaiter().GetResult()
                    if([int]$response.StatusCode -eq 429) {
                        try { [void](Get-WallhavenResponseJson -Task $task) } catch {}
                    } else { $response.Dispose() }
                }
            }
            Stop-SelectionRequests
            if($script:ReservedCandidateId) {
                Release-SharedWallpaperReservation -Id $script:ReservedCandidateId
                $script:ReservedCandidateId=$null
            }
            if($cancel.IsCancellationRequested) {
                if($script:LastWallpaperId -ne $previousId) { Set-Status 'Changement terminé · arrêt demandé.' }
                else { Set-Status 'Sélection annulée · fond actuel conservé.' }
            }
            $script:State='Idle'
        }
        $snapshot=if($script:SharedHistorySnapshot){$script:SharedHistorySnapshot}else{Get-SharedHistorySnapshot}
        $cacheCount=if($CacheDir){@(Get-ChildItem -LiteralPath $CacheDir -File -Filter 'wallhaven-*' -ErrorAction SilentlyContinue).Count}else{0}
        [pscustomobject]@{cancelled=$cancel.IsCancellationRequested;error=$errorText;threadId=[Threading.Thread]::CurrentThread.ManagedThreadId;
            elapsedMs=$clock.Elapsed.TotalMilliseconds;status=$script:LastStatus;id=$script:LastWallpaperId;url=$script:LastWallpaperUrl;file=$script:LastWallpaperFilePath;
            retryAfter=$script:ApiRetryAfter;historyCount=$snapshot.HistoryCount;todayCount=$snapshot.SeenTodayCount;cacheCount=$cacheCount;diagnostics=$script:CandidateDiagnostics}
    }.ToString()).AddArgument($Worker.PolicyPath).AddArgument($SettingsJson).AddArgument($TargetJson).AddArgument($Worker.Cancellation).AddArgument($Worker.Progress).AddArgument([bool]$InitializeOnly)
    $Worker.PowerShell=$ps
    $Worker.Async=$ps.BeginInvoke()
    return $true
}

function Receive-WallhavenWorkerJob {
    param($Worker)
    if(-not $Worker.Async -or -not $Worker.Async.IsCompleted) { return $null }
    try {
        $results=$Worker.PowerShell.EndInvoke($Worker.Async)
        if($results.Count -eq 0) { throw ($Worker.PowerShell.Streams.Error|Out-String) }
        return ($results|Select-Object -Last 1|ConvertTo-Json -Depth 6 -Compress|ConvertFrom-Json)
    }
    finally {
        $Worker.PowerShell.Dispose(); $Worker.PowerShell=$null; $Worker.Async=$null
        $Worker.Cancellation.Dispose(); $Worker.Cancellation=$null
    }
}

function Stop-WallhavenWorkerJob {
    param($Worker)
    if($Worker.Cancellation) { $Worker.Cancellation.Cancel() }
}

function Close-WallhavenSelectionWorker {
    param($Worker)
    if($Worker.Async) { throw 'Wait for cooperative selection cleanup before closing its runspace.' }
    $client=$Worker.Runspace.SessionStateProxy.GetVariable('HttpClient')
    if($client) { $client.Dispose() }
    $Worker.Runspace.Close(); $Worker.Runspace.Dispose()
}

function Get-WallhavenWindowLayout {
    param([double]$WorkLeft=0,[double]$WorkTop=0,[double]$WorkWidth,[double]$WorkHeight,
        [double]$Dpi=96,[double]$CurrentLeft=0,[double]$CurrentTop=0,[bool]$Options=$false)
    $scale=[Math]::Max(1,$Dpi)/96.0
    $availableWidth=[Math]::Max(1,$WorkWidth/$scale-16)
    $availableHeight=[Math]::Max(1,$WorkHeight/$scale-16)
    $mode=if(-not $Options){'Compact'}elseif($availableWidth -ge 980){'Side'}else{'Vertical'}
    $width=[Math]::Min($availableWidth,$(if($mode -eq 'Side'){980}else{560}))
    $height=[Math]::Min($availableHeight,$(if($mode -eq 'Compact'){560}else{680}))
    [pscustomobject]@{Mode=$mode;Width=$width;Height=$height;
        Left=[Math]::Max($WorkLeft,[Math]::Min($CurrentLeft,$WorkLeft+$WorkWidth-[Math]::Ceiling($width*$scale)));
        Top=[Math]::Max($WorkTop,[Math]::Min($CurrentTop,$WorkTop+$WorkHeight-[Math]::Ceiling($height*$scale)))}
}

function Initialize-WallhavenDesktopNative {
    if('WallhavenDesktopNative' -as [type]) { return }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WallhavenDesktopNative {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo { public int Size; public Rect Monitor,Work; public int Flags; }
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, int flags);
    [DllImport("user32.dll",CharSet=CharSet.Auto)] static extern bool GetMonitorInfo(IntPtr h, ref MonitorInfo info);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect rect);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x,int y,int w,int height,uint flags);
    [DllImport("user32.dll",EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetLong64(IntPtr h,int n);
    [DllImport("user32.dll",EntryPoint="GetWindowLongW")] static extern int GetLong32(IntPtr h,int n);
    [DllImport("user32.dll",EntryPoint="SetWindowLongPtrW")] static extern IntPtr SetLong64(IntPtr h,int n,IntPtr v);
    [DllImport("user32.dll",EntryPoint="SetWindowLongW")] static extern int SetLong32(IntPtr h,int n,int v);
    public static IntPtr GetLong(IntPtr h,int n) { return IntPtr.Size==8?GetLong64(h,n):new IntPtr(GetLong32(h,n)); }
    public static void SetLong(IntPtr h,int n,IntPtr v) { if(IntPtr.Size==8) SetLong64(h,n,v); else SetLong32(h,n,v.ToInt32()); }
    public static Rect WorkArea(IntPtr h) {
        var info=new MonitorInfo(); info.Size=Marshal.SizeOf(info);
        if(!GetMonitorInfo(MonitorFromWindow(h,2),ref info)) throw new System.ComponentModel.Win32Exception();
        return info.Work;
    }
    public static void TaskbarWindow(IntPtr h) {
        SetLong(h,-8,IntPtr.Zero);
        SetLong(h,-20,new IntPtr((GetLong(h,-20).ToInt64() & ~0x80L) | 0x40000L));
        SetWindowPos(h,IntPtr.Zero,0,0,0,0,0x37);
    }
}
'@
}

function Set-WallhavenWindowViewport {
    param($Window,[bool]$Options)
    if($script:UpdatingViewport) { return }
    $script:UpdatingViewport=$true
    try {
        $Window.Dispatcher.VerifyAccess()
        Initialize-WallhavenDesktopNative
        $hwnd=([Windows.Interop.WindowInteropHelper]::new($Window)).EnsureHandle()
        $work=[WallhavenDesktopNative]::WorkArea($hwnd)
        $rect=New-Object WallhavenDesktopNative+Rect
        [void][WallhavenDesktopNative]::GetWindowRect($hwnd,[ref]$rect)
        $dpi=96
        try { $dpi=[WallhavenDesktopNative]::GetDpiForWindow($hwnd) } catch {}
        $layout=Get-WallhavenWindowLayout -WorkLeft $work.Left -WorkTop $work.Top -WorkWidth ($work.Right-$work.Left) -WorkHeight ($work.Bottom-$work.Top) -Dpi $dpi -CurrentLeft $rect.Left -CurrentTop $rect.Top -Options $Options
        Set-WallhavenResponsiveLayout -Window $Window -Layout $layout -Options $Options
        [void][WallhavenDesktopNative]::SetWindowPos($hwnd,[IntPtr]::Zero,[int]$layout.Left,[int]$layout.Top,0,0,0x15)
    }
    finally { $script:UpdatingViewport=$false }
}

function Show-WallhavenWindow {
    param($Window,[string]$IconPath)
    $Window.Dispatcher.VerifyAccess()
    Initialize-WallhavenDesktopNative
    if(-not $Window.Icon -and (Test-Path -LiteralPath $IconPath)) {
        $stream=[IO.File]::OpenRead($IconPath)
        try {
            # Fully decode before closing the stream so OTA can replace the ICO.
            $frame=[Windows.Media.Imaging.BitmapFrame]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::None,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            $frame.Freeze()
            $Window.Icon=$frame
        }
        finally { $stream.Dispose() }
    }
    $Window.ShowInTaskbar=$true
    $Window.WindowState='Normal'
    $Window.Show()
    $hwnd=([Windows.Interop.WindowInteropHelper]::new($Window)).Handle
    [WallhavenDesktopNative]::TaskbarWindow($hwnd)
    Set-WallhavenWindowViewport -Window $Window -Options ([bool]$Window.FindName('AdvancedExpander').IsExpanded)
    [void]$Window.Activate()
}

function Hide-WallhavenWindow {
    param($Window)
    $Window.Dispatcher.VerifyAccess()
    $Window.Hide()
    $Window.ShowInTaskbar=$false
}

function Register-WallhavenWindowLifecycle {
    param($Window)
    $Window.Add_Closing({
        param($sender,$e)
        if(-not $script:Exiting) { $e.Cancel=$true; Hide-WallhavenWindow -Window $sender }
    })
}

function Get-WallhavenEngineFunctions {
    $definitions=@{}
    # Canonical engine functions are reused verbatim; UI boundaries are replaced inside the runspace.
    foreach($name in @('Load-MetadataCache','Save-MetadataCache','Remember-WallhavenMetadata',
        'Get-CachedContentDecision','Get-EligibleCandidates','Begin-CandidateEvaluation',
        'Retry-ApiSelection','Start-RecycleSelection','Start-WallpaperChange','Start-ApiRequest',
        'Begin-CandidateDownload','Process-AsyncState','Handle-RequestFailure','Finish-NoEligibleCandidate',
        'Complete-Wallpaper','Get-ApiUrl','Get-SelectionPage','Get-SelectionPageLimit','ConvertTo-QueryString',
        'Get-WallhavenResponseJson','Get-WallhavenRatioForSize','Test-ImageBytes','Get-ResolutionQueryParameters',
        'Test-ResolutionFallbackAllowed','Get-DeepErrorMessage','Get-LocalSelectionKey','Start-CachedSelection',
        'Start-WallhavenApiTask','Initialize-SelectionCycle','Write-SelectionSummary','Load-SearchCache',
        'Save-SearchCache','Start-DiscoveredSelection','Get-QualifiedCandidateRank','Stop-SelectionRequests',
        'Get-SelectionHistorySnapshot','Refresh-SharedHistoryView','Write-CandidateDiagnostic',
        'Set-WindowsWallpaper','Trim-WallpaperCache','Write-Log','Get-CurrentLogPath','Remove-ExpiredLogs','New-WallhavenHttpClient')) {
        $definitions[$name]=(Get-Item "Function:$name").ScriptBlock.ToString()
    }
    return $definitions
}

function New-WallhavenHttpClient {
    param([string]$AppVersion)
    $handler=New-Object Net.Http.HttpClientHandler
    $handler.AutomaticDecompression=[Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $client=[Net.Http.HttpClient]::new($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(65)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd("WallhavenWallpaperRotator/$AppVersion")
    return $client
}

function Start-DesktopWallpaperChange {
    param([string]$Reason='Auto',[switch]$InitializeOnly)
    if($script:Exiting) { return }
    if($script:SelectionWorker.Async) {
        if($Reason -eq 'Manual') { $script:PendingManual=$true; Set-Status 'Un changement est déjà en cours ; demande mise en attente.' }
        return
    }
    $script:State='Selecting'
    $settings=ConvertTo-Json -Compress -InputObject $script:Settings
    $target=ConvertTo-Json -Compress -InputObject (Get-TargetDisplayFilter)
    [void](Start-WallhavenWorkerJob -Worker $script:SelectionWorker -SettingsJson $settings -TargetJson $target -InitializeOnly:$InitializeOnly)
}

function Receive-DesktopSelection {
    if(-not $script:SelectionWorker) { return }
    $message=$null
    while($script:SelectionWorker.Progress.TryDequeue([ref]$message)) { Set-Status $message }
    if(-not $script:SelectionWorker.Async -or -not $script:SelectionWorker.Async.IsCompleted) { return }
    try {
        $result=Receive-WallhavenWorkerJob -Worker $script:SelectionWorker
        $script:DesktopDiagnostics=$result
        if($result.status) { Set-Status $result.status }
        if($result.id) {
            $script:LastWallpaperId=$result.id; $script:LastWallpaperUrl=$result.url; $script:LastWallpaperFilePath=$result.file
            Publish-WallpaperState
        }
        $script:ApiRetryAfter=$result.retryAfter
        if($script:Running) {
            Schedule-NextChange
            if($result.retryAfter -and [DateTime]$result.retryAfter -gt $script:NextChange) { $script:NextChange=[DateTime]$result.retryAfter }
        }
        Write-Log 'INFO' ("selection.worker elapsed_ms={0} thread={1} cancelled={2} history={3}" -f [Math]::Round($result.elapsedMs),$result.threadId,$result.cancelled,$result.historyCount)
    }
    catch { Set-Status "Erreur du worker : $($_.Exception.Message)"; Write-Log 'ERROR' $_.Exception.Message; if($script:Running){$script:NextChange=[DateTime]::Now.AddMinutes(1)} }
    $script:State='Idle'
    Refresh-DiagnosticsUi
    if($script:Exiting) { Complete-DesktopExit; return }
    if($script:PendingManual) { $script:PendingManual=$false; Start-DesktopWallpaperChange -Reason Manual }
}

function Request-DesktopExit {
    if($script:Exiting) { return }
    $script:Exiting=$true; $script:PendingManual=$false; $script:Running=$false
    Hide-SettingsWindow
    if($script:SelectionWorker.Async) { Stop-WallhavenWorkerJob -Worker $script:SelectionWorker }
    else { Complete-DesktopExit }
}

function Complete-DesktopExit {
    $script:Timer.Stop()
    Close-WallhavenSelectionWorker -Worker $script:SelectionWorker
    $notifyIcon.Visible=$false; $notifyIcon.Dispose(); $trayMenu.Dispose()
    if($script:TrayIconObject) { $script:TrayIconObject.Dispose() }
    $script:HttpClient.Dispose(); $handler.Dispose()
    $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose()
    $window.Close()
    [Windows.Application]::Current.Shutdown()
}

function Set-WallhavenResponsiveLayout {
    param($Window,$Layout,[bool]$Options)
    $Window.Dispatcher.VerifyAccess()
    $Window.SizeToContent='Manual'
    $Window.MinHeight=0; $Window.MinWidth=0
    $Window.MaxWidth=[double]::PositiveInfinity; $Window.MaxHeight=[double]::PositiveInfinity
    $Window.Width=$layout.Width; $Window.Height=$layout.Height
    $grid=$Window.FindName('ResponsiveGrid')
    $optionPanel=$Window.FindName('OptionsScrollViewer')
    $optionPanel.Visibility=if($Options){'Visible'}else{'Collapsed'}
    if($layout.Mode -eq 'Side') {
        $grid.ColumnDefinitions[1].Width=[Windows.GridLength]::new(400)
        $grid.RowDefinitions[0].Height=[Windows.GridLength]::new(1,'Star')
        $grid.RowDefinitions[1].Height=[Windows.GridLength]::new(0)
        [Windows.Controls.Grid]::SetColumn($optionPanel,1); [Windows.Controls.Grid]::SetRow($optionPanel,0)
    }
    else {
        $grid.ColumnDefinitions[1].Width=[Windows.GridLength]::new(0)
        if($Options) {
            $footer=$Window.FindName('MainFooter')
            $footer.Measure([Windows.Size]::new($layout.Width-2,[double]::PositiveInfinity))
            $contentHeight=[Math]::Max(1,$layout.Height-50)
            $mainHeight=[Math]::Max(0,[Math]::Min($contentHeight-48,[Math]::Max($contentHeight*0.6,$footer.DesiredSize.Height+48)))
            $grid.RowDefinitions[0].Height=[Windows.GridLength]::new($mainHeight)
            $grid.RowDefinitions[1].Height=[Windows.GridLength]::new(1,'Star')
        }
        else {
            $grid.RowDefinitions[0].Height=[Windows.GridLength]::new(1,'Star')
            $grid.RowDefinitions[1].Height=[Windows.GridLength]::new(0)
        }
        [Windows.Controls.Grid]::SetColumn($optionPanel,0); [Windows.Controls.Grid]::SetRow($optionPanel,1)
    }
    $Window.UpdateLayout()
}
