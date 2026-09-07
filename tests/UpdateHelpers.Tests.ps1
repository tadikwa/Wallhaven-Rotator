$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$Source = Join-Path $Root "src\Wallhaven-Wallpaper-Tray.ps1"

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $Source,
    [ref]$tokens,
    [ref]$parseErrors
)

if ($parseErrors.Count -gt 0) {
    throw "Runtime source does not parse: $($parseErrors[0].Message)"
}

foreach ($name in @(
    "Test-IsNewerVersion",
    "Get-SetupAssetName",
    "Get-ExpectedHashFromChecksumText",
    "Test-DownloadedUpdate"
)) {
    $fn = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq $name
    }, $true) | Select-Object -First 1

    if ($null -eq $fn) {
        throw "Function '$name' not found."
    }

    Invoke-Expression $fn.Extent.Text
}

function Write-Log { param([string]$Level,[string]$Message) }
function Get-DeepErrorMessage { param($ErrorRecord) return [string]$ErrorRecord.Exception.Message }

if (-not (Test-IsNewerVersion -Candidate "1.2.0" -Current "1.1.0")) {
    throw "1.2.0 should be newer than 1.1.0."
}
if (Test-IsNewerVersion -Candidate "1.1.0" -Current "1.1.0") {
    throw "Equal versions must not be treated as updates."
}

$name = Get-SetupAssetName -Version "1.2.3"
if ($name -ne "WallhavenRotator-Setup-v1.2.3.exe") {
    throw "Unexpected setup asset name: $name"
}

$hash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
$file = "WallhavenRotator-Setup-v1.2.3.exe"
$text = "$hash  $file`r`n"

$parsed = Get-ExpectedHashFromChecksumText -Text $text -FileName $file
if ($parsed -ne $hash) {
    throw "SHA-256 checksum parsing failed."
}
if ($null -ne (Get-ExpectedHashFromChecksumText -Text $text -FileName "other.exe")) {
    throw "Checksum parser matched the wrong file."
}

$tmp = Join-Path $env:TEMP ("wallhaven-update-test-" + [guid]::NewGuid().ToString("N") + ".exe")
try {
    [IO.File]::WriteAllBytes($tmp, [Text.Encoding]::UTF8.GetBytes("wallhaven update test payload"))
    $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()

    if (-not (Test-DownloadedUpdate -Path $tmp -ExpectedHash $actual)) {
        throw "Matching SHA-256 update was rejected."
    }

    if (Test-DownloadedUpdate -Path $tmp -ExpectedHash ("0" * 64)) {
        throw "Mismatched SHA-256 update was accepted."
    }
}
finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

$invokeSilentUpdate = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Invoke-SilentUpdate"
}, $true) | Select-Object -First 1

if ($null -eq $invokeSilentUpdate) {
    throw "Invoke-SilentUpdate function not found."
}

if ($invokeSilentUpdate.Extent.Text -notmatch 'Save-UiSettings\s+-ShowValidation\s+\$false') {
    throw "Silent OTA must persist the current settings UI before updater hand-off."
}

Write-Host "Update helper tests: OK" -ForegroundColor Green
