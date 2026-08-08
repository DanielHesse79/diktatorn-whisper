# The script manager's buttons must work when clicked AFTER Open-ScriptManager
# has returned - the real usage. Regression: the first version kept controls as
# function locals and every handler silently did nothing (PowerShell no longer
# resolves the enclosing function's locals once it returns).
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppFunction 'Diktatorn.ps1' @(
    'Get-ScriptFiles', 'New-ScriptName', 'Parse-SalesScript',
    'Update-ScriptList', 'Save-CurrentScript', 'Confirm-ScriptSave', 'Open-ScriptManager')

$scriptsDir = Join-Path $env:TEMP 'dikt_test_scripts'
Remove-Item $scriptsDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $scriptsDir | Out-Null
Copy-Item (Join-Path $script:RepoRoot 'exempel-saljsamtal.md') $scriptsDir

function Write-Log($m) {}
$script:coach = 'groq'
function Get-CoachKey($p) { 'stub' }
$script:openedInCall = $null
function Open-ScriptWindow($p) { $script:openedInCall = $p }

Open-ScriptManager
[System.Windows.Forms.Application]::DoEvents()
Check 'fonster oppnas med scriptet laddat' (($script:mgrList.Items.Count -eq 1) -and ($script:mgrEditor.Text.Length -gt 100))

# Click the buttons the way a user would - after the builder returned.
$bar = @($script:mgrForm.Controls | Where-Object { $_ -is [System.Windows.Forms.FlowLayoutPanel] })[0]
function Click([string]$text) {
    $b = @($bar.Controls | Where-Object { $_.Text -eq $text })[0]
    if (-not $b) { throw "knappen '$text' saknas" }
    $b.PerformClick()
    [System.Windows.Forms.Application]::DoEvents()
}
Click 'Spara'
Check 'Spara skriver filen' ($script:mgrStatus.Text -like '*Sparat*')
Click 'Kopiera'
Check 'Kopiera skapar en fil (1 -> 2)' ($script:mgrList.Items.Count -eq 2)
Click 'Anvand i samtal'
Check 'Anvand i samtal oppnar checklistan' ($null -ne $script:openedInCall)

$script:mgrForm.Dispose()
Remove-Item $scriptsDir -Recurse -Force -ErrorAction SilentlyContinue
Complete-Test
