# Parse-SalesScript must turn the bundled example into a usable checklist with
# Swedish characters intact, and New-ScriptName must produce ASCII-safe filenames.
. (Join-Path $PSScriptRoot '_TestLib.ps1')

Import-AppFunction 'Diktatorn.ps1' @('Parse-SalesScript', 'New-ScriptName')

$example = Join-Path $script:RepoRoot 'exempel-saljsamtal.md'
if (-not (Test-Path $example)) { Skip-Test 'exempel-saljsamtal.md saknas' }

$items = Parse-SalesScript $example
$sections = @($items | Where-Object { $_.kind -eq 'section' })
$points   = @($items | Where-Object { $_.kind -eq 'item' })
Check 'minst 6 rubriker'  ($sections.Count -ge 6) "fick $($sections.Count)"
Check 'minst 15 punkter'  ($points.Count -ge 15)  "fick $($points.Count)"

# Swedish characters must survive the UTF-8 read (a mojibake regression shows up
# as their absence or as replacement characters).
$all = ($items | ForEach-Object { $_.text }) -join ' '
$sw = @([char]0xE5, [char]0xE4, [char]0xF6) | Where-Object { $all.Contains([string]$_) }
Check 'aao intakta i parsad text' ($sw.Count -eq 3) "hittade $($sw.Count) av 3"
Check 'inga ersattningstecken'    (-not $all.Contains([string][char]0xFFFD))

# Filenames must be ASCII-safe and non-empty even from hostile titles.
$n1 = New-ScriptName ('M' + [char]0xF6 + 'te med VD:n! ***')
Check 'New-ScriptName ger ascii'  ($n1 -match '^[\x20-\x7E]+\.md$') "fick '$n1'"
Check 'New-ScriptName tom titel'  ((New-ScriptName '???') -eq 'script.md')
Complete-Test
