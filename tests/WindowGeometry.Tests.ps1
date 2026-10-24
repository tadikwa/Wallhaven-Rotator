$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Wallhaven-Desktop.ps1')
if(-not (Get-Command Get-WallhavenWindowLayout -ErrorAction SilentlyContinue)) { throw 'Monitor-aware window layout is missing.' }
$cases=0
foreach($size in @(@(5120,1440),@(1920,1080),@(1366,768))) {
    foreach($dpi in @(96,120,144,192)) {
        foreach($expanded in @($false,$true)) {
            foreach($origin in @(@(0,0),@(-1920,-300))) {
                $layout=Get-WallhavenWindowLayout -WorkLeft $origin[0] -WorkTop ($origin[1]+40) -WorkWidth $size[0] -WorkHeight ($size[1]-80) -Dpi $dpi -CurrentLeft ($origin[0]+$size[0]-50) -CurrentTop ($origin[1]+$size[1]-50) -Options $expanded
                $scale=$dpi/96.0
                if($layout.Left -lt $origin[0] -or $layout.Top -lt ($origin[1]+40) -or
                    $layout.Left+$layout.Width*$scale -gt $origin[0]+$size[0]+1 -or
                    $layout.Top+$layout.Height*$scale -gt $origin[1]+$size[1]-40+1) { throw 'Window overflowed monitor work area.' }
                if($layout.Width -le 0 -or $layout.Height -le 0) { throw 'Nonpositive layout.' }
                if(-not $expanded -and $layout.Width -gt 560) { throw 'Collapsed window is not compact.' }
                if($expanded -and $layout.Mode -notin @('Side','Vertical')) { throw 'Options have no reachable viewport.' }
                $cases++
            }
        }
    }
}
$wide=Get-WallhavenWindowLayout -WorkWidth 1920 -WorkHeight 1040 -Dpi 96 -Options $true
$narrow=Get-WallhavenWindowLayout -WorkWidth 1366 -WorkHeight 688 -Dpi 192 -Options $true
if($wide.Mode -ne 'Side' -or $narrow.Mode -ne 'Vertical') { throw 'Responsive mode selection failed.' }
Write-Host "Window geometry: $cases monitor/DPI/expansion cases OK"
