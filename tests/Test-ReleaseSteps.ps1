# Tests release.yml's pwsh steps, including the refusals a CI dry run cannot show without failing:
# each step runs in a child pwsh with the env vars GitHub would set, in a throwaway git repo.
# Needs git, pwsh 7 and Python 3 with PyYAML. Exit code = number of failed checks.
#   pwsh -File tests/Test-ReleaseSteps.ps1
param ([string]$ReleaseKit = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$python = Get-Command -Name py, python3, python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $python) { throw 'Python 3 (py, python3 or python) is needed to read the workflow.' }
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('release-kit-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$steps = Join-Path $work 'steps'
& $python.Source -I (Join-Path $PSScriptRoot 'extract_steps.py') (Join-Path $ReleaseKit '.github/workflows/release.yml') release $steps | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not read the steps of release.yml (is PyYAML installed?).' }

$repo = Join-Path $work 'repo'
$null = New-Item -ItemType Directory -Path $repo
Copy-Item -Recurse (Join-Path $ReleaseKit 'tests') $repo
# Throwaway test repo only: no signing, LF bytes kept as written.
foreach ($c in @(@('init', '-q'), @('config', 'user.email', 't@example.com'), @('config', 'user.name', 't'),
        @('config', 'commit.gpgsign', 'false'), @('config', 'core.autocrlf', 'false'), @('add', '.'), @('commit', '-q', '-m', 't'))) {
    & git -C $repo @c 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "git $c failed" }
}
$commit = (git -C $repo rev-parse HEAD).Trim()
$results = [System.Collections.Generic.List[string]]::new()
$failed = 0

function Invoke-Step([string]$Step, [hashtable]$Env) {
    $out = Join-Path $work ([guid]::NewGuid().ToString('N') + '.out')
    $null = New-Item -ItemType File -Path $out
    $runnerTemp = Join-Path $work ('tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $null = New-Item -ItemType Directory -Path $runnerTemp
    $all = @{ GITHUB_OUTPUT = $out; RUNNER_TEMP = $runnerTemp; GITHUB_WORKSPACE = $repo } + $Env
    $saved = @{}
    foreach ($k in $all.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
    try {
        Push-Location $repo
        $text = & pwsh -NoProfile -NonInteractive -File (Join-Path $steps "$Step.ps1") 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $outputs = @{}
    foreach ($line in Get-Content -LiteralPath $out) { $k, $v = $line -split '=', 2; $outputs[$k] = $v }
    [pscustomobject]@{ Code = $code; Text = $text; Outputs = $outputs }
}

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $results.Add("PASS  $Name") } else { $script:failed++; $results.Add("FAIL  $Name  $Detail") }
}

# --- tag step ---
$r = Invoke-Step tag @{ INPUT_TAG = 'v0.0.0-test'; REF_TYPE = 'branch'; REF_NAME = 'main'; DRY_RUN = 'true' }
Check 'tag: input tag, dry run' ($r.Code -eq 0 -and $r.Outputs.tag -eq 'v0.0.0-test' -and $r.Outputs.version -eq '0.0.0-test' -and $r.Outputs.prerelease -eq 'true' -and $r.Outputs.ref -eq '') $r.Text
$r = Invoke-Step tag @{ INPUT_TAG = ''; REF_TYPE = 'tag'; REF_NAME = 'v1.2.3'; DRY_RUN = 'false' }
Check 'tag: from tag push, release' ($r.Code -eq 0 -and $r.Outputs.tag -eq 'v1.2.3' -and $r.Outputs.prerelease -eq 'false' -and $r.Outputs.ref -eq 'refs/tags/v1.2.3') $r.Text
$r = Invoke-Step tag @{ INPUT_TAG = ''; REF_TYPE = 'branch'; REF_NAME = 'main'; DRY_RUN = 'false' }
Check 'tag: refuses a branch run with no tag' ($r.Code -ne 0 -and $r.Text -match 'No tag') $r.Text
foreach ($bad in 'v1.2', '1.2.3', 'v01.2.3', 'v1.2.3-', "v1.2.3`n", 'v1.2.3 ') {
    $r = Invoke-Step tag @{ INPUT_TAG = $bad; REF_TYPE = 'tag'; REF_NAME = 'x'; DRY_RUN = 'false' }
    Check "tag: refuses '$($bad -replace "`n",'\n')'" ($r.Code -ne 0) $r.Text
}

# --- manifest step ---
$files = "tests/fixtures/hello.ps1`ntests/fixtures/nested/data.txt`n"
$r = Invoke-Step manifest @{ FILES = $files; TAG = 'v0.0.0-test'; VERSION = '0.0.0-test'; REPOSITORY = 'J-MaFf/release-kit' }
Check 'manifest: builds' ($r.Code -eq 0) $r.Text
if ($r.Code -eq 0) {
    $dist = $r.Outputs.dist
    $m = Get-Content -Raw (Join-Path $dist 'release-manifest.json') | ConvertFrom-Json -AsHashtable
    Check 'manifest: commit' ($m.commit -eq $commit)
    Check 'manifest: schema/tag/version/repo' ($m.schema -eq 1 -and $m.tag -eq 'v0.0.0-test' -and $m.version -eq '0.0.0-test' -and $m.repository -eq 'J-MaFf/release-kit')
    foreach ($p in 'tests/fixtures/hello.ps1', 'tests/fixtures/nested/data.txt') {
        $n = Split-Path -Leaf $p
        $src = Join-Path $repo $p
        $f = $m.files[$n]
        Check "manifest: $n entry" ($f.path -eq $p -and $f.url -eq "asset:$n" -and $f.size -eq (Get-Item $src).Length -and
            $f.sha256 -ceq (Get-FileHash $src -Algorithm SHA256).Hash.ToLowerInvariant())
        Check "manifest: $n copied byte for byte" ([System.Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($src), [byte[]][IO.File]::ReadAllBytes((Join-Path $dist $n))))
    }
    Check 'manifest: output hash' ($r.Outputs.'manifest-sha256' -ceq (Get-FileHash (Join-Path $dist 'release-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant())
    Check 'manifest: dist has exactly 3 files' (@(Get-ChildItem $dist -File).Count -eq 3)
}
$null = New-Item -ItemType Directory -Path (Join-Path $repo 'other') -Force
Set-Content -LiteralPath (Join-Path $repo 'other/hello.ps1') -Value 'x'
Set-Content -LiteralPath (Join-Path $repo 'release-manifest.json') -Value '{}'
foreach ($case in @(
        @('duplicate names', "tests/fixtures/hello.ps1`nother/hello.ps1", 'would both be uploaded'),
        @('parent path', '../outside.txt', 'inside the repository'),
        @('absolute path', (Join-Path $repo 'tests/fixtures/hello.ps1'), 'inside the repository'),
        @('missing file', 'nope.txt', 'is not a file'),
        @('a folder', 'tests/fixtures', 'is not a file'),
        @('manifest name', 'release-manifest.json', 'replace the manifest'),
        @('empty list', "`n  `n", 'lists no files'))) {
    $r = Invoke-Step manifest @{ FILES = $case[1]; TAG = 'v1.0.0'; VERSION = '1.0.0'; REPOSITORY = 'o/r' }
    Check "manifest: refuses $($case[0])" ($r.Code -ne 0 -and $r.Text -match $case[2]) $r.Text
}

# --- notes step ---
$r = Invoke-Step notes @{ CHANGELOG = 'tests/fixtures/CHANGELOG.md'; VERSION = '0.0.0-test' }
$notes = if ($r.Outputs.path) { Get-Content -Raw $r.Outputs.path } else { '' }
Check 'notes: takes only its section' ($r.Code -eq 0 -and $notes -match 'Fixture entry' -and $notes -notmatch 'older entry' -and $notes -notmatch '^## ') "$($r.Text) [$notes]"
$r = Invoke-Step notes @{ CHANGELOG = 'tests/fixtures/CHANGELOG.md'; VERSION = '9.9.9' }
Check 'notes: refuses a missing section' ($r.Code -ne 0 -and $r.Text -match "no '## \[9.9.9\]' section") $r.Text
$r = Invoke-Step notes @{ CHANGELOG = 'tests/fixtures/CHANGELOG.md'; VERSION = '0.0.0' }
Check 'notes: last section runs to end of file' ($r.Code -eq 0 -and (Get-Content -Raw $r.Outputs.path) -match 'older entry') $r.Text
$r = Invoke-Step notes @{ CHANGELOG = 'NOPE.md'; VERSION = '1.0.0' }
Check 'notes: refuses a missing changelog' ($r.Code -ne 0 -and $r.Text -match 'No changelog') $r.Text
Set-Content -LiteralPath (Join-Path $repo 'EMPTY.md') -Value "## [1.0.0] - x`n`n## [0.9.0]`n- y"
$r = Invoke-Step notes @{ CHANGELOG = 'EMPTY.md'; VERSION = '1.0.0' }
Check 'notes: refuses an empty section' ($r.Code -ne 0 -and $r.Text -match 'is empty') $r.Text

$results
"`n$failed failed"
Remove-Item -Recurse -Force $work
exit [Math]::Min($failed, 255)
