$ErrorActionPreference='Stop'
$Root=Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'src/Wallhaven-Desktop.ps1')
Add-Type -AssemblyName PresentationFramework
$window=$null
$iconFixture=Join-Path $env:TEMP ('wallhaven-icon-'+[guid]::NewGuid().ToString('N')+'.ico')
Copy-Item -LiteralPath (Join-Path $Root 'assets/Wallhaven-Rotator.ico') -Destination $iconFixture
try {
    if(-not (Get-Command Register-WallhavenWindowLifecycle -ErrorAction SilentlyContinue)) { throw 'Window close-to-tray lifecycle is missing.' }
    $source=[IO.File]::ReadAllText((Join-Path $Root 'src/Wallhaven-Wallpaper-Tray.ps1'))
    $markup=[regex]::Match($source,"(?s)\[xml\]\`$xaml = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
    if(-not $markup) { throw 'Runtime XAML not found.' }
    $window=[Windows.Markup.XamlReader]::Parse($markup)
    if(-not (Get-Command Set-WallhavenResponsiveLayout -ErrorAction SilentlyContinue)) { throw 'Measured responsive WPF arrangement is missing.' }
    $window.Title='Wallhaven Rotator - isolated lifecycle test'
    $script:Exiting=$false
    Register-WallhavenWindowLifecycle -Window $window
    Show-WallhavenWindow -Window $window -IconPath $iconFixture
    $iconStream=[IO.File]::Open($iconFixture,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $iconStream.Dispose()
    $hwnd=([Windows.Interop.WindowInteropHelper]::new($window)).Handle
    $style=[WallhavenDesktopNative]::GetLong($hwnd,-20).ToInt64()
    if(-not $window.IsVisible -or -not $window.ShowInTaskbar -or -not $window.Icon -or
        ($style -band 0x40000) -eq 0 -or ($style -band 0x80) -ne 0 -or [WallhavenDesktopNative]::GetLong($hwnd,-8) -ne [IntPtr]::Zero) { throw 'Visible HWND is not an ownerless taskbar window with its icon.' }
    foreach($name in @('SortCombo','CategoryCombo','IntervalText','UnitCombo','AutoRotationCheck','ChangeNowButton','PauseButton','SaveButton','ResolutionModeCombo','ResolutionMatchCombo',
        'CustomWidthText','CustomHeightText','CustomRatioCombo','ContentFilterCombo','QueryText','RunAtLogonCheck',
        'CheckUpdatesCheck','AutoUpdateCheck','OpenLogsButton','OpenFolderButton','CurrentWallpaperButton')) {
        if(-not $window.FindName($name)) { throw "Lost existing field: $name" }
    }
    $window.FindName('AdvancedExpander').IsExpanded=$true
    Set-WallhavenWindowViewport -Window $window -Options $true
    if($window.FindName('OptionsScrollViewer').ActualHeight -le 0 -or $window.FindName('MainScrollViewer').ActualHeight -le 0) { throw 'Missing scrollable viewport.' }
    $rect=New-Object WallhavenDesktopNative+Rect
    [void][WallhavenDesktopNative]::GetWindowRect($hwnd,[ref]$rect)
    $work=[WallhavenDesktopNative]::WorkArea($hwnd)
    if($rect.Left -lt $work.Left -or $rect.Top -lt $work.Top -or $rect.Right -gt $work.Right -or $rect.Bottom -gt $work.Bottom) { throw 'Actual HWND overflowed its monitor work area.' }
    foreach($size in @(@(5120,1440),@(1920,1080),@(1366,768))) {
        foreach($dpi in @(96,120,144,192)) {
            $layout=Get-WallhavenWindowLayout -WorkWidth $size[0] -WorkHeight ($size[1]-80) -Dpi $dpi -Options $true
            Set-WallhavenResponsiveLayout -Window $window -Layout $layout -Options $true
            if($window.FindName('MainScrollViewer').ActualHeight -lt 24 -or $window.FindName('OptionsScrollViewer').ActualHeight -lt 24) {
                throw "A viewport became unreachable at $($size -join 'x')/$dpi DPI."
            }
        }
    }
    $window.Close()
    if($window.IsVisible -or $window.ShowInTaskbar) { throw 'Close did not hide window and taskbar button.' }
    Show-WallhavenWindow -Window $window -IconPath (Join-Path $Root 'assets/Wallhaven-Rotator.ico')
    if(-not $window.IsVisible) { throw 'Hidden window could not be restored.' }
    $script:Exiting=$true
    $window.Close()
    $window=$null
    Write-Host 'Real WPF HWND, icon, responsive viewports, close/hide/restore/final close: OK'
}
finally { if($window) { $script:Exiting=$true; $window.Close() }; Remove-Item -LiteralPath $iconFixture -Force -ErrorAction SilentlyContinue }
