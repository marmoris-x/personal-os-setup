# Pester 5.9.1 (pinned - see docs/decisions/0010-test-strategy.md).
# Validates setup/manifest.yaml against setup/lib/manifest.ps1: the repo manifest must be
# clean, and the deliberately broken fixture must be rejected.
# Setup goes in BeforeAll: top-level code here would only run during discovery (Pester 5).
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $repoRoot 'setup\lib\manifest.ps1')
}

Describe 'manifest schema validation' {
    It 'accepts the repo manifest without errors' {
        $manifest = Get-Manifest -Path (Join-Path $repoRoot 'setup\manifest.yaml')
        $errors = @(Test-ManifestSchema -Manifest $manifest -RepoRoot $repoRoot)
        $errors.Count | Should -Be 0 -Because ($errors -join '; ')
    }

    It 'rejects every seeded error in the broken fixture' {
        $manifest = Get-Manifest -Path (Join-Path $PSScriptRoot 'fixtures\manifest-broken.yaml')
        $errors = @(Test-ManifestSchema -Manifest $manifest -RepoRoot $repoRoot)
        $errors.Count | Should -BeGreaterOrEqual 7 -Because ($errors -join '; ')
        $joined = $errors -join '; '
        $joined | Should -Match 'duplicate id'
        $joined | Should -Match 'unknown area'
        $joined | Should -Match 'unknown type'
        $joined | Should -Match 'source must'
        $joined | Should -Match 'target must'
        $joined | Should -Match "dir 'XX/example' must start with"
        $joined | Should -Match "dir 'DEV/\.\./Windows' must not contain a '\.\.' segment"
        $joined | Should -Match "must not contain a line break"
        $joined | Should -Match 'core must'
        $joined | Should -Match 'mcp json does not parse'
        $joined | Should -Match 'winget file not found'
        # a component that installs content nobody wrote (measured: pwsh-profile-unix)
        $joined | Should -Match 'example-content-missing : the file it promises is missing in the repo'
    }

    # The old rule "every dir-component path is visible in git (carries at least one file)"
    # ended with 2.1.2: the .gitkeep markers left the repo, and the manifest alone defines the
    # folders. The proof lives in tests/Structure.Tests.ps1 now - it installs the folder
    # components into a test sandbox and asserts every dirs: entry exists there.
}
