<#
.SYNOPSIS
    Brings a folder up to date with the newest GitHub release published by release-kit.
.DESCRIPTION
    Dot-source this file, then call Update-FromGitHubRelease. It follows the ReSkate launcher's
    updater:

      1. one request for the repository's latest release (the only call GitHub rate-limits: 60 an
         hour per IP without a token);
      2. its release-manifest.json, refused when its schema, repository or tag is not this release's;
      3. for each file the manifest lists, the local file's size and SHA-256 against the manifest:
         equal means up to date, whatever the version numbers say;
      4. every changed file downloaded next to its target as <file>.new and checked for size and
         SHA-256 (and its attestation with -VerifyAttestation) before any file is replaced; then all
         are swapped in, and if one swap fails, every file already swapped is put back.

    It never throws for an update problem: it returns a result whose Status is UpToDate, Updated,
    Skipped (-WhatIf, or a declined -Confirm) or Failed, warns on Failed, and leaves the files it
    has. Files the manifest does not list are left alone.

    Ship this file in your own releases (list it in the files of the release workflow) and it
    updates itself with everything else. Works in Windows PowerShell 5.1 and PowerShell 7.
.PARAMETER Repository
    The GitHub repository, owner/name.
.PARAMETER InstallPath
    The folder the files live in. Each file's manifest path is relative to it.
.PARAMETER Path
    Only these manifest paths (such as 'modules/Tools/Tools.psm1'). Default: every file.
.PARAMETER Token
    A GitHub token, needed for a private repository (gh auth token, or a read-only fine-grained
    token). Without one, a private repository's release answers 404.
.PARAMETER VerifyAttestation
    Also run gh attestation verify on each downloaded file, against -SignerWorkflow. Needs the
    GitHub CLI. Public repositories only on GitHub Free and Pro.
.PARAMETER SignerWorkflow
    The workflow -VerifyAttestation requires to have built the files.
.PARAMETER TimeoutSec
    Time limit of each web request.
.OUTPUTS
    [pscustomobject] Status (UpToDate, Updated, Skipped, Failed), Repository, Tag, Updated (paths
    replaced), Message.
.EXAMPLE
    . "$PSScriptRoot/Update-FromGitHubRelease.ps1"
    $result = Update-FromGitHubRelease -Repository J-MaFf/my-tool -InstallPath $PSScriptRoot
    if ($result.Status -eq 'Updated') { Write-Host "Updated to $($result.Tag): $($result.Updated -join ', ')" }
#>
function Update-FromGitHubRelease {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$InstallPath,

        [string[]]$Path,

        [string]$Token,

        [switch]$VerifyAttestation,

        [string]$SignerWorkflow = 'J-MaFf/release-kit/.github/workflows/release.yml',

        [ValidateRange(1, 600)]
        [int]$TimeoutSec = 15
    )

    $result = [pscustomobject]@{
        Status     = 'Failed'
        Repository = $Repository
        Tag        = $null
        Updated    = @()
        Message    = $null
    }
    $staged = @()
    try {
        # Windows PowerShell 5.1 may default to TLS 1.0, which GitHub refuses.
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        }
        $headers = @{
            'Accept'               = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent'           = 'release-kit-updater'
        }
        if ($Token) { $headers['Authorization'] = "Bearer $Token" }

        try {
            $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
        }
        catch {
            $hint = if ($Token) { '' } else { ' A private repository needs -Token.' }
            throw "Could not read the latest release of $Repository ($($_.Exception.Message)).$hint"
        }
        $result.Tag = [string]$release.tag_name

        $manifestAsset = @($release.assets | Where-Object { $_.name -eq 'release-manifest.json' }) | Select-Object -First 1
        if (-not $manifestAsset) { throw "Release $($result.Tag) of $Repository has no release-manifest.json." }
        $manifestText = Get-ReleaseAssetText -Asset $manifestAsset -Headers $headers -TimeoutSec $TimeoutSec
        if ($manifestText.Length -gt 1MB) { throw 'release-manifest.json is larger than 1 MB.' }
        $manifest = $manifestText | ConvertFrom-Json
        if ($manifest.schema -ne 1) {
            throw "release-manifest.json of $($result.Tag) has schema '$($manifest.schema)'; this updater reads schema 1. Update it by hand."
        }
        if ($manifest.repository -ne $Repository -or $manifest.tag -cne $result.Tag) {
            throw "release-manifest.json names repository '$($manifest.repository)' and tag '$($manifest.tag)', not $Repository and $($result.Tag)."
        }

        $root = [System.IO.Path]::GetFullPath($InstallPath)
        $entries = @(foreach ($property in $manifest.files.PSObject.Properties) {
                $entry = $property.Value
                $relative = [string]$entry.path
                if ($Path -and $Path -notcontains $relative) { continue }
                if ([string]$entry.sha256 -notmatch '^[0-9a-f]{64}$' -or [long]$entry.size -lt 0) {
                    throw "release-manifest.json has an invalid entry for '$relative'."
                }
                [pscustomobject]@{
                    Name   = $property.Name
                    Path   = $relative
                    Target = Resolve-InstallTarget -Root $root -RelativePath $relative
                    Sha256 = [string]$entry.sha256
                    Size   = [long]$entry.size
                }
            })
        if ($Path) {
            foreach ($wanted in $Path) {
                if (-not ($entries | Where-Object { $_.Path -eq $wanted })) { throw "release-manifest.json of $($result.Tag) does not list '$wanted'." }
            }
        }

        $changed = @($entries | Where-Object { -not (Test-FileMatch -Path $_.Target -Size $_.Size -Sha256 $_.Sha256) })
        if (-not $changed) {
            $result.Status = 'UpToDate'
            $result.Message = "Up to date with $($result.Tag)."
            return $result
        }
        if (-not $PSCmdlet.ShouldProcess("$($changed.Count) file(s) in $root", "Update to $Repository $($result.Tag)")) {
            $result.Status = 'Skipped'
            $result.Message = "Would update $(@($changed | ForEach-Object { $_.Path }) -join ', ') to $($result.Tag)."
            return $result
        }

        # Stage: every changed file downloaded and checked before anything is replaced.
        foreach ($entry in $changed) {
            $asset = @($release.assets | Where-Object { $_.name -eq $entry.Name }) | Select-Object -First 1
            if (-not $asset) { throw "Release $($result.Tag) is missing the asset $($entry.Name)." }
            $parent = Split-Path -Parent $entry.Target
            if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force -WhatIf:$false }
            $new = $entry.Target + '.new'
            $staged += $new
            Save-ReleaseAsset -Asset $asset -Headers $headers -TimeoutSec $TimeoutSec -OutFile $new
            if (-not (Test-FileMatch -Path $new -Size $entry.Size -Sha256 $entry.Sha256)) {
                throw "The downloaded $($entry.Path) does not match the size and SHA-256 in the manifest."
            }
            if ($VerifyAttestation) {
                if (-not (Get-Command -Name gh -ErrorAction SilentlyContinue)) { throw '-VerifyAttestation needs the GitHub CLI (gh).' }
                $verify = & gh attestation verify $new --repo $Repository --signer-workflow $SignerWorkflow 2>&1
                if ($LASTEXITCODE -ne 0) { throw "gh attestation verify refused $($entry.Path): $(($verify | Out-String).Trim())" }
            }
        }

        Install-StagedFile -Target @($changed | ForEach-Object { $_.Target })
        $staged = @()
        $result.Status = 'Updated'
        $result.Updated = @($changed | ForEach-Object { $_.Path })
        $result.Message = "Updated $($changed.Count) file(s) to $($result.Tag)."
        return $result
    }
    catch {
        $result.Status = 'Failed'
        $result.Message = $_.Exception.Message
        Write-Warning "Update-FromGitHubRelease: $($result.Message) Keeping the files there are."
        return $result
    }
    finally {
        # Its own staging files: removed even under -WhatIf.
        foreach ($file in $staged) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue -WhatIf:$false }
    }
}

<#
.SYNOPSIS
    The full path of a manifest path inside Root; throws for one that could leave it.
#>
function Resolve-InstallTarget {
    param ([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains(':') -or (($RelativePath -split '[\\/]') | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' })) {
        throw "release-manifest.json has an unsafe path: '$RelativePath'."
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    $prefix = $Root.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "release-manifest.json has a path outside the install folder: '$RelativePath'."
    }
    return $full
}

<#
.SYNOPSIS
    True when Path is a file of exactly Size bytes with SHA-256 Sha256.
#>
function Test-FileMatch {
    param ([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][long]$Size, [Parameter(Mandatory = $true)][string]$Sha256)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -ne $Size) { return $false }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha256
}

<#
.SYNOPSIS
    Downloads a release asset to OutFile: the API's asset URL with a token (which a private
    repository needs), else its public download link.
#>
function Save-ReleaseAsset {
    param ($Asset, [hashtable]$Headers, [int]$TimeoutSec, [string]$OutFile)

    if ($Headers.ContainsKey('Authorization')) {
        $assetHeaders = $Headers.Clone()
        $assetHeaders['Accept'] = 'application/octet-stream'
        Invoke-WebRequest -Uri $Asset.url -Headers $assetHeaders -TimeoutSec $TimeoutSec -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
    else {
        Invoke-WebRequest -Uri $Asset.browser_download_url -Headers @{ 'User-Agent' = $Headers['User-Agent'] } -TimeoutSec $TimeoutSec -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
}

<#
.SYNOPSIS
    A small release asset (the manifest) as UTF-8 text.
#>
function Get-ReleaseAssetText {
    param ($Asset, [hashtable]$Headers, [int]$TimeoutSec)

    # A temporary file of its own, so -WhatIf on the caller does not apply to it.
    $WhatIfPreference = $false
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('release-manifest-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Save-ReleaseAsset -Asset $Asset -Headers $Headers -TimeoutSec $TimeoutSec -OutFile $file
        return [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8)
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

<#
.SYNOPSIS
    Moves each Target.new over Target, keeping the old one as Target.old until all have moved; if
    any move fails, puts every file back as it was and throws.
#>
function Install-StagedFile {
    param ([Parameter(Mandatory = $true)][string[]]$Target)

    # Called only after the caller's ShouldProcess said yes.
    $WhatIfPreference = $false
    $done = @()
    try {
        foreach ($file in $Target) {
            $old = $file + '.old'
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
            $hadOld = Test-Path -LiteralPath $file
            if ($hadOld) { [System.IO.File]::Move($file, $old) }
            $done += [pscustomobject]@{ File = $file; Old = $old; HadOld = $hadOld }
            [System.IO.File]::Move($file + '.new', $file)
        }
    }
    catch {
        $failure = $_.Exception.Message
        foreach ($step in $done) {
            if (Test-Path -LiteralPath $step.File) {
                if (-not $step.HadOld -or (Test-Path -LiteralPath $step.Old)) { Remove-Item -LiteralPath $step.File -Force -ErrorAction SilentlyContinue }
            }
            if ($step.HadOld -and (Test-Path -LiteralPath $step.Old)) { [System.IO.File]::Move($step.Old, $step.File) }
        }
        throw "Could not replace the files ($failure); put the old ones back."
    }
    foreach ($step in $done) {
        if ($step.HadOld) { Remove-Item -LiteralPath $step.Old -Force -ErrorAction SilentlyContinue }
    }
}
