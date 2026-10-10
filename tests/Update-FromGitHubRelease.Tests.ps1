# Tests for src/Update-FromGitHubRelease.ps1 (Pester 5 or 6, PowerShell 7 or Windows PowerShell 5.1).
# The web calls are mocked: Invoke-RestMethod answers the latest-release request, and
# Invoke-WebRequest writes the bytes $script:Served holds for a URL to -OutFile.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Update-FromGitHubRelease.ps1')

    function Get-Sha256 ([byte[]]$Bytes) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { return (-join ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') })) } finally { $sha.Dispose() }
    }

    function Get-Bytes ([string]$Text) { return [System.Text.Encoding]::UTF8.GetBytes($Text) }

    # A release of the files in $Files (manifest path -> text), served under its asset names, with
    # $Change applied to the manifest before it is served.
    function Set-TestRelease {
        param ([hashtable]$Files, [scriptblock]$Change = {}, [string]$Tag = 'v1.2.0', [string]$Repository = 'owner/tool')
        $script:Served = @{}
        $assets = @()
        $entries = [ordered]@{}
        foreach ($path in ($Files.Keys | Sort-Object)) {
            $name = Split-Path -Leaf $path
            $bytes = Get-Bytes $Files[$path]
            $entries[$name] = [ordered]@{ path = $path; url = "asset:$name"; sha256 = (Get-Sha256 $bytes); size = $bytes.Length }
            $script:Served["https://dl.example/$name"] = $bytes
            $script:Served["https://api.example/assets/$name"] = $bytes
            $assets += [pscustomobject]@{ name = $name; url = "https://api.example/assets/$name"; browser_download_url = "https://dl.example/$name" }
        }
        $manifest = [ordered]@{ schema = 1; repository = $Repository; tag = $Tag; version = $Tag.TrimStart('v'); commit = ('c' * 40); files = $entries }
        & $Change $manifest
        $manifestBytes = Get-Bytes ($manifest | ConvertTo-Json -Depth 5)
        $script:Served['https://dl.example/release-manifest.json'] = $manifestBytes
        $script:Served['https://api.example/assets/release-manifest.json'] = $manifestBytes
        $assets += [pscustomobject]@{ name = 'release-manifest.json'; url = 'https://api.example/assets/release-manifest.json'; browser_download_url = 'https://dl.example/release-manifest.json' }
        $script:Release = [pscustomobject]@{ tag_name = $Tag; assets = $assets }
    }

    function Set-LocalFile ([string]$RelativePath, [string]$Text) {
        $full = Join-Path $script:Install $RelativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
        [System.IO.File]::WriteAllBytes($full, (Get-Bytes $Text))
    }

    function Get-LocalText ([string]$RelativePath) {
        return [System.IO.File]::ReadAllText((Join-Path $script:Install $RelativePath))
    }

    function Get-Leftover {
        return @(Get-ChildItem -LiteralPath $script:Install -Recurse -File | Where-Object { $_.Name -match '\.(new|old)$' })
    }
}

Describe 'Update-FromGitHubRelease' {
    BeforeEach {
        $script:Install = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:Install
        Mock Invoke-RestMethod { $script:Release }
        Mock Invoke-WebRequest {
            # -Uri binds as a [Uri]; the table is keyed by the text.
            $key = [string]$Uri
            if (-not $script:Served.ContainsKey($key)) { throw "404 for $key" }
            [System.IO.File]::WriteAllBytes($OutFile, $script:Served[$key])
        }
        Mock Write-Warning {}
    }

    It 'Reports UpToDate and downloads no file when every file matches' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2'; 'lib/helper.psm1' = 'helper v2' }
        Set-LocalFile 'tool.ps1' 'v2'
        Set-LocalFile 'lib/helper.psm1' 'helper v2'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        $result.Status | Should -Be 'UpToDate'
        $result.Tag | Should -Be 'v1.2.0'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like '*release-manifest.json' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'Replaces a changed file, creates a missing one in its folder, and leaves the rest alone' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2'; 'lib/helper.psm1' = 'helper v2'; 'same.txt' = 'same' }
        Set-LocalFile 'tool.ps1' 'v1'
        Set-LocalFile 'same.txt' 'same'
        Set-LocalFile 'mine.txt' 'not in the manifest'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        $result.Status | Should -Be 'Updated'
        @($result.Updated | Sort-Object) | Should -Be @('lib/helper.psm1', 'tool.ps1')
        Get-LocalText 'tool.ps1' | Should -Be 'v2'
        Get-LocalText 'lib/helper.psm1' | Should -Be 'helper v2'
        Get-LocalText 'mine.txt' | Should -Be 'not in the manifest'
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -like '*same.txt' }
        Get-Leftover | Should -BeNullOrEmpty
    }

    It 'Changes nothing when a download does not match the manifest''s <What>' -ForEach @(
        @{ What = 'SHA-256'; Served = 'v3' }
        @{ What = 'size'; Served = 'v2 plus more' }
    ) {
        Set-TestRelease -Files @{ 'a.ps1' = 'a v2'; 'tool.ps1' = 'v2' }
        $script:Served['https://dl.example/tool.ps1'] = Get-Bytes $Served
        Set-LocalFile 'a.ps1' 'a v1'
        Set-LocalFile 'tool.ps1' 'v1'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'does not match the size and SHA-256'
        Get-LocalText 'a.ps1' | Should -Be 'a v1'
        Get-LocalText 'tool.ps1' | Should -Be 'v1'
        Get-Leftover | Should -BeNullOrEmpty
        Should -Invoke Write-Warning -Times 1 -Exactly
    }

    It 'Refuses a manifest with <Case>' -ForEach @(
        @{ Case = 'an unknown schema'; Change = { param ($m) $m.schema = 2 }; Message = "schema '2'" }
        @{ Case = 'another repository'; Change = { param ($m) $m.repository = 'someone/else' }; Message = "repository 'someone/else'" }
        @{ Case = 'another tag'; Change = { param ($m) $m.tag = 'v0.9.0' }; Message = "tag 'v0.9.0'" }
        @{ Case = 'a parent path'; Change = { param ($m) $m.files['tool.ps1'].path = '../tool.ps1' }; Message = 'unsafe path' }
        @{ Case = 'a rooted path'; Change = { param ($m) $m.files['tool.ps1'].path = '/etc/tool.ps1' }; Message = 'unsafe path' }
        @{ Case = 'a drive path'; Change = { param ($m) $m.files['tool.ps1'].path = 'C:/tool.ps1' }; Message = 'unsafe path' }
        @{ Case = 'a dot segment'; Change = { param ($m) $m.files['tool.ps1'].path = 'lib/./tool.ps1' }; Message = 'unsafe path' }
        @{ Case = 'a bad hash'; Change = { param ($m) $m.files['tool.ps1'].sha256 = 'ABC' }; Message = 'invalid entry' }
    ) {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2' } -Change $Change
        Set-LocalFile 'tool.ps1' 'v1'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match $Message
        Get-LocalText 'tool.ps1' | Should -Be 'v1'
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -like '*tool.ps1' }
    }

    It 'Fails, keeping the files, when the latest release cannot be read' {
        Mock Invoke-RestMethod { throw 'No such host is known.' }
        Set-LocalFile 'tool.ps1' 'v1'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'Could not read the latest release of owner/tool.*No such host.*needs -Token'
        Get-LocalText 'tool.ps1' | Should -Be 'v1'
    }

    It 'Fails when the release has no manifest' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2' }
        $script:Release.assets = @($script:Release.assets | Where-Object { $_.name -ne 'release-manifest.json' })

        (Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install).Message | Should -Match 'has no release-manifest.json'
    }

    It 'Fails when a changed file''s asset is missing from the release' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2' }
        $script:Release.assets = @($script:Release.assets | Where-Object { $_.name -ne 'tool.ps1' })
        Set-LocalFile 'tool.ps1' 'v1'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        $result.Message | Should -Match 'missing the asset tool.ps1'
        Get-LocalText 'tool.ps1' | Should -Be 'v1'
    }

    It 'With a token, sends it and downloads from the API''s asset URL' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2' }
        Set-LocalFile 'tool.ps1' 'v1'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install -Token 't0ken'

        $result.Status | Should -Be 'Updated'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Headers['Authorization'] -eq 'Bearer t0ken' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example/assets/tool.ps1' -and $Headers['Accept'] -eq 'application/octet-stream' -and $Headers['Authorization'] -eq 'Bearer t0ken'
        }
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -like 'https://dl.example/*' }
    }

    It 'Without a token, sends no Authorization header anywhere' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2' }

        $null = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter { $Headers.ContainsKey('Authorization') }
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Headers.ContainsKey('Authorization') }
    }

    It 'With -Path, updates only the paths named' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2'; 'other.ps1' = 'other v2' }
        Set-LocalFile 'tool.ps1' 'v1'
        Set-LocalFile 'other.ps1' 'other v1'

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install -Path 'tool.ps1'

        $result.Updated | Should -Be @('tool.ps1')
        Get-LocalText 'other.ps1' | Should -Be 'other v1'
    }

    It 'With -Path, fails for a path the manifest does not list' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2' }

        (Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install -Path 'nope.ps1').Message | Should -Match "does not list 'nope.ps1'"
    }

    It 'Puts back every file it already replaced when a later one cannot be replaced' {
        Set-TestRelease -Files @{ 'a.ps1' = 'a v2'; 'b.ps1' = 'b v2' }
        Set-LocalFile 'a.ps1' 'a v1'
        # A folder where b.ps1 should be: its download stages fine, its swap fails.
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Install 'b.ps1')

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install

        $result.Status | Should -Be 'Failed'
        $result.Message | Should -Match 'put the old ones back'
        Get-LocalText 'a.ps1' | Should -Be 'a v1'
        Test-Path -LiteralPath (Join-Path $script:Install 'b.ps1') -PathType Container | Should -BeTrue
        Get-Leftover | Should -BeNullOrEmpty
    }

    It 'With -WhatIf, reports Skipped and changes nothing' {
        Set-TestRelease -Files @{ 'tool.ps1' = 'v2' }
        Set-LocalFile 'tool.ps1' 'v1'

        $tempManifests = { @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'release-manifest-*.json' -ErrorAction SilentlyContinue).Count }
        $before = & $tempManifests

        $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install -WhatIf

        & $tempManifests | Should -Be $before -Because 'its own temporary copy of the manifest is removed even under -WhatIf'
        $result.Status | Should -Be 'Skipped'
        $result.Message | Should -Match 'Would update tool.ps1 to v1.2.0'
        Get-LocalText 'tool.ps1' | Should -Be 'v1'
        Should -Invoke Invoke-WebRequest -Times 0 -ParameterFilter { $Uri -like '*tool.ps1' }
    }

    Context '-VerifyAttestation' {
        BeforeEach {
            # A function named gh wins over the real CLI, and sets the exit code it is told to.
            function global:gh { $global:GhCalls += , ($args -join ' '); $global:LASTEXITCODE = $global:GhExitCode; 'gh says' }
            $global:GhCalls = @()
            $global:GhExitCode = 0
            Set-TestRelease -Files @{ 'tool.ps1' = 'v2' }
            Set-LocalFile 'tool.ps1' 'v1'
        }

        AfterEach {
            Remove-Item -Path Function:\global:gh -ErrorAction SilentlyContinue
        }

        It 'Verifies each downloaded file against the signer workflow before replacing it' {
            $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install -VerifyAttestation

            $result.Status | Should -Be 'Updated'
            $global:GhCalls.Count | Should -Be 1
            $global:GhCalls[0] | Should -Match '^attestation verify \S+tool\.ps1\.new --repo owner/tool --signer-workflow J-MaFf/release-kit/\.github/workflows/release\.yml$'
        }

        It 'Changes nothing when the attestation does not verify' {
            $global:GhExitCode = 1

            $result = Update-FromGitHubRelease -Repository owner/tool -InstallPath $script:Install -VerifyAttestation

            $result.Status | Should -Be 'Failed'
            $result.Message | Should -Match 'gh attestation verify refused tool.ps1: gh says'
            Get-LocalText 'tool.ps1' | Should -Be 'v1'
            Get-Leftover | Should -BeNullOrEmpty
        }
    }
}
