# Smoke test of src/Update-FromGitHubRelease.ps1 that needs no Pester, for Windows PowerShell 5.1
# (whose built-in Pester 3.4 cannot run the suite): functions named Invoke-RestMethod and
# Invoke-WebRequest stand in for the web, as functions win over cmdlets. Exit code = failures.
#   powershell.exe -NoProfile -File tests/Smoke-WindowsPowerShell.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Update-FromGitHubRelease.ps1')

$failures = 0
function Check([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "PASS  $Name" } else { Write-Host "FAIL  $Name"; $script:failures++ }
}

function Get-Sha256Hex([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
}

$install = Join-Path ([System.IO.Path]::GetTempPath()) ('rk-smoke-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $install 'lib') -Force
[System.IO.File]::WriteAllText((Join-Path $install 'tool.ps1'), 'v1')

$files = @{ 'tool.ps1' = 'v2'; 'lib/helper.psm1' = 'helper v2' }
$script:Served = @{}
$entries = @{}
$assets = @()
foreach ($path in $files.Keys) {
    $name = Split-Path -Leaf $path
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($files[$path])
    $entries[$name] = @{ path = $path; url = "asset:$name"; sha256 = (Get-Sha256Hex $bytes); size = $bytes.Length }
    $script:Served["https://dl.example/$name"] = $bytes
    $assets += New-Object PSObject -Property @{ name = $name; url = "https://api.example/$name"; browser_download_url = "https://dl.example/$name" }
}
$manifest = @{ schema = 1; repository = 'owner/tool'; tag = 'v1.2.0'; version = '1.2.0'; commit = ('c' * 40); files = $entries }
$script:Served['https://dl.example/release-manifest.json'] = [System.Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 5))
$assets += New-Object PSObject -Property @{ name = 'release-manifest.json'; url = 'https://api.example/release-manifest.json'; browser_download_url = 'https://dl.example/release-manifest.json' }
$script:Release = New-Object PSObject -Property @{ tag_name = 'v1.2.0'; assets = $assets }

function Invoke-RestMethod { param($Uri, $Headers, $TimeoutSec, $ErrorAction) $script:Release }
function Invoke-WebRequest {
    param($Uri, $Headers, $TimeoutSec, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
    $key = [string]$Uri
    if (-not $script:Served.ContainsKey($key)) { throw "404 for $key" }
    [System.IO.File]::WriteAllBytes($OutFile, $script:Served[$key])
}

try {
    Check "running on PowerShell $($PSVersionTable.PSVersion)" $true
    $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $install -WarningAction SilentlyContinue
    Check "first run: Updated ($($result.Status): $($result.Message))" ($result.Status -eq 'Updated')
    Check 'tool.ps1 replaced' ([System.IO.File]::ReadAllText((Join-Path $install 'tool.ps1')) -eq 'v2')
    Check 'lib/helper.psm1 created' ([System.IO.File]::ReadAllText((Join-Path $install 'lib/helper.psm1')) -eq 'helper v2')
    Check 'no .new or .old left' (-not (Get-ChildItem -LiteralPath $install -Recurse -File | Where-Object { $_.Name -match '\.(new|old)$' }))

    $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $install -WarningAction SilentlyContinue
    Check "second run: UpToDate ($($result.Status))" ($result.Status -eq 'UpToDate')

    $script:Served['https://dl.example/tool.ps1'] = [System.Text.Encoding]::UTF8.GetBytes('tampered')
    [System.IO.File]::WriteAllText((Join-Path $install 'tool.ps1'), 'v1')
    $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $install -WarningAction SilentlyContinue
    Check "tampered download: Failed ($($result.Message))" ($result.Status -eq 'Failed' -and $result.Message -match 'does not match')
    Check 'tampered download: tool.ps1 kept' ([System.IO.File]::ReadAllText((Join-Path $install 'tool.ps1')) -eq 'v1')
}
finally {
    Remove-Item -LiteralPath $install -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "$failures failed"
exit $failures
