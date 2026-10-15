<#
setup/lib/manifest.ps1 - the manifest, and the two naming rules of this repo.

Used by export, install, verify, the docs generator and the tests. Dot-source this file, then:
  $m = Get-Manifest -Path <manifest.yaml>
  $errors = @(Test-ManifestSchema -Manifest $m -RepoRoot <repo>)
An empty error list means the manifest is valid.

NAMING RULES - the only place they are written down (see docs/structure.md, ADR 0014):

1. Where a target lives inside this repo. Manifest targets start with a root token:
     HOME/       -> home/            installs to %USERPROFILE%
     DOCUMENTS/  -> home/Documents/  installs to the Windows Documents folder
     VAULT/      -> vault/           installs to the vault path
     DEV/        -> dev/             installs to the dev root

2. How a target file is STORED in the repo. A dotted name that git itself would
   interpret inside this repo is stored without the dot and installed with it
   (.gitignore, .gitattributes, .gitleaksignore, .kopiaignore, .stignore).
   Hidden FOLDERS keep their dot: git does not interpret them.
   `store_as:` is the exception for a starter template, which is stored with a
   trailing .tmpl and installed without it.

Keep this file ASCII-only: Windows PowerShell 5.1 reads a BOM-less file in the
ANSI code page, and a stray umlaut can break the parser.
#>

$script:RepoRootForTarget = [ordered]@{
    'HOME'      = 'home'
    'DOCUMENTS' = 'home/Documents'
    'VAULT'     = 'vault'
    'DEV'       = 'dev'
}

# Rule 2, first half: stored without the dot because git would interpret the dotted name
# anywhere below the repo root.
$script:DotStoredNames = @('.gitignore', '.gitattributes', '.gitleaksignore', '.kopiaignore', '.stignore')

function Get-RepoRootMap {
    # the target token -> repo folder table, for callers that need to walk every mirror
    [CmdletBinding()]
    param()
    return $script:RepoRootForTarget
}

function Get-RepoRelPath {
    # "VAULT/000-meta/backup.md" -> "vault/000-meta/backup.md"
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target)
    $p = $Target -replace '\\', '/'
    while ($p.StartsWith('/')) { $p = $p.Substring(1) }
    $parts = $p -split '/', 2
    $root = [string]$parts[0]
    if (-not $script:RepoRootForTarget.Contains($root)) {
        throw ("target does not start with a known root token (HOME DOCUMENTS VAULT DEV): " + $Target)
    }
    if ($parts.Count -gt 1 -and $parts[1]) { return ($script:RepoRootForTarget[$root] + '/' + $parts[1]) }
    return $script:RepoRootForTarget[$root]
}

function Get-StoredLeaf {
    # ".gitignore" -> "gitignore"; anything else unchanged
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Leaf)
    if ($script:DotStoredNames -contains $Leaf) { return $Leaf.Substring(1) }
    return $Leaf
}

function Get-RepoFileRel {
    # the repo-relative path that holds the content for one manifest target
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Target,
        [string]$StoreAs
    )
    $rel = Get-RepoRelPath $Target
    $idx = $rel.LastIndexOf('/')
    $dir = if ($idx -lt 0) { '' } else { $rel.Substring(0, $idx + 1) }
    $leaf = if ($idx -lt 0) { $rel } else { $rel.Substring($idx + 1) }
    if ($StoreAs) { return ($dir + $StoreAs) }
    return ($dir + (Get-StoredLeaf $leaf))
}

function Get-MirrorFolder {
    # One row per mirror folder in the repo and the target root it installs to.
    # DOCUMENTS lives INSIDE home/ (the Windows Documents folder sits under the profile),
    # so the HOME row must not walk into Documents/ - otherwise every file there would be
    # rendered twice, once under HOME/ and once under DOCUMENTS/.
    [CmdletBinding()]
    param()
    return @(
        [pscustomobject]@{ Target = 'HOME'; RepoRel = 'home'; Skip = @('Documents') }
        [pscustomobject]@{ Target = 'DOCUMENTS'; RepoRel = 'home/Documents'; Skip = @() }
        [pscustomobject]@{ Target = 'VAULT'; RepoRel = 'vault'; Skip = @() }
        [pscustomobject]@{ Target = 'DEV'; RepoRel = 'dev'; Skip = @() }
    )
}

function Get-Manifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Import-Module powershell-yaml -ErrorAction Stop
    $data = ConvertFrom-Yaml (Get-Content -LiteralPath $Path -Raw)
    if (-not $data) { throw "manifest not readable: $Path" }
    return $data
}

function Get-ManifestField {
    # works for Hashtable (powershell-yaml) and PSCustomObject alike
    [CmdletBinding()]
    param($Entry, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Entry) { return $null }
    if ($Entry -is [System.Collections.IDictionary]) {
        if ($Entry.Contains($Name)) { return $Entry[$Name] }
        return $null
    }
    foreach ($p in $Entry.PSObject.Properties) { if ($p.Name -eq $Name) { return $p.Value } }
    return $null
}

function Test-RepoContentPresent {
    # Every component that installs content must find that content in the repo.
    # Measured 2026-10-14: `pwsh-profile-unix` promised HOME/.config/powershell/profile.ps1
    # and no such file was ever written. On the two systems that use it install.ps1 reported
    # `repo file missing` as a stage ERROR; on Windows nobody noticed, because the component is
    # `unsupported` there and the file stage skips it before it looks. A manifest that promises
    # content nobody wrote is a hole in the kit, not an operating system's problem - so the
    # answer here does not depend on the system this runs on.
    # Returns an error text or an empty string.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        $Entry,
        [Parameter(Mandatory)][string]$Target
    )
    $rel = Get-RepoFileRel -Target $Target -StoreAs ([string](Get-ManifestField $Entry 'store_as'))
    $full = Join-Path $RepoRoot $rel
    if ((Get-ManifestField $Entry 'recursive')) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { return ('the folder it promises is missing in the repo (' + $rel + ')') }
        return ''
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return ('the file it promises is missing in the repo (' + $rel + ')') }
    return ''
}

function Test-ManifestSchema {
    # returns the list of error strings; an empty list means the manifest is valid
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$RepoRoot
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $allowedAreas = @('claude', 'vault', 'life-os', 'research', 'backup', 'guards', 'powershell', 'windows', 'dev', 'git')
    $allowedTypes = @('copy', 'template', 'dir', 'generated', 'winget', 'task', 'mcp', 'obsidian-plugin', 'doc-only')

    if (-not (Get-ManifestField $Manifest 'version')) { $errors.Add('missing top-level field: version') }
    $components = @(Get-ManifestField $Manifest 'components')
    if ($components.Count -eq 0 -or $null -eq $components[0]) {
        $errors.Add('missing top-level field: components')
        return $errors
    }

    $seen = @{}
    foreach ($e in $components) {
        $id = [string](Get-ManifestField $e 'id')
        if (-not $id) { $errors.Add('entry without id'); continue }
        if ($id -notmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $errors.Add("$id : id must be lowercase words joined by hyphens") }
        if ($seen.ContainsKey($id)) { $errors.Add("$id : duplicate id") }
        $seen[$id] = $true

        $area = [string](Get-ManifestField $e 'area')
        if ($area -notin $allowedAreas) { $errors.Add("$id : unknown area '$area'") }
        $type = [string](Get-ManifestField $e 'type')
        if ($type -notin $allowedTypes) { $errors.Add("$id : unknown type '$type'") }
        $core = Get-ManifestField $e 'core'
        if ($core -isnot [bool]) { $errors.Add("$id : core must be true or false") }

        $target = [string](Get-ManifestField $e 'target')
        switch ($type) {
            'copy' {
                $src = [string](Get-ManifestField $e 'source')
                if (-not $src) { $errors.Add("$id : copy needs a source") }
                elseif ($src -notmatch '^\{(HOME|DOCUMENTS|VAULT|DEV)\}[\\/]') { $errors.Add("$id : source must start with a root token ({HOME} {DOCUMENTS} {VAULT} {DEV})") }
                if ($target -notmatch '^(HOME|DOCUMENTS|VAULT|DEV)/') { $errors.Add("$id : target must start with HOME/ DOCUMENTS/ VAULT/ or DEV/") }
                else {
                    $err = Test-RepoContentPresent -RepoRoot $RepoRoot -Entry $e -Target $target
                    if ($err) { $errors.Add($id + ' : ' + $err) }
                }
            }
            'template' {
                $src = [string](Get-ManifestField $e 'source')
                if (-not $src) { $errors.Add("$id : template needs a source") }
                elseif ($src -notmatch '^\{(HOME|DOCUMENTS|VAULT|DEV)\}[\\/]') { $errors.Add("$id : source must start with a root token ({HOME} {DOCUMENTS} {VAULT} {DEV})") }
                if ($target -notmatch '^(HOME|DOCUMENTS|VAULT|DEV)/') { $errors.Add("$id : target must start with HOME/ DOCUMENTS/ VAULT/ or DEV/") }
                else {
                    $err = Test-RepoContentPresent -RepoRoot $RepoRoot -Entry $e -Target $target
                    if ($err) { $errors.Add($id + ' : ' + $err) }
                }
            }
            'doc-only' {
                if ($target -notmatch '^(HOME|DOCUMENTS|VAULT|DEV)/') { $errors.Add("$id : target must start with HOME/ DOCUMENTS/ VAULT/ or DEV/") }
                else {
                    $err = Test-RepoContentPresent -RepoRoot $RepoRoot -Entry $e -Target $target
                    if ($err) { $errors.Add($id + ' : ' + $err) }
                }
            }
            'dir' {
                $dirs = @(Get-ManifestField $e 'dirs')
                if ($dirs.Count -eq 0 -or $null -eq $dirs[0]) { $errors.Add("$id : dir needs a dirs list") }
                else {
                    foreach ($d in $dirs) {
                        # the root token alone is allowed: "DEV" creates the dev root itself
                        # (2.1.2, dev-dirs); "DEV/Projects" a folder below it. The two rules
                        # after it close what the loosened first one would let through: a ".."
                        # segment and an embedded line break (a trailing \n passes the $ of
                        # .NET regex; measured in review 16 on the staged version).
                        $ds = [string]$d
                        if ($ds -notmatch '^(HOME|DOCUMENTS|VAULT|DEV)(/|$)') { $errors.Add("$id : dir '$ds' must start with HOME/ DOCUMENTS/ VAULT/ or DEV/ (or be the root token alone)") }
                        elseif ($ds -match '(^|/)\.\.(/|$)') { $errors.Add("$id : dir '$ds' must not contain a '..' segment") }
                        elseif ($ds -match '[\r\n]') { $errors.Add("$id : dir '$ds' must not contain a line break") }
                    }
                }
            }
            'winget' {
                $f = [string](Get-ManifestField $e 'file')
                if (-not $f) { $errors.Add("$id : winget needs a file") }
                elseif ($f -notmatch '\.(winget|json)$') { $errors.Add("$id : winget file must end in .winget or .json") }
                elseif (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $f))) { $errors.Add("$id : winget file not found in the repo") }
            }
            'task' {
                $f = [string](Get-ManifestField $e 'file')
                if (-not $f) { $errors.Add("$id : task needs a file") }
                elseif (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $f))) { $errors.Add("$id : task file not found in the repo") }
                if (-not (Get-ManifestField $e 'name')) { $errors.Add("$id : task needs a name") }
            }
            'mcp' {
                if (-not (Get-ManifestField $e 'name')) { $errors.Add("$id : mcp needs a name") }
                $json = [string](Get-ManifestField $e 'json')
                if (-not $json) { $errors.Add("$id : mcp needs a json field") }
                else {
                    try { $null = ConvertFrom-Json $json } catch { $errors.Add("$id : mcp json does not parse") }
                }
            }
            'obsidian-plugin' {
                foreach ($field in @('name', 'repo', 'version')) {
                    if (-not (Get-ManifestField $e $field)) { $errors.Add("$id : obsidian-plugin needs $field") }
                }
            }
            'generated' {
                if (-not (Get-ManifestField $e 'note')) { $errors.Add("$id : generated needs a note") }
            }
        }
    }
    return $errors
}
