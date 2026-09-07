param(
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Setup = Join-Path $Root "setup"
$Payload = Join-Path $Setup "payload"
$Dist = Join-Path $Root "dist"

# Runtime encoding preflight: PowerShell 5.1 requires a single UTF-8 BOM at byte 0.
$RuntimePath = Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1"
[byte[]]$RuntimeBytes = [System.IO.File]::ReadAllBytes($RuntimePath)
$RuntimeBomPositions = New-Object 'System.Collections.Generic.List[int]'
for ($i = 0; $i -le $RuntimeBytes.Length - 3; $i++) {
    if (
        $RuntimeBytes[$i]   -eq 0xEF -and
        $RuntimeBytes[$i+1] -eq 0xBB -and
        $RuntimeBytes[$i+2] -eq 0xBF
    ) {
        [void]$RuntimeBomPositions.Add($i)
    }
}
if (
    $RuntimeBomPositions.Count -ne 1 -or
    $RuntimeBomPositions[0] -ne 0
) {
    throw "Encodage runtime invalide : un seul BOM UTF-8 est autorisé, à la position 0. Positions détectées : $($RuntimeBomPositions -join ', ')"
}

$CanonicalVersion = (Get-Content (Join-Path $Root "VERSION") -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = $CanonicalVersion
}

if ($Version -ne $CanonicalVersion) {
    throw "Version demandée '$Version' différente de VERSION ('$CanonicalVersion')."
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "VERSION doit être au format SemVer X.Y.Z."
}

New-Item -ItemType Directory -Path $Payload -Force | Out-Null
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

# Refresh the embedded payload from the canonical application sources.
Copy-Item (Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1") (Join-Path $Payload "Wallhaven-Wallpaper-Tray.ps1") -Force
Copy-Item (Join-Path $Root "src\Wallhaven-SharedPolicy.ps1") (Join-Path $Payload "Wallhaven-SharedPolicy.ps1") -Force
Copy-Item (Join-Path $Root "src\Wallhaven-Rotator-Launcher.vbs") (Join-Path $Payload "Wallhaven-Rotator-Launcher.vbs") -Force
Copy-Item (Join-Path $Root "src\README-runtime.txt") (Join-Path $Payload "README.txt") -Force
Copy-Item (Join-Path $Root "assets\Wallhaven-Rotator.ico") (Join-Path $Payload "Wallhaven-Rotator.ico") -Force
Copy-Item (Join-Path $Root "assets\Wallhaven-Rotator.png") (Join-Path $Payload "Wallhaven-Rotator.png") -Force

# Verify that the runtime's public version matches VERSION.
$runtime = Get-Content (Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1") -Raw
if ($runtime -notmatch [regex]::Escape('$script:AppVersion = "' + $Version + '"')) {
    throw "La version du runtime PowerShell ne correspond pas à VERSION."
}

# Parse PowerShell before embedding it.
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1"),
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-List | Out-String | Write-Error
    throw "Le runtime PowerShell contient des erreurs de syntaxe."
}

Push-Location $Setup
try {
    $env:WALLHAVEN_VERSION = $Version
    python .\generate_resources.py

    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"

    go vet -unsafeptr=false ./...

    $Output = Join-Path $Dist ("WallhavenRotator-Setup-v{0}.exe" -f $Version)
    $LdFlags = "-H=windowsgui -X main.appVersion=$Version -X main.setupVersion=$Version"
    go build -trimpath -buildvcs=false -ldflags $LdFlags -o $Output .

    if (-not (Test-Path $Output)) {
        throw "Le setup n'a pas été généré."
    }

    $vi = (Get-Item $Output).VersionInfo
    if ($vi.ProductVersion -ne $Version) {
        throw "ProductVersion PE inattendue : '$($vi.ProductVersion)' au lieu de '$Version'."
    }
    if ($vi.FileVersion -ne "$Version.0") {
        throw "FileVersion PE inattendue : '$($vi.FileVersion)' au lieu de '$Version.0'."
    }

    $hash = Get-FileHash $Output -Algorithm SHA256
    $hashLine = "{0}  {1}" -f $hash.Hash.ToLowerInvariant(), (Split-Path $Output -Leaf)
    $hashPath = Join-Path $Dist ("WallhavenRotator-Setup-v{0}-SHA256.txt" -f $Version)
    Set-Content -Path $hashPath -Value $hashLine -Encoding ASCII

    Write-Host ""
    Write-Host "Build OK : $Output" -ForegroundColor Green
    Write-Host "SHA-256 : $($hash.Hash.ToLowerInvariant())"
}
finally {
    Remove-Item Env:WALLHAVEN_VERSION -ErrorAction SilentlyContinue
    Pop-Location
}
