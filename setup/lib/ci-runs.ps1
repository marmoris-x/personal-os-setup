<#
setup/lib/ci-runs.ps1 - which CI run verify-all check N judges.

Source of the job names: gh run view <id> --json jobs on the runs of 2026-10-26 (the macOS job
is named "macos"; the full-setup job of the same system is "full-setup (macos-latest)").

ASCII-only on purpose (Windows PowerShell 5.1 reads a BOM-less file in the ANSI code page).
#>

function Select-CiRunWithMacOs {
    # $Runs: the objects of `gh run list --json databaseId,...` for ONE commit.
    # $GetJobs: scriptblock, takes a databaseId and returns that run's job objects (name, conclusion).
    param([object[]]$Runs, [scriptblock]$GetJobs)
    # Newest first by databaseId: ids only grow, while two runs that start in the same second have
    # the same time and gh lists them in no promised order. The job name decides, not the clock.
    $ordered = @($Runs | Where-Object { $_ } | Sort-Object { [int64]$_.databaseId } -Descending)
    if ($ordered.Count -eq 0) { return $null }
    $newest = $null
    foreach ($run in $ordered) {
        $jobs = @(& $GetJobs $run.databaseId)
        if (-not $newest) { $newest = [pscustomobject]@{ Run = $run; Jobs = $jobs; HasMacOs = $false } }
        if (@($jobs | Where-Object { $_.name -like 'macos*' }).Count -gt 0) {
            return [pscustomobject]@{ Run = $run; Jobs = $jobs; HasMacOs = $true }
        }
    }
    # no run of this commit has the macOS job: the newest one is judged, and says so
    return $newest
}
