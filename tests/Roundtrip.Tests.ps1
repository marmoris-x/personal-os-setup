# Pester 5.9.1 (pinned). The placeholder round trip.
#
# The strongest check of the whole export pipeline runs only on a machine that HAS the
# live system and the personal.yaml: it renders every repo file back with the real
# values and compares it to the live original. Entry kinds that intentionally diverge
# (append / drop_lines in the manifest) are skipped and counted. In CI this test is
# skipped (no personal.yaml there) - that is reported, never silently ignored.
# Top level runs during discovery: the -Skip condition below is evaluated there, so the
# flag must live here as well as in BeforeAll (which serves the run phase).
$script:roundtripRepo = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:roundtripRepo 'setup/lib/manifest.ps1')
. (Join-Path $script:roundtripRepo 'setup/lib/platform.ps1')
$script:roundtripOs = Get-PlatformId
$configPath = Join-Path (Get-PlatformHome) '.personal-os/personal.yaml'
$script:hasLive = Test-Path -LiteralPath $configPath

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'setup/lib/manifest.ps1')
    . (Join-Path $repoRoot 'setup/lib/platform.ps1')
    . (Join-Path $repoRoot 'setup/lib/placeholders.ps1')
    $script:roundtripOs = Get-PlatformId
    $configPath = Join-Path (Get-PlatformHome) '.personal-os/personal.yaml'
    $script:hasLive = Test-Path -LiteralPath $configPath
}

Describe 'placeholder vocabulary' {
    BeforeAll {
        # folder NAMES only, joined at runtime - the repo never carries a literal path
        $syncDirName = 'OneDrive'
        $docsDirName = 'Dokumente'
        # The fake roots carry the shape of the system this test runs on: Join-Path and
        # Split-Path answer per platform, and a "C:" drive does not exist on macOS/Linux
        # (measured in CI, 2026-10-14). The specific values do not matter for the vocabulary.
        $script:fakeWindows = ($IsWindows -or $env:OS -eq 'Windows_NT')
        $fakeHome = if ($script:fakeWindows) { 'C:\Users\someone' } else { '/home/someone' }
        $script:fakeRoots = @{
            HOME      = $fakeHome
            DOCUMENTS = Join-Path $fakeHome (Join-Path $syncDirName $docsDirName)
            VAULT     = if ($script:fakeWindows) { 'C:\PersonalOS' } else { (Join-Path $fakeHome 'PersonalOS') }
            DEV       = if ($script:fakeWindows) { 'C:\Dev' } else { (Join-Path $fakeHome 'Dev') }
        }
        $script:fakeCfg = @{
            user_name        = 'Vera Beispiel'
            user_given       = 'Vera'
            user_family      = 'Beispiel'
            github_account   = 'example-user'
            b2_bucket        = 'example-kopia-backup'
            archive_dir_name = 'Dokumentenarchiv'
            morning_time     = '07:00'
            backup_time      = '12:30'
        }
        $script:map = Get-PlaceholderMap -Roots $script:fakeRoots -ConfigValues $script:fakeCfg
        $script:map['{{INSTALL_DATE}}'] = '2026-01-01'
        $script:map['{{USER_SID}}'] = 'S-1-5-21-1-2-3-1001'
        $script:map['{{START_BOUNDARY}}'] = '2026-01-01T07:00:00+01:00'
    }

    It 'expands every declared placeholder to its value' {
        foreach ($k in $script:map.Keys) {
            (Expand-Placeholders $k $script:map) | Should -BeExactly ([string]$script:map[$k]) -Because $k
        }
    }

    It 'leaves unknown tokens alone (research runtime placeholders)' {
        (Expand-Placeholders 'x {{N_SOURCES}} y {{SOMETHING_ELSE}}' $script:map) | Should -Be 'x {{N_SOURCES}} y {{SOMETHING_ELSE}}'
    }

    It 'gives every rooted path a bash spelling' {
        Convert-PathStyle 'C:\Users\someone' 'bash' | Should -Be '/c/Users/someone'
        Convert-PathStyle 'not-a-path' 'bash' | Should -BeNullOrEmpty
        if (-not $script:fakeWindows) {
            # on macOS and Linux the bash style is the path itself - there is no drive letter
            # (the old expectation here was $null; that is what left {{DEV_BASH}} and
            # {{HOME_BASH}} unrendered in the ubuntu job, measured 2026-10-14)
            Convert-PathStyle '/home/someone' 'bash' | Should -Be '/home/someone'
        }
    }

    It 'every {{TOKEN}} used in the mirror folders is either known or whitelisted' {
        $known = @($script:map.Keys) + @('{{N_SOURCES}}')
        $unknown = New-Object System.Collections.Generic.List[string]
        $mirrorFiles = foreach ($mirror in (Get-MirrorFolder)) {
            $dir = Join-Path $repoRoot ($mirror.RepoRel -replace '/', '\')
            if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Recurse -File -Force }
        }
        foreach ($f in $mirrorFiles) {
            $ext = $f.Extension.ToLowerInvariant()
            if (@('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.exe', '.dll', '.pyc') -contains $ext) { continue }
            $text = [IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, '\{\{[A-Z0-9_]+\}\}')) {
                if ($known -notcontains $m.Value) { $unknown.Add($m.Value + ' in ' + $f.Name) }
            }
        }
        $unknown.Count | Should -Be 0 -Because (($unknown | Select-Object -Unique) -join '; ')
    }

    It 'no file that the export mirrors carries a render-time placeholder' {
        # The export cannot reverse a value that exists only at render time. {{USER_SID}} and
        # {{START_BOUNDARY}} have no pair at all; {{INSTALL_DATE}} had one that read the install
        # journal - and a partial install run (install.ps1 -Components) moves the journal's date
        # without re-rendering every file, so on 2026-10-13 the live vault/000-meta/backup.md
        # could no longer be reversed and drift-check.ps1 went red. Render-time placeholders
        # belong in the install-once skeletons (type: doc-only), which the export never mirrors.
        # Derived, not hard-coded: every placeholder install.ps1 adds beyond the base map is a
        # render-time value the export cannot reverse. A new one added there is covered here
        # without a second edit.
        $installText = [IO.File]::ReadAllText((Join-Path $repoRoot 'install.ps1'))
        $renderTime = @([regex]::Matches($installText, "\`$placeholders\['(\{\{[A-Z0-9_]+\}\})'\]") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        ($renderTime -contains '{{INSTALL_DATE}}') | Should -BeTrue -Because 'the derivation from install.ps1 must find the known render-time placeholders (a broken pattern would make this test vacuous)'
        $manifest = Get-Manifest -Path (Join-Path $repoRoot 'setup\manifest.yaml')
        $hits = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($manifest.components)) {
            $type = [string](Get-ManifestField $e 'type')
            if ($type -notin @('copy', 'template')) { continue }
            $targetRel = [string](Get-ManifestField $e 'target')
            $repoPath = Join-Path $repoRoot (Get-RepoFileRel -Target $targetRel -StoreAs ([string](Get-ManifestField $e 'store_as')))
            $files = @()
            if (Get-ManifestField $e 'recursive') {
                if (Test-Path -LiteralPath $repoPath -PathType Container) { $files = @(Get-ChildItem -LiteralPath $repoPath -Recurse -File -Force) }
            }
            elseif (Test-Path -LiteralPath $repoPath -PathType Leaf) { $files = @(Get-Item -LiteralPath $repoPath) }
            # Where-Object drops the $null: @($null) has Count 1, and '' -like $null would then
            # match every non-recursive file and skip it silently (this test passed for the wrong
            # reason until it was made to fail on the known-bad tree first). Excludes count only
            # for recursive entries - the same place where the export applies them.
            $excludes = if (Get-ManifestField $e 'recursive') { @(Get-ManifestField $e 'exclude') | Where-Object { $_ } } else { @() }
            foreach ($f in $files) {
                $ext = $f.Extension.ToLowerInvariant()
                if (@('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.exe', '.dll', '.pyc') -contains $ext) { continue }
                # an excluded child is not mirrored either - the same matching as the export
                $childRel = $f.FullName.Substring($repoPath.Length).TrimStart('\', '/')
                $skip = $false
                foreach ($p in $excludes) {
                    if (($f.Name -like $p) -or ($childRel -like $p) -or ($childRel -like ('*\' + $p + '\*'))) { $skip = $true; break }
                }
                if ($skip) { continue }
                $text = [IO.File]::ReadAllText($f.FullName)
                foreach ($t in $renderTime) {
                    if ($text.Contains($t)) { $hits.Add(($f.FullName.Substring($repoRoot.Length).TrimStart('\')) + ' carries ' + $t) }
                }
            }
        }
        $hits.Count | Should -Be 0 -Because (($hits | Select-Object -First 5) -join '; ')
    }
}

Describe 'repo renders back to the live system (needs the live machine)' {
    It 'reproduces every exported file byte for byte' -Skip:(-not $script:hasLive) {
        $cfg = @{}
        $loaded = ConvertFrom-Yaml (Get-Content -LiteralPath $configPath -Raw)
        if ($loaded -is [System.Collections.IDictionary]) { foreach ($k in $loaded.Keys) { $cfg[[string]$k] = $loaded[$k] } }
        else { foreach ($p in $loaded.PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
        $roots = @{
            HOME      = Get-PlatformHome
            DOCUMENTS = Get-PlatformDocuments
            VAULT     = [string]$cfg['vault_path']
            DEV       = [string]$cfg['dev_root']
        }
        # the map of THIS system: {{PWSH_HOST}} renders to powershell.exe on Windows and to
        # pwsh on macOS/Linux, so the round trip is checked against the right direction
        $map = Get-PlaceholderMap -Roots $roots -ConfigValues $cfg -Os $script:roundtripOs
        # A fixed old date, not today: this test must hold on every day, not only on the day the
        # live file was rendered (before 2.1.1 it failed on any later day - the live backup note
        # carried the render day while this line used the run day). A mirrored file that carries
        # {{INSTALL_DATE}} has no stable round trip at all; the vocabulary test forbids it.
        $map['{{INSTALL_DATE}}'] = '2020-01-01'
        $manifest = Get-Manifest -Path (Join-Path $repoRoot 'setup\manifest.yaml')
        $bad = New-Object System.Collections.Generic.List[string]
        $checked = 0; $skipped = 0
        function Test-ExcludedRel([string]$relPath, $patterns) {
            # the same matching as export.ps1: this test compares only what export wrote
            if (-not $patterns) { return $false }
            $name = Split-Path $relPath -Leaf
            foreach ($p in $patterns) {
                if ($name -like $p) { return $true }
                if ($relPath -like $p) { return $true }
                if ($relPath -like ('*\' + $p + '\*')) { return $true }
            }
            return $false
        }
        $platforms = Get-PlatformData -RepoRoot $repoRoot
        foreach ($e in @($manifest.components)) {
            $type = [string](Get-ManifestField $e 'type')
            if ($type -notin @('copy', 'template')) { continue }
            if ((Get-ManifestField $e 'append') -or (Get-ManifestField $e 'drop_lines')) { $skipped++; continue }
            # a component the platform map marks `unsupported` here has no live file on this
            # system (pwsh-profile-unix on Windows, pwsh51-profile on macOS/Linux): the export
            # does not mirror it, so there is nothing to render back
            if (Test-PlatformUnsupported (Get-PlatformValue -Platforms $platforms -ComponentId ([string](Get-ManifestField $e 'id')) -Os $script:roundtripOs)) { $skipped++; continue }
            $src = [string](Get-ManifestField $e 'source')
            foreach ($k in $roots.Keys) { $src = $src.Replace('{' + $k + '}', $roots[$k]) }
            $targetRel = [string](Get-ManifestField $e 'target')
            # stored name (dot rule, store_as) and repo folder come from setup/lib/manifest.ps1
            $repoFile = Join-Path $repoRoot (Get-RepoFileRel -Target $targetRel -StoreAs ([string](Get-ManifestField $e 'store_as')))
            if (Get-ManifestField $e 'recursive') {
                if (-not (Test-Path -LiteralPath $src -PathType Container)) { $bad.Add('live missing: ' + $src); continue }
                foreach ($rf in (Get-ChildItem -LiteralPath $src -Recurse -File -Force)) {
                    $childRel = $rf.FullName.Substring($src.Length).TrimStart('\', '/')
                    if (Test-ExcludedRel $childRel (Get-ManifestField $e 'exclude')) { continue }
                    $repoChild = Join-Path $repoFile $childRel
                    if (-not (Test-Path -LiteralPath $repoChild)) { $bad.Add('repo missing: ' + $repoChild); continue }
                    $checked++
                    $rendered = Expand-Placeholders ([IO.File]::ReadAllText($repoChild)) $map
                    if ($rendered -cne [IO.File]::ReadAllText($rf.FullName)) { $bad.Add($childRel) }
                }
            }
            else {
                if (-not (Test-Path -LiteralPath $src)) { $bad.Add('live missing: ' + $src); continue }
                $checked++
                $rendered = Expand-Placeholders ([IO.File]::ReadAllText($repoFile)) $map
                if ($rendered -cne [IO.File]::ReadAllText($src)) { $bad.Add($targetRel) }
            }
        }
        $bad.Count | Should -Be 0 -Because (($bad | Select-Object -First 5) -join '; ')
        $checked | Should -BeGreaterThan 100
        Write-Host ('    (Roundtrip: ' + $checked + ' files compared, ' + $skipped + ' entries with append/drop_lines skipped)')
    }
}
