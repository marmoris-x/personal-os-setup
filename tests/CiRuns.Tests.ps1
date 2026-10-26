#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.9.1' }
# verify-all check N picks the newest CI run of the checked commit that contains the macOS job, by job
# name and not by start time (setup/lib/ci-runs.ps1). The run lists are recorded shapes of `gh run list`
# and `gh run view --json jobs`; same-second is the 2026-10-26 case: a push run (no macOS job) and a
# manual run (with it) start in the same second, and gh lists the push run first.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'setup/lib/ci-runs.ps1')
    $script:Fix = Join-Path $PSScriptRoot 'fixtures/ci-runs'
    function Read-Fixture([string]$name) { Get-Content -LiteralPath (Join-Path $script:Fix $name) -Raw -Encoding UTF8 | ConvertFrom-Json }
    function Select-From([string]$set) {
        $runs = @(Read-Fixture "$set.runs.json")
        $jobs = Read-Fixture "$set.jobs.json"
        Select-CiRunWithMacOs -Runs $runs -GetJobs { param($id) @($jobs.([string]$id).jobs) }.GetNewClosure()
    }
}

Describe 'Select-CiRunWithMacOs' {
    It 'takes the manual run with the macOS job when a push run without it starts in the same second' {
        $r = Select-From 'same-second'
        $r.Run.databaseId | Should -Be 40296759900
        $r.HasMacOs | Should -BeTrue
        @($r.Jobs | Where-Object { $_.name -like 'macos*' }).Count | Should -Be 1
    }
    It 'takes the manual run even when gh lists the runs the other way round' {
        $runs = @(Read-Fixture 'same-second.runs.json')
        [array]::Reverse($runs)
        $jobs = Read-Fixture 'same-second.jobs.json'
        $r = Select-CiRunWithMacOs -Runs $runs -GetJobs { param($id) @($jobs.([string]$id).jobs) }.GetNewClosure()
        $r.Run.databaseId | Should -Be 40296759900
    }
    It 'falls back to the newest run, flagged without macOS, when no run has the job' {
        $r = Select-From 'push-only'
        $r.Run.databaseId | Should -Be 40226928538
        $r.HasMacOs | Should -BeFalse
        @($r.Jobs).Count | Should -Be 2
    }
    It 'returns nothing for an empty run list' {
        Select-CiRunWithMacOs -Runs @() -GetJobs { throw 'must not be called' } | Should -BeNullOrEmpty
    }
}
