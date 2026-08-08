# Live meeting tab: must mirror the meeting state (status, talk share, VU
# meters with OK/TYST? health tags, crocodile warning, script progress,
# transcript tail) and must flag silence - the visual arm of the audio check.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppFunction 'Diktatorn.ps1' @('Build-LiveTab', 'Update-LiveTab')
$crocWinSec = 600; $crocPct = 70; $chunkSec = 30

# Meeting 90 s in: you 45 s, others 75 s (38% you), healthy audio levels.
$script:meeting = $true; $script:meetFinishing = $false
$script:meetStart = (Get-Date).AddSeconds(-90)
$script:meetSecsYou = 45.0; $script:meetSecsOthers = 75.0
$script:meetRec = [pscustomobject]@{ MicLevel = 0.12; SysLevel = 0.08; MicPeak = 0.15; SysSeconds = 60.0; MicCaptured = $true }
$script:chunkListYou = New-Object 'System.Collections.Generic.List[double]'
$script:chunkListOthers = New-Object 'System.Collections.Generic.List[double]'
@(10, 10) | ForEach-Object { $script:chunkListYou.Add([double]$_) }      # dominant talker -> croc fires
@(1, 1)   | ForEach-Object { $script:chunkListOthers.Add([double]$_) }
$script:meetLines = New-Object 'System.Collections.Generic.List[string]'
1..30 | ForEach-Object { $script:meetLines.Add("[00:00:00] Du: rad $_") }
$script:scriptChecks = @()
for ($i = 0; $i -lt 5; $i++) { $c = New-Object System.Windows.Forms.CheckBox; $c.Checked = ($i -lt 2); $script:scriptChecks += $c }

$tab = New-Object System.Windows.Forms.TabPage
$tab.Size = New-Object System.Drawing.Size(720, 560)
Build-LiveTab $tab
Update-LiveTab
[System.Windows.Forms.Application]::DoEvents()

Check 'status visar pagaende mote'  ($script:dashLiveStatus.Text -like 'MOTE PAGAR*') "'$($script:dashLiveStatus.Text)'"
Check 'talandel 38% raknas ratt'    ($script:dashTalkLabel.Text -like '*Du 38%*') "'$($script:dashTalkLabel.Text)'"
Check 'talandel-baren har bredd'    ($script:dashTalkYou.Width -gt 0)
Check 'matare OK vid friskt ljud'   (($script:dashMicTag.Text -eq 'OK') -and ($script:dashSysTag.Text -eq 'OK'))
Check 'krokodilvarning vid dominans' ($script:dashCroc.Text -like '*rokodil*')
Check 'scriptstatus 2/5'            ($script:dashScriptLbl.Text -like '*2 / 5*')
Check 'transkript visar svansen'    ($script:dashTranscript.Text -like '*rad 30*')

# Silent recorder -> both health tags must flip to TYST?
$script:meetRec = [pscustomobject]@{ MicLevel = 0.002; SysLevel = 0.0; MicPeak = 0.004; SysSeconds = 0.0; MicCaptured = $true }
Update-LiveTab
Check 'tyst ljud flaggas TYST?' (($script:dashMicTag.Text -eq 'TYST?') -and ($script:dashSysTag.Text -eq 'TYST?'))
Complete-Test
