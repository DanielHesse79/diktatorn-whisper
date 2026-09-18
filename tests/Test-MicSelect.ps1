# Microphone selection must never land on a virtual input (Voicemeeter bus, VB-CABLE,
# stereo mix) unless the user picked it, and recordings must find the chosen mic by
# NAME at record time. Seen live 2026-09-18: installing Voicemeeter put a mute bus
# first in the Windows list and shifted every WaveIn index; calls went out silent.
. (Join-Path $PSScriptRoot '_TestLib.ps1')

Import-AppVariable 'Diktatorn.ps1' 'virtualMicPattern'
Import-AppFunction 'Diktatorn.ps1' @('Test-VirtualMic', 'Resolve-MicDevice')
function Write-Log($m) {}

$micCfg = Join-Path $env:TEMP 'dikt_test_mic.txt'
Remove-Item $micCfg -ErrorAction SilentlyContinue
function Pick([string[]]$names, [string]$prefer) {
    $script:micNames = $names; $script:preferMic = $prefer
    $script:micOnlyVirtual = $false; $script:micHow = 'automatiskt vald'
    return (Resolve-MicDevice)
}
$real = 'Mikrofon (USB PnP Sound Device)'
$cam  = 'Mikrofon (USB Camera)'
$vm   = 'Voicemeeter Out B3 (VB-Audio Vo'   # WaveIn truncates names to 31 characters
$cab  = 'CABLE Output (VB-Audio Virtual'

$i = Pick @($vm, $real, $cam) 'finns-inte'
Check 'Voicemeeter forst i listan -> forsta riktiga' ($script:micNames[$i] -eq $real) "fick $($script:micNames[$i])"
$i = Pick @($vm, $real, $cam) 'USB Camera'
Check 'preferens pa riktig mik foljs'                ($script:micNames[$i] -eq $cam) "fick $($script:micNames[$i])"
$i = Pick @($vm, $cab, $cam) 'CABLE'
Check 'preferens som pekar pa virtuell ignoreras'    ($script:micNames[$i] -eq $cam) "fick $($script:micNames[$i])"
$i = Pick @($vm, $cab) 'x'
Check 'bara virtuella -> startvarning'               ([bool]$script:micOnlyVirtual)
[IO.File]::WriteAllText($micCfg, $vm)
$i = Pick @($real, $vm) 'x'
Check 'eget val i menyn vinner, aven virtuellt'      ($script:micNames[$i] -eq $vm -and $script:micHow -eq 'vald i menyn') "fick $($script:micNames[$i]) ($($script:micHow))"
Remove-Item $micCfg -ErrorAction SilentlyContinue

# Name lookup at record time, against this machine's real WaveIn devices.
$naudio = Get-NAudioPath
if ($naudio) {
    Add-Type -Path $naudio
    Import-AppFunction 'Diktatorn.ps1' @('Get-RecMicDevice')
    $fresh = @()
    for ($k = 0; $k -lt [NAudio.Wave.WaveIn]::DeviceCount; $k++) { $fresh += [NAudio.Wave.WaveIn]::GetCapabilities($k).ProductName }
    if ($fresh.Count -ge 2) {
        # Devices added after startup: the startup list is the real one reversed, so the
        # stored index now points at a different device.
        $script:micNames = @($fresh[($fresh.Count - 1)..0]); $script:micDevice = 0
        $want = $script:micNames[0]
        $got = Get-RecMicDevice
        Check 'inspelning hittar valda mik pa namn trots forskjutna index' ($fresh[$got] -eq $want) "ville '$want', fick '$($fresh[$got])'"
    }
    if (@($fresh | Where-Object { -not (Test-VirtualMic $_) }).Count) {
        $script:micNames = @('Headset som inte finns langre'); $script:micDevice = 0
        $got = Get-RecMicDevice
        Check 'forsvunnen mik -> riktig ersattare, aldrig virtuell' (-not (Test-VirtualMic $fresh[$got])) "fick '$($fresh[$got])'"
    }
}
Complete-Test
