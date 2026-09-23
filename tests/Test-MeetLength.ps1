# A meeting left running must be noticed. 2026-09-18 a recording ran for 50 hours after
# the call ended and 3 082 of its 3 737 lines were Whisper filling silence. Two warnings:
# nobody has spoken for $idleWarnSec, and the recording passed $longWarnSec.
. (Join-Path $PSScriptRoot '_TestLib.ps1')

Import-AppVariable 'Diktatorn.ps1' 'chunkSec'
Import-AppVariable 'Diktatorn.ps1' 'idleWarnSec'
Import-AppVariable 'Diktatorn.ps1' 'longWarnSec'
Import-AppVariable 'Diktatorn.ps1' 'longRepeatSec'
Import-AppFunction 'Diktatorn.ps1' @('Get-MeetIdleSeconds', 'Get-MeetLengthWarning')

function Set-Chunks([double[]]$you, [double[]]$others) {
    $script:chunkListYou = New-Object 'System.Collections.Generic.List[double]'
    $script:chunkListOthers = New-Object 'System.Collections.Generic.List[double]'
    for ($i = 0; $i -lt $you.Count; $i++) { $script:chunkListYou.Add($you[$i]); $script:chunkListOthers.Add($others[$i]) }
}
Set-Chunks @(4, 0, 0.3, 0) @(2, 6, 0, 0)
Check 'tystnad raknas bakifran'             ((Get-MeetIdleSeconds) -eq 2 * $chunkSec) "fick $(Get-MeetIdleSeconds)"
Set-Chunks @(0, 0, 3) @(0, 0, 0)
Check 'nagon pratade i sista biten -> 0'    ((Get-MeetIdleSeconds) -eq 0)
Set-Chunks @() @()
Check 'inga bitar an -> 0'                  ((Get-MeetIdleSeconds) -eq 0)

# Simulate a meeting minute by minute and record which warnings fire when.
function Invoke-Meeting([int]$minutes, [scriptblock]$idleAt) {
    $script:idleWarnedAt = 0; $script:longWarnedAt = 0
    $fired = @()
    for ($m = 1; $m -le $minutes; $m++) {
        $w = Get-MeetLengthWarning ($m * 60) (& $idleAt $m)
        if ($w) { $fired += "$w@$m" }
    }
    return $fired
}
$idleMin = $idleWarnSec / 60; $longMin = $longWarnSec / 60; $repMin = $longRepeatSec / 60

# Active 90-minute call: never quiet for long -> nothing.
$f = Invoke-Meeting 90 { param($m) ($m % 4) * 60 }
Check 'aktivt 90-minuterssamtal -> ingen varning' ($f.Count -eq 0) "fick $($f -join ', ')"

# Call ends after 20 min, the recording keeps going: idle warning after $idleWarnSec,
# then again for every further $idleWarnSec of silence.
$f = Invoke-Meeting 45 { param($m) [math]::Max(0, $m - 20) * 60 }
$want = @("idle@$(20 + $idleMin)", "idle@$(20 + 2 * $idleMin)")
Check 'glomd inspelning -> tyst-varning, sedan igen' (($f -join ',') -eq ($want -join ',')) "fick $($f -join ', ')"

# Someone speaks after the first warning: re-arms, and warns again only after a new full stretch.
$f = Invoke-Meeting 30 { param($m) if ($m -le 15) { $m * 60 } else { ($m - 15) * 60 } }
$want = @("idle@$idleMin", "idle@$(15 + $idleMin)")
Check 'nagon pratar -> tyst-varningen nollstalls' (($f -join ',') -eq ($want -join ',')) "fick $($f -join ', ')"

# Long but lively meeting: one warning at $longWarnSec, then every $longRepeatSec.
$f = Invoke-Meeting ($longMin + 2 * $repMin + 5) { param($m) 0 }
$want = @("long@$longMin", "long@$($longMin + $repMin)", "long@$($longMin + 2 * $repMin)")
Check 'langt mote -> varning vid 2 h och varje timme' (($f -join ',') -eq ($want -join ',')) "fick $($f -join ', ')"

Check 'standard: 10 min tystnad, 2 h langd' (($idleWarnSec -eq 600) -and ($longWarnSec -eq 7200))
Complete-Test
