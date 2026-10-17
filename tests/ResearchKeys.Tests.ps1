# The cross-platform key persistence: functions of set-research-keys.ps1, no prompt, no machine
# state. Windows keeps its user environment variables; the Unix path is a 0600 env file plus a
# guarded source block in the profiles.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\home\.claude\setup\powershell\set-research-keys.ps1')
    $script:tmp = Join-Path ([IO.Path]::GetTempPath()) ('keys-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:tmp | Out-Null
}
AfterAll {
    if (Test-Path -LiteralPath $script:tmp) { Remove-Item -LiteralPath $script:tmp -Recurse -Force }
}

Describe 'the Unix key file' {
    It 'writes every known key as an export line and reads it back' {
        $path = Join-Path $script:tmp 'keys.env'
        Write-ResearchKeyEnvFile -Path $path -Values @{ EXA_API_KEY = 'dummy-exa'; TAVILY_API_KEY = 'dummy-tavily' }
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match "export EXA_API_KEY='dummy-exa'"
        $text | Should -Match "export TAVILY_API_KEY='dummy-tavily'"
        $text | Should -Not -Match 'dummy-exa.*dummy-exa' -Because 'each key is written once'
        $back = Read-ResearchKeyEnvFile -Path $path
        $back['EXA_API_KEY'] | Should -Be 'dummy-exa'
        $back['TAVILY_API_KEY'] | Should -Be 'dummy-tavily'
    }

    It 'escapes a single quote so the shell file stays valid' {
        $path = Join-Path $script:tmp 'quote.env'
        Write-ResearchKeyEnvFile -Path $path -Values @{ EXA_API_KEY = "a'b" }
        [IO.File]::ReadAllText($path) | Should -Match "export EXA_API_KEY='a'\\''b'"
        (Read-ResearchKeyEnvFile -Path $path)['EXA_API_KEY'] | Should -Be "a'b"
    }

    It 'writes the Unix file with mode 600' -Skip:(-not ($IsLinux -or $IsMacOS)) {
        $path = Join-Path $script:tmp 'mode.env'
        Write-ResearchKeyEnvFile -Path $path -Values @{ EXA_API_KEY = 'dummy' }
        $mode = [IO.File]::GetUnixFileMode($path)
        ($mode -band [IO.UnixFileMode]::UserRead) | Should -Be ([IO.UnixFileMode]::UserRead)
        ($mode -band [IO.UnixFileMode]::GroupRead) | Should -Be 0
        ($mode -band [IO.UnixFileMode]::OtherRead) | Should -Be 0
    }

    It 'does not write a key that does not belong to the service list' {
        $path = Join-Path $script:tmp 'unknown.env'
        Write-ResearchKeyEnvFile -Path $path -Values @{ NOT_A_SERVICE = 'x'; EXA_API_KEY = 'y' }
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Not -Match 'NOT_A_SERVICE'
        $text | Should -Match 'EXA_API_KEY'
    }
}

Describe 'the profile source line' {
    It 'adds the guarded source block once and never the key itself' {
        $profile = Join-Path $script:tmp '.profile'
        Add-ResearchKeyProfileSource -ProfilePath $profile | Should -BeTrue
        Add-ResearchKeyProfileSource -ProfilePath $profile | Should -BeFalse
        $text = [IO.File]::ReadAllText($profile)
        ([regex]::Matches($text, 'personal-os-setup: research keys')).Count | Should -Be 1
        $text | Should -Match 'research-keys\.env'
        $text | Should -Not -Match 'dummy'
    }

    It 'always includes .profile, .bashrc only when it exists, .zshrc when zsh is the shell' {
        $homeDir = Join-Path $script:tmp 'home-paths'
        New-Item -ItemType Directory -Force -Path $homeDir | Out-Null
        $plain = @(Get-ResearchKeyProfilePaths -HomeDir $homeDir -Shell '/bin/bash')
        ($plain -join ',') | Should -Not -Match '\.zshrc'
        New-Item -ItemType File -Path (Join-Path $homeDir '.bashrc') | Out-Null
        $withBash = @(Get-ResearchKeyProfilePaths -HomeDir $homeDir -Shell '/bin/bash')
        ($withBash -join ',') | Should -Match '\.bashrc'
        $withZsh = @(Get-ResearchKeyProfilePaths -HomeDir $homeDir -Shell '/bin/zsh')
        ($withZsh -join ',') | Should -Match '\.zshrc'
    }
}
