# Live meeting tab: must mirror the meeting state (status, talk share, VU
# meters with OK/TYST? health tags, crocodile warning, script progress,
# transcript tail) and must flag silence - the visual arm of the audio check.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppUi
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

Check 'status visar motestiden'     ($script:dashLiveStatus.Text -match '^\d{2}:\d{2}$') "'$($script:dashLiveStatus.Text)'"
Check 'statusprick ar accentfargad'  ($script:dashDot.BackColor -eq $script:uiAccent)
Check 'live-korten visas'            ($script:dashLiveCard.Visible -and $script:dashTrCard.Visible)
Check 'tomtillstandet ar dolt'       (-not $script:dashIdle.Visible)
Check 'talandel visar minuter'       ($script:dashTalkLabel.Text -like '*0,8*' -or $script:dashTalkLabel.Text -like '*0.8*') "'$($script:dashTalkLabel.Text)'"
Check 'matare OK vid friskt ljud'    (($script:dashMicTag.Text -eq 'OK') -and ($script:dashSysTag.Text -eq 'OK'))
Check 'krokodilvarning vid dominans' ($script:dashCroc.Text -like '*rokodil*') "'$($script:dashCroc.Text)'"
Check 'scriptstatus 2/5'             ($script:dashScriptLbl.Text -like '*2 / 5*') "'$($script:dashScriptLbl.Text)'"
Check 'transkript visar svansen'     ($script:dashTranscript.Text -like '*rad 30*')

# Talk-share bar is owner-drawn now: paint it and confirm both segments appear.
$bmp = New-Object System.Drawing.Bitmap($script:dashTalkBar.Width, $script:dashTalkBar.Height)
$script:dashTalkBar.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
$mid = [int]($bmp.Height / 2)
$youPx = $bmp.GetPixel(6, $mid); $othPx = $bmp.GetPixel(($bmp.Width - 8), $mid)
Check 'talandel-baren ritar din del'    ($youPx.B -gt $youPx.R) "rgb($($youPx.R),$($youPx.G),$($youPx.B))"
Check 'talandel-baren ritar ovrigas del' ([math]::Abs([int]$othPx.R - [int]$othPx.B) -lt 30) "rgb($($othPx.R),$($othPx.G),$($othPx.B))"
$bmp.Dispose()

# Silent recorder -> both health tags must flip to TYST?
$script:meetRec = [pscustomobject]@{ MicLevel = 0.002; SysLevel = 0.0; MicPeak = 0.004; SysSeconds = 0.0; MicCaptured = $true }
Update-LiveTab
Check 'tyst ljud flaggas TYST?' (($script:dashMicTag.Text -eq 'TYST?') -and ($script:dashSysTag.Text -eq 'TYST?'))

# No meeting -> the idle panel replaces the live cards (a dead 0% bar reads as a bug)
$script:meeting = $false; $script:meetFinishing = $false
Update-LiveTab
Check 'tomtillstandet visas i vila'   $script:dashIdle.Visible
Check 'live-korten doljs i vila'      ((-not $script:dashLiveCard.Visible) -and (-not $script:dashTrCard.Visible))
Check 'statusprick gron i vila'       ($script:dashDot.BackColor -eq $script:uiOk)

Complete-Test
