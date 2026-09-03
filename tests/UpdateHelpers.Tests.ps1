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
    "Get-SignedSetupAssetName",
    "Test-ExpectedUpdatePublisher",
    "Get-ExpectedHashFromChecksumText"
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

$ExpectedUpdateSignerCn = "CN=SignPath Foundation"
$ExpectedUpdateSignerOrg = "O=SignPath Foundation"

if (-not (Test-IsNewerVersion -Candidate "1.1.0" -Current "1.0.1")) {
    throw "1.1.0 should be newer than 1.0.1."
}
if (Test-IsNewerVersion -Candidate "1.0.1" -Current "1.0.1") {
    throw "Equal versions must not be treated as updates."
}
if (Test-IsNewerVersion -Candidate "1.0.0" -Current "1.0.1") {
    throw "Older versions must not be treated as updates."
}
if (Test-IsNewerVersion -Candidate "invalid" -Current "1.0.1") {
    throw "Invalid version must not be treated as an update."
}

$name = Get-SignedSetupAssetName -Version "1.2.3"
if ($name -ne "WallhavenRotator-Setup-v1.2.3.exe") {
    throw "Unexpected signed setup asset name: $name"
}

$validSubject = "CN=SignPath Foundation, O=SignPath Foundation, L=Lewes, S=Delaware, C=US"
if (-not (Test-ExpectedUpdatePublisher -Subject $validSubject)) {
    throw "Expected SignPath Foundation publisher was rejected."
}
if (Test-ExpectedUpdatePublisher -Subject "CN=Other Publisher, O=Other Publisher, C=US") {
    throw "Unexpected publisher was accepted."
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
