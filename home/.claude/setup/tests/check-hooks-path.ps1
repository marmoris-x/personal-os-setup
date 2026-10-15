function Write-Done([string]$t){ Write-Host "   done: $t" }
if ($true) {
    # A repository-local core.hooksPath silently wins over the global one, so the gitleaks
    # hook never runs in that repository. Three of them had exactly that (found 2026-09-27).
    $overrides = @()
    Get-ChildItem '{{DEV}}\Projects' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dirs = if (Test-Path (Join-Path $_.FullName '.git')) { @($_.FullName) }
                else { @((Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName '.git') }).FullName) }
        foreach ($dir in $dirs) {
            $local = git -C $dir config --local --get core.hooksPath 2>$null
            if ($local) { $overrides += "$dir -> $local" }
        }
    }
    if ($overrides.Count -eq 0) { Write-Done 'no local core.hooksPath overrides under {{DEV}}\Projects' }
    else {
        Write-Host '   These repositories override core.hooksPath locally, so no gitleaks hook runs there:' -ForegroundColor Yellow
        $overrides | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
        Write-Host '      Fix with: git -C <repo> config --local --unset core.hooksPath' -ForegroundColor Yellow
    }
}

