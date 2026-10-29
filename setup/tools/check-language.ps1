<#
setup/tools/check-language.ps1 - is every file in this repo in English?

The rule (task "folder-structure", section 3): docs, READMEs, comments, commit messages and
file or folder names are English. The one thing that stays German is *data the owner speaks or
his own system stores*: a folder name inside his vault, a heading his morning routine writes,
the phrases that trigger a skill, and German sample text inside the research tooling. Those are
listed below, one line per file, each with its reason - nothing is excused silently.

  pwsh setup/tools/check-language.ps1            # report; exit 0 when clean, 1 on findings

Scope: every file git tracks (the worktree copy, so comments count). Untracked scratch is not
part of the repo and is ignored.
Not ASCII-only, unlike the other tools: it has to carry the umlauts and the one German file
name it searches for. Everything else in it is ASCII.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }

# --- German words ---------------------------------------------------------------------------
# Chosen so that they do NOT appear in ordinary English text: no "die", "die" is ambiguous with
# the English verb, no "war"/"hat"/"in"/"an"/"so", no "man". An umlaut counts on its own.
$germanWords = @(
    'und', 'oder', 'aber', 'nicht', 'kein', 'keine', 'keinen', 'einen', 'einem', 'eines', 'einer',
    'sind', 'wird', 'werden', 'wurde', 'wurden', 'haben', 'hatte', 'kann', 'koennen', 'kannst',
    'muss', 'muessen', 'soll', 'sollen', 'darf', 'fuer', 'ueber', 'durch', 'gegen', 'ohne',
    'nachdem', 'noch', 'nur', 'auch', 'schon', 'sehr', 'mehr', 'wenn', 'dann', 'dass', 'sich',
    'diese', 'dieser', 'dieses', 'diesem', 'diesen', 'beim', 'vom', 'zum', 'zur', 'ausser',
    'bei', 'sein', 'seine', 'seinem', 'ihrem', 'ihren', 'ihre', 'ihres', 'denn', 'weil',
    'damit', 'sowie', 'sowohl', 'etwa', 'jedoch', 'bereits', 'immer', 'wieder', 'nichts',
    'etwas', 'alles', 'viele', 'vielen', 'dort', 'oben', 'unten', 'heute', 'gestern', 'jetzt',
    'zwischen', 'unter', 'waehrend', 'moeglich', 'jede', 'jeden', 'jeder', 'zusaetzlich',
    # words this repo used itself
    'aufraeumen', 'auftraege', 'auftrag', 'lebensprotokoll', 'morgenbericht', 'erledigt',
    'bestandteile', 'waechter', 'dokumentenarchiv', 'sprachaufnahme', 'aufgaben', 'protokoll',
    'zusammengefuehrt', 'pruefung', 'pruefungen', 'uebersprungen', 'uebersetzung', 'aenderung',
    'schluessel', 'sicherung', 'ordner', 'datei', 'hinweis', 'warnung', 'erfolg', 'abbruch',
    'ansicht', 'einstellungen', 'deaktivieren', 'zurueck', 'loeschen', 'speichern', 'oeffnen'
)

# --- phrases that may appear anywhere, each with a reason --------------------------------------
# These are not prose: they are values of the owner's own system (a folder name from his
# personal.yaml, a folder inside his vault, his real document names) or a sentence a guard has
# to say to him in German. Matches inside one of them do not count.
$toleratedPhrases = @(
    @{ text = 'inbox/audio/erledigt';                           reason = 'a folder inside the owner vault (his word for done)' },
    @{ text = 'Dokumentenarchiv';                               reason = 'the owner archive folder name, from his personal.yaml' },
    @{ text = 'auftraege';                                      reason = 'a folder inside the owner vault (his tasks folder): a scanner that must exclude it has to spell the name' },
    @{ text = 'Fuer das andere bitte eine neue Sitzung starten'; reason = 'the sentence the session guard relays to the owner' },
    @{ text = 'noch nicht';                                     reason = 'a German phrase the research standard looks for in German texts' },
    @{ text = '2026_Maerz';                                     reason = 'the owner real document file name' },
    @{ text = '2026_März';                                      reason = 'the owner real document file name' },
    @{ text = 'Pruefung\notes.txt';                             reason = 'the ASCII twin of the umlaut path one line above it in the delete-guard suite: the twin is what shows the umlaut case is not passed by accident, so the spelling has to stay' },
    @{ text = 'chore: Buecher und Notizen umsortiert';          reason = 'an invented commit message in the downloads-guard suite: the case pins that German words inside a MESSAGE are not a git switch, and the words must be spelled out for the case to say that' }
)

# --- paths and files that are exempt, each with a reason --------------------------------------
# Match rules run on the repo-relative path with forward slashes.
$exemptRules = @(
    @{ pattern = '^tests/fixtures/.*';                                     reason = 'test fixture: deliberate sample content' },
    @{ pattern = '^home/\.claude/setup/tests/research/.*\.py$';             reason = 'test fixtures with German sample text for the research scripts' },
    @{ pattern = '^vault/inbox/audio/erledigt/.*';                          reason = 'a folder name inside the owner vault (his word); renaming it would restructure his vault' },
    @{ pattern = '^home/\.claude/skills/research/scripts/(ai_patterns|check_note)\.py$'; reason = 'German AI-writing patterns: the data the detector matches on' },
    @{ pattern = '^home/\.claude/skills/research/references/style-rules\.md$'; reason = 'style rules for the owner German research texts' },
    @{ pattern = '^home/\.claude/skills/research/scripts/.*\.py$';          reason = 'research tooling with German pattern data' },
    @{ pattern = '^home/\.claude/(skills/[^/]+/SKILL|agents/[^/]+)\.md$';   reason = 'quoted phrases the owner speaks - they trigger the skill' },
    @{ pattern = '^home/\.claude/CLAUDE\.md$';                              reason = 'quoted trigger phrases the owner speaks (sehr gruendlich, ausfuehrlich)' },
    @{ pattern = '^home/\.claude/setup/other-harnesses/.*SKILL\.md$';       reason = 'quoted phrases the owner speaks (portable skill copies)' },
    @{ pattern = '^home/\.agents/skills/.*SKILL\.md$';                      reason = 'portable skill copies quote the owner German trigger phrases and report lines' },
    @{ pattern = '^home/\.claude/life-os/project-tracker\.ps1$';            reason = 'writes the owner German project activity and morning report lines' },
    @{ pattern = '^home/\.claude/skills/image/scripts/new-image\.ps1$';    reason = 'prints the German messages the owner reads (graphics memory full, template check, no answer)' },
    @{ pattern = '^home/\.claude/skills/image/scripts/restore-models\.ps1$'; reason = 'prints the German messages the owner reads (missing file, wrong size or hash, free-space refusal, failed download)' },
    @{ pattern = '^home/\.claude/skills/video/scripts/new-video\.ps1$';    reason = 'prints the German messages the owner reads (RAM guard with the programs to close, GPU holder, graphics memory full, template check, no answer)' },
    @{ pattern = '^home/\.claude/hooks/deepseek-orientation\.ps1$';        reason = 'prints the German warning the owner reads when the orientation file does not fit' },
    @{ pattern = '^docs/media-projects\.md$';                              reason = 'quotes the German morning report line the owner reads' },
    @{ pattern = '^vault/\.claude/skills/[^/]+/SKILL\.md$';                 reason = 'quoted phrases the owner speaks' },
    @{ pattern = '^vault/(AGENTS|CLAUDE)\.md$';                             reason = 'the owner vault: names his own notes and note types' },
    @{ pattern = '^vault/000-meta/templates/.*';                            reason = 'vault templates with the owner German headings' },
    @{ pattern = '^home/\.claude/life-os/(cleanup|transcribe|life-os-common|morning|morning-checks|area-check)\.ps1$'; reason = 'operates on German folder and heading names inside the owner vault, and writes the German Morgenbericht lines' },
    @{ pattern = '^tests/LifeOs[A-Za-z]*\.(Tests\.)?ps1$';                  reason = 'test fixtures with the German vault headings and Morgenbericht lines the Life OS scripts work on' },
    @{ pattern = '^home/\.claude/life-os/register-tasks.*\.ps1$';           reason = 'registers the owner scheduled task' },
    @{ pattern = '^docs/phone-setup\.md$';                                  reason = 'quotes the label a German phone really shows' },
    @{ pattern = '^setup/tools/old-paths\.txt$';                            reason = 'the pattern list that check C of verify-all searches for: it has to name the old German file names' },
    @{ pattern = '^setup/tools/check-language\.ps1$';                       reason = 'it holds the German word list that this check searches for' },
    @{ pattern = '^CHANGELOG\.md$';                                         reason = 'a record of what was true at the time: it names the old German file names that were renamed away (check C excludes it for the same reason)' },
    @{ pattern = '^vault/gitignore$';                                       reason = 'lists the owner vault working folders by name' },
    @{ pattern = '^vault/\.stignore$';                                      reason = 'same, for the sync tool' }
)

function Test-Exempt([string]$rel) {
    foreach ($r in $exemptRules) { if ($rel -match $r.pattern) { return $true } }
    return $false
}
function Get-ExemptReason([string]$rel) {
    foreach ($r in $exemptRules) { if ($rel -match $r.pattern) { return $r.reason } }
    return ''
}

Push-Location $RepoRoot
try { $tracked = @(& git ls-files | Where-Object { $_ } | Sort-Object) }
finally { Pop-Location }
if ($tracked.Count -eq 0) { Write-Host 'LANGUAGE: git ls-files returned nothing' -ForegroundColor Red; exit 1 }

$binaryExt = @('.png', '.jpg', '.jpeg', '.gif', '.ico', '.pdf', '.zip', '.exe', '.dll', '.pyc', '.woff', '.woff2')
$wordRx = [regex]('(?i)(?<![\w-])(' + (($germanWords | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')(?![\w-])')
$umlautRx = '[äöüÄÖÜß]'

$pathHits = New-Object System.Collections.Generic.List[string]
$lineHits = New-Object System.Collections.Generic.List[string]
$tolerated = New-Object System.Collections.Generic.List[string]
$phraseUsed = @{}

function Get-RealHitCount([string]$line, $rx) {
    # counts the matches that do NOT sit inside a tolerated phrase.
    # Returns a plain int: a returned array (even an empty one) is easy to misread in
    # PowerShell, and a wrong count here would either hide a finding or invent one.
    $spans = New-Object System.Collections.Generic.List[object]
    foreach ($p in $toleratedPhrases) {
        $i = $line.IndexOf($p.text, [StringComparison]::OrdinalIgnoreCase)
        while ($i -ge 0) {
            # parentheses are load-bearing: the comma binds tighter than +, so
            # @($i, $i + $len) would build ($i, $i) and then append the length
            $spans.Add(@($i, ($i + $p.text.Length)))
            $script:phraseUsed[$p.text] = $true
            $i = $line.IndexOf($p.text, $i + 1, [StringComparison]::OrdinalIgnoreCase)
        }
    }
    $n = 0
    foreach ($m in $rx.Matches($line)) {
        $inside = $false
        foreach ($s in $spans) { if (($m.Index -ge $s[0]) -and (($m.Index + $m.Length) -le $s[1])) { $inside = $true; break } }
        if (-not $inside) { $n++ }
    }
    return $n
}

foreach ($rel in $tracked) {
    # 1. the NAME of the file or one of its folders
    $nameHit = $false
    foreach ($seg in ($rel -split '/')) {
        if ($seg -match $umlautRx) { $nameHit = $true }
        elseif ((Get-RealHitCount $seg $wordRx) -gt 0) { $nameHit = $true }
    }
    if ($nameHit) {
        if (Test-Exempt $rel) { $tolerated.Add('path  ' + $rel + '   [' + (Get-ExemptReason $rel) + ']') }
        else { $pathHits.Add($rel) }
        continue
    }

    # 2. the CONTENT
    $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($binaryExt -contains $ext) { continue }
    $full = Join-Path $RepoRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $text = ''
    try { $text = [IO.File]::ReadAllText($full) } catch { continue }
    $isExempt = Test-Exempt $rel
    $found = 0
    foreach ($line in ($text -split "`r?`n")) {
        if ((Get-RealHitCount $line $wordRx) -gt 0) { $found++ }
        elseif ($line -match $umlautRx) {
            # an umlaut outside a tolerated phrase: only report it when the line is not one of them
            $bare = $line
            foreach ($p in $toleratedPhrases) { $bare = $bare.Replace($p.text, '', [StringComparison]::OrdinalIgnoreCase) }
            if ($bare -match $umlautRx) { $found++ }
        }
    }
    if ($found -eq 0) { continue }
    if ($isExempt) { $tolerated.Add('lines ' + $found.ToString().PadLeft(4) + ' ' + $rel + '   [' + (Get-ExemptReason $rel) + ']') }
    else { $lineHits.Add($found.ToString().PadLeft(4) + '  ' + $rel) }
}
Pop-Location

Write-Host ('LANGUAGE: ' + $tracked.Count + ' tracked file(s) scanned')
Write-Host 'LANGUAGE scope: a fixed German word list, common German function words and umlauts. That finds German prose, not every German sentence - a sentence built only from words outside the list is missed. The check is a net, not a proof.'
if ($tolerated.Count -gt 0) {
    Write-Host ('  tolerated (each with a written reason): ' + $tolerated.Count + ' file(s)')
    foreach ($t in $tolerated) { Write-Host ('    ' + $t) -ForegroundColor DarkGray }
}
if ($pathHits.Count -eq 0 -and $lineHits.Count -eq 0) {
    Write-Host 'LANGUAGE-OK: no German outside the tolerated files' -ForegroundColor Green
    exit 0
}
foreach ($p in $pathHits) { Write-Host ('  German in a file or folder NAME: ' + $p) -ForegroundColor Red }
foreach ($h in $lineHits) { Write-Host ('  German lines: ' + $h) -ForegroundColor Red }
Write-Host ('LANGUAGE: ' + ($pathHits.Count + $lineHits.Count) + ' finding(s) - translate them, or add the file to $exemptRules with a written reason') -ForegroundColor Red
exit 1
