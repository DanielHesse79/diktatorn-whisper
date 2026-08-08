# Dashboard lifecycle: opens with all four tabs, reopening activates rather
# than duplicates, closing hides (not disposes) and stops the refresh timer,
# reopening shows the window again and restarts the timer. Regression: Activate
# alone won't un-hide a hidden window, leaving the dashboard unreachable.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppFunction 'Diktatorn.ps1' @('Open-Dashboard')
# Lifecycle only - stub the tab content builders.
function Build-LiveTab($t) {}
function Update-LiveTab {}
function Build-SettingsTab($t) {}
function Build-HistoryTab($t) {}
function Refresh-HistoryList {}
function Build-TrendTab($t) {}
function Refresh-TrendView {}
$icoIdle = [System.Drawing.SystemIcons]::Application

Open-Dashboard
[System.Windows.Forms.Application]::DoEvents()
$tabs = @($script:dashForm.Controls | Where-Object { $_ -is [System.Windows.Forms.TabControl] })[0]
Check 'fonstret oppnas synligt'   $script:dashForm.Visible
Check 'fyra flikar'               ($tabs.TabPages.Count -eq 4) "fick $($tabs.TabPages.Count)"
Check 'live-timern gar'           $script:dashTimer.Enabled

Open-Dashboard
$forms = @([System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'Diktatorn' })
Check 'aterppning dubblerar inte' ($forms.Count -eq 1) "fick $($forms.Count) fonster"

$script:dashForm.Close()
[System.Windows.Forms.Application]::DoEvents()
Check 'stangning doljer (disposar inte)' ((-not $script:dashForm.Visible) -and (-not $script:dashForm.IsDisposed))
Check 'stangning stoppar timern'         (-not $script:dashTimer.Enabled)

Open-Dashboard
[System.Windows.Forms.Application]::DoEvents()
Check 'aterppning visar igen'      $script:dashForm.Visible
Check 'aterppning startar timern'  $script:dashTimer.Enabled

$script:dashTimer.Stop(); $script:dashForm.Dispose()
Complete-Test
