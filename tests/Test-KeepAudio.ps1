# Keep-audio archiving: OFF archives nothing; ON copies (never moves) every
# chunk into the dated archive; the purge removes only folders older than the
# retention window. This is the safety net for re-transcribing a broken meeting.
. (Join-Path $PSScriptRoot '_TestLib.ps1')

Import-AppFunction 'Diktatorn.ps1' @('Save-MeetingAudio', 'Clear-OldMeetingAudio')
function Write-Log($m) {}

$outRoot = Join-Path $env:TEMP 'dikt_test_keepaudio'
Remove-Item $outRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $outRoot | Out-Null
$audioArchive = Join-Path $outRoot 'Motesljud'
$keepAudioDays = 7

$script:meetDir = Join-Path $outRoot 'meetdir'
New-Item -ItemType Directory -Force $script:meetDir | Out-Null
Set-Content (Join-Path $script:meetDir 'chunk_0000_sys.wav') 'RIFFx'
Set-Content (Join-Path $script:meetDir 'chunk_0000_mic.wav') 'RIFFy'
$script:meetOutFile = Join-Path $outRoot 'Mote_2026-01-01_120000.txt'

$script:meetKeepAudio = $false
Save-MeetingAudio
Check 'OFF: inget arkiveras' (@(Get-ChildItem $audioArchive -Directory -ErrorAction SilentlyContinue).Count -eq 0)

$script:meetKeepAudio = $true
Save-MeetingAudio
$dest = Join-Path $audioArchive 'Mote_2026-01-01_120000'
Check 'ON: mapp skapas'          (Test-Path $dest)
Check 'ON: bada wav kopieras'    (@(Get-ChildItem $dest -Filter *.wav -ErrorAction SilentlyContinue).Count -eq 2)
Check 'ON: original finns kvar'  (Test-Path (Join-Path $script:meetDir 'chunk_0000_sys.wav'))

$old = Join-Path $audioArchive 'Mote_gammalt'
New-Item -ItemType Directory -Force $old | Out-Null
Set-Content (Join-Path $old 'x.wav') 'z'
(Get-Item $old).LastWriteTime = (Get-Date).AddDays(-8)
Clear-OldMeetingAudio
Check 'purge: farskt mote kvar'   (Test-Path $dest)
Check 'purge: >7 dagar rensas'    (-not (Test-Path $old))

Remove-Item $outRoot -Recurse -Force -ErrorAction SilentlyContinue
Complete-Test
