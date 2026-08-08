# Meeting recording and the phone assistant both tap the system loopback and
# must never run simultaneously. Five cases: both guards short-circuit BEFORE
# any side effects, and both normal paths still proceed when the other is idle.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms

Import-AppFunction 'Diktatorn.ps1' @('Start-Meeting')
Import-AppFunction 'Telefonassistent.ps1' @('Start-Telefonassistent')

$script:balloons = @()
$tray = [pscustomobject]@{}
$tray | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value { param($t, $ti, $m, $ic) $script:balloons += $m }
function Write-Log($m) {}
function Cancel-Dictation {}
$script:popupCalled = $false
function Show-MeetLangPrompt { $script:popupCalled = $true; return $null }   # null = avbryt -> saker abort
$script:utgangCalled = $false
function Get-TaValdUtgang { $script:utgangCalled = $true; return $null }     # null -> saker abort efter vakten

# 1. Start-Meeting medan bryggan kor -> vagra fore sprakpopupen
$script:meeting = $false; $script:meetFinishing = $false; $script:dictating = $false
$script:taBridge = [pscustomobject]@{ Aktiv = $true }
$script:popupCalled = $false; $script:balloons = @()
Start-Meeting
Check 'Start-Meeting vagrar under telefonsamtal' ((-not $script:popupCalled) -and (-not $script:meeting) -and ($script:balloons.Count -eq 1))

# 2. Start-Meeting utan brygga -> nar popupen (normalvagen opaverkad)
$script:taBridge = $null; $script:popupCalled = $false
Start-Meeting
Check 'Start-Meeting nar popupen i vila' $script:popupCalled

# 3. Start-Telefonassistent under mote -> vagra fore utgangsvalet
$script:meeting = $true
$script:utgangCalled = $false; $script:balloons = @()
$r = Start-Telefonassistent 'svarare' 400
Check 'telefonassistent vagrar under mote' (($r -eq $false) -and (-not $script:utgangCalled) -and ($script:balloons.Count -eq 1))

# 4. ...och under efterbatchen (meetFinishing)
$script:meeting = $false; $script:meetFinishing = $true
$script:utgangCalled = $false
$r = Start-Telefonassistent 'svarare' 400
Check 'telefonassistent vagrar under efterbatch' (($r -eq $false) -and (-not $script:utgangCalled))

# 5. I vila -> passerar vakten
$script:meetFinishing = $false
$script:utgangCalled = $false
$null = Start-Telefonassistent 'svarare' 400
Check 'telefonassistent passerar vakten i vila' $script:utgangCalled
Complete-Test
