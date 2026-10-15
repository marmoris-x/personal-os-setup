# Pester 5.9.1 (pinned). The skeleton rule (task "folder-structure", section 3.2).
#
# This repo installs the SYSTEM, never the owner's data. A mirror folder may hold rules,
# settings, templates, scripts, skills and hooks - and nothing that records the owner's own
# situation: no task files, no notes, no research results, no recordings, no transcripts,
# no run records, no session state.
#
# Each rule below is written as "what is allowed", never as a blocklist of file names, so a new
# kind of personal file is caught instead of slipping through.
# Since 2.1.2 no folder needs a placeholder file: folders that carry no file of their own stand
# as dirs: entries in the manifest, and the install proof below checks them in a test sandbox.
# Setup goes in BeforeAll: top-level code here would only run during discovery (Pester 5).
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot

    function Get-MirrorFile {
        # every file in the three mirror folders, as a path relative to the repo
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($dir in @('home', 'vault', 'dev')) {
            $abs = Join-Path $repoRoot $dir
            if (-not (Test-Path -LiteralPath $abs)) { continue }
            foreach ($f in (Get-ChildItem -LiteralPath $abs -Recurse -File -Force)) {
                $out.Add(($f.FullName.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/'))
            }
        }
        return $out
    }
    $script:mirrorFiles = @(Get-MirrorFile)
}

Describe 'skeleton rule: the mirror folders hold only what may be installed' {

    It 'has mirror files at all (a silent zero would make every rule below pass)' {
        $script:mirrorFiles.Count | Should -BeGreaterThan 100
    }

    It 'the vault working folders hold nothing but their marker' {
        # 100-daily, 200-projects, 300-areas, 400-knowledge, 500-sources, 600-archive,
        # 900-inactive, outbox, trash: the structure matters, the content is the owner's.
        # Since 2.1.2 the .gitkeep placeholders are gone - the folders stand as dirs: entries
        # in the manifest. Only real content stays, like the archive's own README.
        $allowed = @('README.md')
        $bad = @($script:mirrorFiles | Where-Object {
                $_ -match '^vault/(100-daily|200-projects|300-areas|400-knowledge|500-sources|600-archive|900-inactive|outbox|trash)/' -and
                ($allowed -notcontains (Split-Path $_ -Leaf))
            })
        $bad.Count | Should -Be 0 -Because ('not part of the installable skeleton: ' + ($bad -join ', '))
    }

    It 'the vault inbox holds nothing at all' {
        # the folder itself comes from the manifest (dirs:), so not even a marker file remains
        $bad = @($script:mirrorFiles | Where-Object { $_ -match '^vault/inbox/' })
        $bad.Count | Should -Be 0 -Because ('recordings or transcripts must never enter the repo: ' + ($bad -join ', '))
    }

    It 'carries no placeholder file (the folders come from the manifest)' {
        # .gitkeep and friends were the old way to keep an empty folder in git. Since 2.1.2 the
        # dirs: entries in the manifest are the one mechanism (docs/structure.md), and the
        # install proof below shows the folders appear without any file of their own.
        $placeholderNames = @('.gitkeep', '.keep', '.placeholder')
        $bad = @($script:mirrorFiles | Where-Object { $placeholderNames -contains (Split-Path $_ -Leaf) })
        $bad.Count | Should -Be 0 -Because ('empty folders belong in the manifest, not faked with markers: ' + ($bad -join ', '))
    }

    It 'no audio or video recording is in a mirror' {
        $mediaExt = @('.mp3', '.m4a', '.wav', '.ogg', '.opus', '.flac', '.aac', '.wma', '.mp4', '.mov', '.mkv', '.webm', '.avi')
        $bad = @($script:mirrorFiles | Where-Object { $mediaExt -contains ([IO.Path]::GetExtension($_).ToLowerInvariant()) })
        $bad.Count | Should -Be 0 -Because ('recordings are the owner''s data: ' + ($bad -join ', '))
    }

    It 'no _removed folder and no leftover task file survives' {
        $bad = @($script:mirrorFiles | Where-Object { $_ -match '(^|/)_removed/' })
        $bad.Count | Should -Be 0 -Because ('a removed-component folder is not part of the skeleton: ' + ($bad -join ', '))
        # the German half of the pattern is assembled from two pieces: the language check
        # (check E) must not find the word this rule exists to hunt down
        $bad = @($script:mirrorFiles | Where-Object { (Split-Path $_ -Leaf) -match ('auf' + 'trag|assignment|brief') })
        $bad.Count | Should -Be 0 -Because ('task and brief documents are the owner''s paper: ' + ($bad -join ', '))
    }

    It 'no research note folder sits in the mirror' {
        $bad = @($script:mirrorFiles | Where-Object { $_ -match '/notes-\d+/' })
        $bad.Count | Should -Be 0 -Because ('research results belong in the vault, not in a test folder: ' + ($bad -join ', '))
    }

    It 'the home mirror carries no session or runtime state' {
        # Claude Code and the other tools keep their history outside what may be installed.
        # Compared as whole path SEGMENTS: a folder named 200-projects is a vault category,
        # while a folder named projects under home/ is agent session state.
        $forbiddenSeg = @('projects', 'sessions', 'file-history', 'shell-snapshots', 'paste-cache',
            'debug', 'telemetry', 'backups', 'state', 'tasks', 'teams')
        $bad = @($script:mirrorFiles | Where-Object {
                if ($_ -notmatch '^home/') { return $false }
                $segs = @(($_ -replace '^home/', '') -split '/')
                for ($i = 0; $i -lt ($segs.Count - 1); $i++) {
                    if ($forbiddenSeg -contains $segs[$i]) { return $true }
                }
                if ((Split-Path $_ -Leaf) -match '\.jsonl$|^history\.jsonl$|\.credentials\.json$') { return $true }
                return $false
            })
        $bad.Count | Should -Be 0 -Because ('session state and credentials must never be installed: ' + ($bad -join ', '))
    }

    It 'the profiles folder is a template, never a live profile' {
        # home/.claude/profiles/ holds real keys; only profiles-template/ may be in the repo
        $bad = @($script:mirrorFiles | Where-Object { $_ -match '\.claude/profiles/' })
        $bad.Count | Should -Be 0 -Because ('live provider profiles carry keys: ' + ($bad -join ', '))
    }

    It 'the starter templates are stored as .tmpl, so nobody mistakes them for real notes' {
        foreach ($t in @('vault/000-meta/index.md.tmpl', 'vault/000-meta/log.md.tmpl', 'vault/000-meta/todo.md.tmpl')) {
            $script:mirrorFiles | Should -Contain $t
        }
        $bad = @($script:mirrorFiles | Where-Object { $_ -match '^vault/000-meta/(index|log|todo)\.md$' })
        $bad.Count | Should -Be 0 -Because ('a working note without the .tmpl marker: ' + ($bad -join ', '))
    }
}

Describe 'folder entries: the manifest is the definition, the install is the proof' {

    BeforeAll {
        # The same sandbox pattern as Install.Tests: a run of its own under tests\_tmp (or the
        # work folder check.ps1 hands over), so two parallel check runs cannot collide. The
        # full install runs, so the proof covers the normal path, not a narrowed one.
        # (A -Components list would need one argv token per id through pwsh -File; the full
        # run is both simpler and the stronger claim.)
        . (Join-Path $repoRoot 'setup\lib\manifest.ps1')
        Import-Module powershell-yaml -ErrorAction Stop
        $fixture = Join-Path $PSScriptRoot 'fixtures\personal.dummy.yaml'
        $scratchRoot = if ($env:PERSONAL_OS_CHECK_WORKDIR) { $env:PERSONAL_OS_CHECK_WORKDIR } else { Join-Path $PSScriptRoot '_tmp' }
        $sandbox = Join-Path $scratchRoot 'structure-dirs'
        if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
        $script:dirsTarget = Join-Path $sandbox 'target'
        New-Item -ItemType Directory -Force -Path $script:dirsTarget | Out-Null
        $script:dirsOut = & pwsh -NoProfile -File (Join-Path $repoRoot 'install.ps1') -TargetRoot $script:dirsTarget -ConfigPath $fixture -NonInteractive 2>&1 | Out-String
        $script:dirsCode = $LASTEXITCODE
    }

    It 'the folder install into the sandbox ran (a silent failure would fake the proof)' {
        $script:dirsCode | Should -Be 0 -Because $script:dirsOut
        $script:dirsOut | Should -Match 'INSTALL-OK'
    }

    It 'every dirs: entry of the manifest exists under the sandbox after the install' {
        $manifest = Get-Manifest -Path (Join-Path $repoRoot 'setup\manifest.yaml')
        $expected = New-Object System.Collections.Generic.List[string]
        foreach ($e in @($manifest.components)) {
            if ([string](Get-ManifestField $e 'type') -ne 'dir') { continue }
            foreach ($d in @(Get-ManifestField $e 'dirs')) {
                $expected.Add((Join-Path $script:dirsTarget (([string]$d).Replace('/', '\'))))
            }
        }
        # a silent zero (a broken parse) must not turn this into a free pass
        $expected.Count | Should -BeGreaterThan 15
        $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Container) })
        $missing.Count | Should -Be 0 -Because ('the install did not create: ' + ($missing -join ', '))
    }
}
