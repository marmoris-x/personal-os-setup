#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.9.1' }
# Tests for the Stop hook hub-reminder.ps1: silent unless the project hub is older than the repo.

BeforeAll {
    . (Join-Path $PSScriptRoot 'LifeOsTestVault.ps1')
    $script:Hook = $env:HUB_REMINDER
    if (-not $script:Hook) { $script:Hook = Join-Path (New-RenderedMirror (Join-Path (Split-Path -Parent $PSScriptRoot) 'home\.claude\hooks\hub-reminder.ps1') (Join-Path ([IO.Path]::GetTempPath()) ('hubrem-src-' + [guid]::NewGuid().ToString('N').Substring(0, 8)))) 'hub-reminder.ps1' }
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('hubrem-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $script:Work | Out-Null

    function Invoke-Hook([string]$stdin, [string]$vault, [string]$dev, [string]$state) {
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:Hook + '" -VaultPath "' + $vault + '" -DevRoot "' + $dev + '" -StateDir "' + $state + '"'
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = [Diagnostics.Process]::Start($psi)
        $p.StandardInput.Write($stdin); $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $sw.Stop()
        return [pscustomobject]@{ Out = $out.Trim(); Code = $p.ExitCode; Ms = $sw.ElapsedMilliseconds }
    }
    function New-Case([string]$name, [string]$hubWritten = '', [switch]$NoHub) {
        $c = Join-Path $script:Work ([guid]::NewGuid().ToString('N').Substring(0, 6))
        $v = New-TestVault (Join-Path $c 'vault')
        $d = Join-Path $c 'Projects'
        $repo = New-TestRepo $d $name
        if (-not $NoHub) { $null = New-Hub $v $name $hubWritten }
        return [pscustomobject]@{ Vault = $v; Dev = $d; Repo = $repo; State = (Join-Path $c 'state'); Name = $name }
    }
    function Get-Stdin([string]$cwd, [string]$session = 's1', [bool]$active = $false) {
        return (ConvertTo-Json @{ session_id = $session; cwd = $cwd; stop_hook_active = $active; hook_event_name = 'Stop' } -Compress)
    }
    function Add-Commit([string]$repo) {
        Write-TestFile (Join-Path $repo ('f' + [guid]::NewGuid().ToString('N').Substring(0, 4) + '.txt')) "x`n"
        & git -C $repo add -A 2>$null | Out-Null
        & git -C $repo -c commit.gpgsign=false commit -q -m 'more' 2>$null | Out-Null
    }
}

AfterAll {
    if ($script:Hook -and $script:Hook -like '*hubrem-src-*') { Remove-Item -LiteralPath (Split-Path -Parent $script:Hook) -Recurse -Force -ErrorAction SilentlyContinue }
    if ($script:Work -and (Test-Path -LiteralPath $script:Work)) { Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'hub-reminder.ps1' {
    It 'is silent outside the projects folder' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $r = Invoke-Hook (Get-Stdin (Join-Path $script:Work 'elsewhere')) $c.Vault $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
        $r.Code | Should -Be 0
    }
    It 'is silent for a repository without a hub' {
        $c = New-Case 'proj' -NoHub
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
        $r.Code | Should -Be 0
    }
    It 'is silent while stop_hook_active is true' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $r = Invoke-Hook (Get-Stdin $c.Repo 's1' $true) $c.Vault $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
    }
    It 'is silent when the hub was written after the newest commit' {
        $c = New-Case 'proj' '2999-01-01T00:00:00'
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
    }
    It 'blocks once when the hub is older than the newest commit' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        $r.Code | Should -Be 0
        $j = $r.Out | ConvertFrom-Json
        $j.decision | Should -Be 'block'
        $j.reason | Should -Match 'proj\.md'
        $j.reason | Should -Match 'hub_written'
    }
    It 'does not block a second time for the same session and commit' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $null = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
    }
    It 'blocks again after a new commit in the same session' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $null = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        Start-Sleep -Milliseconds 1100
        Add-Commit $c.Repo
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        ($r.Out | ConvertFrom-Json).decision | Should -Be 'block'
    }
    It 'blocks in another session for the same commit' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $null = Invoke-Hook (Get-Stdin $c.Repo 'sA') $c.Vault $c.Dev $c.State
        $r = Invoke-Hook (Get-Stdin $c.Repo 'sB') $c.Vault $c.Dev $c.State
        ($r.Out | ConvertFrom-Json).decision | Should -Be 'block'
    }
    It 'blocks when the hub has no hub_written yet' {
        $c = New-Case 'proj' ''
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        ($r.Out | ConvertFrom-Json).decision | Should -Be 'block'
    }
    It 'works from a subfolder of the repository' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $sub = Join-Path $c.Repo 'src\deep'
        New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $r = Invoke-Hook (Get-Stdin $sub) $c.Vault $c.Dev $c.State
        ($r.Out | ConvertFrom-Json).decision | Should -Be 'block'
    }
    It 'blocks when only PROGRESS.md is newer than the hub' {
        $stamp = (Get-Date).AddMinutes(-5).ToString('yyyy-MM-ddTHH:mm:ss')
        $c = New-Case 'proj' $stamp
        # the commit is older than the hub; PROGRESS.md is written afterwards
        $old = (Get-Date).AddHours(-2).ToString('s')
        $env:GIT_COMMITTER_DATE = $old; $env:GIT_AUTHOR_DATE = $old
        & git -C $c.Repo -c commit.gpgsign=false commit -q --amend --no-edit 2>$null | Out-Null
        Remove-Item Env:\GIT_COMMITTER_DATE, Env:\GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
        Write-TestFile (Join-Path $c.Repo 'PROGRESS.md') "# p`n"
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        ($r.Out | ConvertFrom-Json).decision | Should -Be 'block'
    }
    It 'fails open on garbage input' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $r = Invoke-Hook 'this is not json' $c.Vault $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
        $r.Code | Should -Be 0
    }
    It 'fails open when the vault is missing' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $r = Invoke-Hook (Get-Stdin $c.Repo) (Join-Path $script:Work 'no-vault') $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
        $r.Code | Should -Be 0
    }
    It 'is silent for a repository without commits' {
        $c = New-Case 'proj' '2000-01-01T00:00:00'
        $empty = Join-Path $c.Dev 'empty'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        & git -C $empty init -q 2>$null | Out-Null
        $null = New-Hub $c.Vault 'empty' '2000-01-01T00:00:00'
        $r = Invoke-Hook (Get-Stdin $empty) $c.Vault $c.Dev $c.State
        $r.Out | Should -BeNullOrEmpty
    }
    It 'returns in under half a second when nothing is to be said' {
        $c = New-Case 'proj' '2999-01-01T00:00:00'
        $null = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State   # warm the disk cache
        $r = Invoke-Hook (Get-Stdin $c.Repo) $c.Vault $c.Dev $c.State
        $r.Ms | Should -BeLessThan 500
        $r2 = Invoke-Hook (Get-Stdin (Join-Path $script:Work 'elsewhere')) $c.Vault $c.Dev $c.State
        $r2.Ms | Should -BeLessThan 500
    }
}
