# The journal silence gate (AudioPrep.Clean + Rms >= 0.01) must pass real speech
# and reject room noise. Without it, Whisper invents plausible sentences out of
# hiss and writes fabricated entries into a personal journal (seen live:
# "Tack till elever och personal vid Varmland" from an empty room).
. (Join-Path $PSScriptRoot '_TestLib.ps1')

$naudio = Get-NAudioPath
if (-not $naudio) { Skip-Test 'lib\NAudio.dll saknas (kor Install-Diktatorn.ps1 forst)' }
Add-Type -Path $naudio
Import-AppCSharp 'Diktatorn.ps1' 'csPrep' 'AudioPrep' @($naudio)

# Synthetic but calibrated to real measurements: speech peaks ~0.25 (measured
# mic speech ~0.1-0.44), room noise ~0.004 RMS (measured 0.004-0.005).
function New-Wav([string]$path, [scriptblock]$sample) {
    $w = New-Object NAudio.Wave.WaveFileWriter($path, (New-Object NAudio.Wave.WaveFormat(16000, 16, 1)))
    $buf = New-Object 'single[]' 16000
    for ($s = 0; $s -lt 3; $s++) {
        for ($i = 0; $i -lt 16000; $i++) { $buf[$i] = & $sample ($s * 16000 + $i) }
        $w.WriteSamples($buf, 0, 16000)
    }
    $w.Dispose()
}
$speech = Join-Path $env:TEMP 'dikt_test_speech.wav'
$noise  = Join-Path $env:TEMP 'dikt_test_noise.wav'
New-Wav $speech { param($i) [float](0.25 * [math]::Sin(2 * [math]::PI * 220 * $i / 16000) * (0.5 + 0.5 * [math]::Sin(2 * [math]::PI * 3 * $i / 16000))) }
$rnd = New-Object System.Random 42
New-Wav $noise { param($i) [float](($rnd.NextDouble() - 0.5) * 0.008) }

# Same gate expression as Stop-Journal: exists AND >=0.5s voiced AND rms >= 0.01
function Test-Gate([string]$wav) {
    $clean = Join-Path $env:TEMP 'dikt_test_clean.wav'
    Remove-Item $clean -ErrorAction SilentlyContinue
    try { [AudioPrep]::Clean($wav, $clean) } catch { return $false }
    if (-not (Test-Path $clean) -or ((Get-Item $clean).Length -lt 16000)) { return $false }
    return ([AudioPrep]::Rms($clean) -ge 0.01)
}
Check 'tal slapps igenom'   (Test-Gate $speech)
Check 'rumsbrus avvisas'    (-not (Test-Gate $noise))
Remove-Item $speech, $noise, (Join-Path $env:TEMP 'dikt_test_clean.wav') -ErrorAction SilentlyContinue
Complete-Test
