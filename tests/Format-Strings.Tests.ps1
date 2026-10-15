# Pester 5.9.1 (pinned - see docs/decisions/0010-test-strategy.md).
# Every "-f" format string in the repo has to be a valid .NET composite format string - the
# template of a literal or an expandable string, of the parenthesised form of either, or of a
# variable that a plain assignment in the same file gave a string. A template built at runtime
# (concatenated, read from a file) cannot be checked here; that is the stated limit of this test.
# Reason (review-2, finding 1): setup/tools/verify-all.ps1 carried '{0,>2}', which is not valid
# alignment syntax - the acceptance script threw "Input string was not in a correct format" on
# its first check line and never ran at all, through two commits and a green CI, because nothing
# ever parsed its format strings. '>' is not a digit: alignment is '{0,2}' or '{0,-2}'.
# Setup goes in BeforeAll: top-level code here would only run during discovery (Pester 5).
BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $scriptFiles = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.ps1' |
        Where-Object { $_.FullName -notmatch '\\\.git\\|\\node_modules\\|\\venv\\|\\__pycache__\\' })

    # Resolves an expression to what it really is: unwraps `( ... )` and the CommandExpressionAst
    # PowerShell puts around a simple value. `($fmt) -f 'x'` is a ParenExpressionAst holding a
    # pipeline holding the variable (review 5 measured that this shape was invisible).
    function Resolve-Expression($expr) {
        while ($true) {
            if ($expr -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $inner = $null
                if (($expr.Pipeline -is [System.Management.Automation.Language.PipelineAst]) -and ($expr.Pipeline.PipelineElements.Count -eq 1)) {
                    $inner = $expr.Pipeline.PipelineElements[0]
                }
                if (-not $inner) { return $null }
                $expr = $inner
                continue
            }
            if ($expr -is [System.Management.Automation.Language.CommandExpressionAst]) { $expr = $expr.Expression; continue }
            return $expr
        }
    }

    # Every string template used as the left side of -f, with the file it stands in. Four shapes
    # are read: a literal, an expandable string, a parenthesised form of either, and a variable
    # that a plain assignment in the same file gave a string - `$fmt = '{0,>2}'; $fmt -f 'x'` was
    # the shape both review 3 and review 4 used to show a hole here. A template that only exists at
    # runtime (built by concatenation, read from a file) stays out of reach; the header says so.
    function Get-FormatTemplates {
        $found = New-Object System.Collections.Generic.List[object]
        foreach ($f in $scriptFiles) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            # the last plain string assignment per variable name wins (an approximation, and a
            # deliberate one: the alternative is not reading the assignment at all)
            $assigned = @{}
            foreach ($a in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
                if ($a.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
                $right = Resolve-Expression $a.Right
                if ($null -eq $right) { continue }
                $isString = ($right -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
                            ($right -is [System.Management.Automation.Language.ExpandableStringExpressionAst])
                if (-not $isString) { continue }
                $assigned[$a.Left.VariablePath.UserPath] = [pscustomobject]@{ Line = $right.Extent.StartLineNumber; Template = $right.Value }
            }
            $ops = $ast.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) -and ($node.Operator -eq 'Format')
                }, $true)
            foreach ($op in $ops) {
                $left = Resolve-Expression $op.Left
                if ($null -eq $left) { continue }
                $isString = ($left -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
                            ($left -is [System.Management.Automation.Language.ExpandableStringExpressionAst])
                if ($isString) {
                    $found.Add([pscustomobject]@{ File = $f.FullName; Line = $left.Extent.StartLineNumber; Template = $left.Value })
                }
                elseif ($left -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    $name = $left.VariablePath.UserPath
                    if ($assigned.ContainsKey($name)) {
                        $found.Add([pscustomobject]@{ File = $f.FullName; Line = $assigned[$name].Line; Template = $assigned[$name].Template })
                    }
                }
            }
        }
        return $found
    }
}

Describe '-f format strings' {
    It 'parses every composite format string in the repository' {
        $templates = Get-FormatTemplates
        $templates.Count | Should -BeGreaterThan 0 -Because 'the scan must find the format strings it claims to check'

        $broken = New-Object System.Collections.Generic.List[string]
        foreach ($t in $templates) {
            $max = -1
            foreach ($m in [regex]::Matches($t.Template, '\{(\d+)')) { if ([int]$m.Groups[1].Value -gt $max) { $max = [int]$m.Groups[1].Value } }
            if ($max -lt 0) { continue }   # no format item at all - nothing to parse
            $fmtArgs = @(0..$max | ForEach-Object { 'x' })
            try { $null = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, $t.Template, $fmtArgs) }
            catch { $broken.Add(($t.File.Substring($repoRoot.Length).TrimStart('\') + ':' + $t.Line + '  ' + $t.Template + '  -> ' + $_.Exception.Message)) }
        }
        $broken.Count | Should -Be 0 -Because ($broken -join ' | ')
    }
}
