# Shared helpers for Diktatorn's test harnesses.
#
# The core idea: tests run the app's REAL functions, extracted from the source
# files by brace counting - never hand-copied duplicates that drift. This is the
# pattern every regression here was actually caught with (the script-manager
# scope bug, the [S01] parser bug, the popup closure bug).
#
# Conventions each Test-*.ps1 follows:
#   exit 0 = pass, exit 2 = skipped (print the reason), anything else = fail.
#   Run under Windows PowerShell 5.1 with -STA, same runtime as the app.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

# Extract a named function's full text from a source file. Brace counting is
# naive (a '{' inside a string literal would miscount) - fine for this codebase,
# where extracted functions keep braces balanced in literals too.
function Get-AppFunction([string]$file, [string]$name) {
    $src = Get-Content (Join-Path $script:RepoRoot $file) -Raw
    $s = $src.IndexOf("function $name")
    if ($s -lt 0) { throw "hittar inte 'function $name' i $file" }
    $depth = 0
    $i = $src.IndexOf('{', $s)
    for ($j = $i; $j -lt $src.Length; $j++) {
        if ($src[$j] -eq '{') { $depth++ }
        elseif ($src[$j] -eq '}') {
            $depth--
            if ($depth -eq 0) { return $src.Substring($s, $j - $s + 1) }
        }
    }
    throw "obalanserade klamrar vid extrahering av $name ur $file"
}

# Extract and define one or more app functions so the calling test can use them.
# Dot-sourcing inside THIS helper would trap the definitions in its own scope
# (they'd vanish on return - every test then fails with CommandNotFound), so the
# leading declaration is rewritten to 'function global:Name'. Only the first
# 'function ' is rewritten; nested helper functions stay function-local.
function Import-AppFunction([string]$file, [string[]]$names) {
    foreach ($n in $names) {
        $body = Get-AppFunction $file $n
        . ([scriptblock]::Create(($body -replace '^function ', 'function global:')))
    }
}

# Extract an embedded C# block by its PowerShell variable name ($csPrep etc)
# and compile it. Returns silently if the type already exists.
function Import-AppCSharp([string]$file, [string]$varName, [string]$probeType, [string[]]$refs) {
    if ($probeType -and ([System.Management.Automation.PSTypeName]$probeType).Type) { return }
    $src = Get-Content (Join-Path $script:RepoRoot $file) -Raw
    $m = [regex]::Match($src, "(?s)\`$$varName = @[`"']\r?\n(.*?)\r?\n[`"']@")
    if (-not $m.Success) { throw "hittar inte C#-blocket `$$varName i $file" }
    Add-Type -TypeDefinition $m.Groups[1].Value -ReferencedAssemblies $refs
}

function Get-NAudioPath {
    $p = Join-Path $script:RepoRoot 'lib\NAudio.dll'
    if (Test-Path $p) { return $p }
    return $null
}

# Uniform check reporting. Call Complete-Test at the end. The state variable is
# deliberately awkwardly named: tests share the script scope with this lib, and a
# test's innocent `$checks = ...` once clobbered the result list (19 phantom fails).
$script:__diktTestChecks = @()
function Check([string]$label, [bool]$ok, [string]$detail = '') {
    $script:__diktTestChecks += [pscustomobject]@{ label = $label; ok = $ok }
    $mark = if ($ok) { 'OK  ' } else { 'FAIL' }
    "  [$mark] $label$(if ($detail) { "  ($detail)" })"
}
function Complete-Test {
    $failed = @($script:__diktTestChecks | Where-Object { -not $_.ok })
    ""
    if ($failed.Count -eq 0) { "PASS ($($script:__diktTestChecks.Count) kontroller)"; exit 0 }
    "FAIL ($($failed.Count) av $($script:__diktTestChecks.Count)): $(($failed | ForEach-Object { $_.label }) -join '; ')"
    exit 1
}
function Skip-Test([string]$reason) { "SKIP: $reason"; exit 2 }
