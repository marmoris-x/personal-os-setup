# Pester 5.9.1 (pinned - see docs/decisions/0010-test-strategy.md).
# How a GitHub release names its files: setup/lib/releases.ps1, tested without any network.
#
# The asset lists below are RECORDED, not fetched: they are the real names the two releases
# carried on 2026-10-14 (measured with `gh api repos/<repo>/releases/latest --jq '.assets[].name'`).
# A test that called the API would be a live check of somebody else's repository and would fail
# in an offline CI; what this file keeps is that our code reads the shapes we measured. The live
# end-to-end proof is the full-setup CI job, which really downloads and installs on Linux.
# Setup goes in BeforeAll: top-level code here would only run during discovery (Pester 5).
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'setup/lib/manifest.ps1')
    . (Join-Path $repoRoot 'setup/lib/releases.ps1')

    # trufflehog v3.99.2 (the release that made the first full-setup run fail)
    $script:trufflehogAssets = @(
        @{ name = 'trufflehog_3.99.2_checksums.txt' }
        @{ name = 'trufflehog_3.99.2_checksums.txt.pem' }
        @{ name = 'trufflehog_3.99.2_darwin_amd64.tar.gz' }
        @{ name = 'trufflehog_3.99.2_linux_amd64.tar.gz' }
        @{ name = 'trufflehog_3.99.2_linux_arm64.tar.gz' }
        @{ name = 'trufflehog_3.99.2_windows_amd64.tar.gz' }
    )
    $script:trufflehogSums = @(
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  trufflehog_3.99.2_darwin_amd64.tar.gz'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  trufflehog_3.99.2_linux_amd64.tar.gz'
        'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  trufflehog_3.99.2_linux_arm64.tar.gz'
    ) -join "`n"

    # uv 0.13.1 - the .sha256 files sit next to each asset, and the file is a real sha256sum line
    $script:uvAssetName = 'uv-x86_64-unknown-linux-gnu.tar.gz'
    $script:uvAssets = @(
        @{ name = 'sha256.sum' }
        @{ name = 'uv-aarch64-unknown-linux-gnu.tar.gz' }
        @{ name = 'uv-aarch64-unknown-linux-gnu.tar.gz.sha256' }
        @{ name = $script:uvAssetName }
        @{ name = $script:uvAssetName + '.sha256' }
        @{ name = 'uv-x86_64-pc-windows-msvc.zip' }
    )
    # the file's real content, measured 2026-10-14
    $script:uvShaText = 'eadd9d27c134ab5ac1ffd4473b97a741407f3ea238288f03121fc4deddf90220  ' + $script:uvAssetName

    $script:linuxPackages = (Get-Content -LiteralPath (Join-Path $repoRoot 'linux/packages.yaml') -Raw | ConvertFrom-Yaml)
}

Describe 'the release asset name' {
    It 'is found by the END of the name, because the version sits inside it' {
        # the yaml says "linux_amd64.tar.gz"; the release says trufflehog_3.99.2_linux_amd64.tar.gz
        $asset = Select-ReleaseAsset -Assets $script:trufflehogAssets -Suffix 'linux_amd64.tar.gz'
        $asset | Should -Not -BeNullOrEmpty
        $asset.name | Should -BeExactly 'trufflehog_3.99.2_linux_amd64.tar.gz'
    }

    It 'is not found by an exact comparison - the shape that broke' {
        # This is the state the old code was in: it compared the whole name, so it found nothing
        # in the release of that day and trufflehog silently stayed missing.
        @($script:trufflehogAssets | Where-Object { $_.name -eq 'linux_amd64.tar.gz' }).Count |
            Should -Be 0 -Because 'the release carries its version in the file name'
    }

    It 'answers empty for a suffix the release does not carry' {
        Select-ReleaseAsset -Assets $script:trufflehogAssets -Suffix 'linux_riscv64.tar.gz' | Should -BeNullOrEmpty
        Select-ReleaseAsset -Assets $script:trufflehogAssets -Suffix '' | Should -BeNullOrEmpty
    }
}

Describe 'the checksum of a release' {
    It 'prefers the asset own .sha256 file, then a checksums.txt' {
        (Get-ReleaseChecksumAsset -Assets $script:uvAssets -AssetName $script:uvAssetName).name |
            Should -BeExactly ($script:uvAssetName + '.sha256')
        (Get-ReleaseChecksumAsset -Assets $script:trufflehogAssets -AssetName 'trufflehog_3.99.2_linux_amd64.tar.gz').name |
            Should -BeExactly 'trufflehog_3.99.2_checksums.txt'
    }

    It 'reads the line that belongs to the asset' {
        Find-ReleaseChecksum -Text $script:trufflehogSums -AssetName 'trufflehog_3.99.2_linux_amd64.tar.gz' |
            Should -BeExactly ('b' * 64)
        Find-ReleaseChecksum -Text $script:trufflehogSums -AssetName 'trufflehog_3.99.2_linux_arm64.tar.gz' |
            Should -BeExactly ('c' * 64)
    }

    It 'reads a file that carries nothing but the hash' {
        Find-ReleaseChecksum -Text ('d' * 64) -AssetName 'anything.tar.gz' | Should -BeExactly ('d' * 64)
        Find-ReleaseChecksum -Text $script:uvShaText -AssetName $script:uvAssetName |
            Should -BeExactly 'eadd9d27c134ab5ac1ffd4473b97a741407f3ea238288f03121fc4deddf90220'
    }

    It 'answers empty when the text carries no line for the asset' {
        # empty means the install is refused instead of running unverified
        Find-ReleaseChecksum -Text $script:trufflehogSums -AssetName 'trufflehog_3.99.2_darwin_arm64.tar.gz' | Should -BeExactly ''
        Find-ReleaseChecksum -Text '' -AssetName 'x.tar.gz' | Should -BeExactly ''
    }
}

Describe 'linux/packages.yaml and the releases it names' {
    It 'resolves every release asset against the recorded release' {
        $recorded = @{
            trufflehog = $script:trufflehogAssets
            uv         = $script:uvAssets
        }
        $bad = New-Object System.Collections.Generic.List[string]
        $checked = 0
        foreach ($rel in @(Get-ManifestField $script:linuxPackages 'releases')) {
            $name = [string](Get-ManifestField $rel 'name')
            if (-not $recorded.ContainsKey($name)) { continue }
            foreach ($key in @('asset_linux_x86_64', 'asset_linux_arm64')) {
                $suffix = [string](Get-ManifestField $rel $key)
                if (-not $suffix) { continue }
                # the arm64 asset of a release is not in the recorded x86_64 list on purpose:
                # only check the ones the recording carries, and say so
                if (($name -eq 'trufflehog') -and ($key -eq 'asset_linux_x86_64')) {
                    $checked++
                    if (-not (Select-ReleaseAsset -Assets $recorded[$name] -Suffix $suffix)) { $bad.Add($name + ' ' + $suffix) }
                }
                if (($name -eq 'uv') -and ($key -eq 'asset_linux_x86_64')) {
                    $checked++
                    if (-not (Select-ReleaseAsset -Assets $recorded[$name] -Suffix $suffix)) { $bad.Add($name + ' ' + $suffix) }
                }
            }
        }
        $checked | Should -Be 2
        $bad.Count | Should -Be 0 -Because ('no asset of the recorded release ends in: ' + ($bad -join ', '))
    }

    It 'says how many folder levels an archive carries, and uv really has one' {
        $uv = @(Get-ManifestField $script:linuxPackages 'releases') | Where-Object { [string](Get-ManifestField $_ 'name') -eq 'uv' }
        [string](Get-ManifestField $uv 'strip_components') | Should -BeExactly '1' -Because 'the uv archive unpacks into uv-x86_64-unknown-linux-gnu/'
        $th = @(Get-ManifestField $script:linuxPackages 'releases') | Where-Object { [string](Get-ManifestField $_ 'name') -eq 'trufflehog' }
        [string](Get-ManifestField $th 'strip_components') | Should -BeExactly '' -Because 'the trufflehog archive puts its binary at the top level'
    }

    It 'names a repository and a binary for every release' {
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($rel in @(Get-ManifestField $script:linuxPackages 'releases')) {
            foreach ($key in @('name', 'repo', 'binary')) {
                if (-not [string](Get-ManifestField $rel $key)) { $bad.Add([string](Get-ManifestField $rel 'name') + ' has no ' + $key) }
            }
        }
        $bad.Count | Should -Be 0 -Because ($bad -join '; ')
    }

    It 'reads the text of a response that arrives as bytes' {
        # Measured on ubuntu-latest (2026-10-14, the second full-setup run): GitHub serves a
        # checksum file as application/octet-stream, Invoke-WebRequest hands back a byte array,
        # and the [string] parameter of Find-ReleaseChecksum refused it - "Cannot convert value
        # to type System.String". The live install ended there (6 of its 15 stage lines printed).
        # Both shapes below are the ones a caller really gets.
        $line = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  trufflehog_3.99.2_linux_amd64.tar.gz'
        $asBytes = [Text.Encoding]::UTF8.GetBytes($line + "`n")
        (Convert-ReleaseText -Content $asBytes) | Should -BeExactly ($line + "`n")
        (Convert-ReleaseText -Content $line) | Should -BeExactly $line -Because 'a text response comes back as a string'
        (Convert-ReleaseText -Content '') | Should -BeExactly '' -Because 'an empty answer must not fail the parameter binding (review 18, nit)'
        $found = Find-ReleaseChecksum -Text (Convert-ReleaseText -Content $asBytes) -AssetName 'trufflehog_3.99.2_linux_amd64.tar.gz'
        $found | Should -BeExactly 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    }

    It 'asks for a token when the environment carries one, and stays anonymous without' {
        # Review 18 (M7) measured the consequence of the anonymous limit on a runner: trufflehog
        # came back "403 (rate limit exceeded)" in the first install, while the second install of
        # the SAME run installed it - the retry was fine, the verify in between was not. CI hands
        # the job a token (github.token as GH_TOKEN); a user's machine usually has none, and then
        # the call stays anonymous exactly as before. The value never reaches a report.
        $saved = @{}
        foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        try {
            $plain = Get-GitHubApiHeaders
            $plain.Keys | Should -Not -Contain 'Authorization' -Because 'no token means no header to send'
            $plain['User-Agent'] | Should -BeExactly 'personal-os-setup' -Because 'GitHub refuses a request without one'
            [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', 'test-token-value')
            (Get-GitHubApiHeaders)['Authorization'] | Should -BeExactly 'Bearer test-token-value'
            [Environment]::SetEnvironmentVariable('GITHUB_TOKEN', $null)
            [Environment]::SetEnvironmentVariable('GH_TOKEN', 'test-token-value')
            (Get-GitHubApiHeaders)['Authorization'] | Should -BeExactly 'Bearer test-token-value' -Because 'GH_TOKEN is the name a person sets'
        }
        finally {
            foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN')) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
}
