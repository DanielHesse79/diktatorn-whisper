# The meeting-chunk silence gate must measure SPEECH, not file size. AudioPrep.Clean
# keeps up to one second of every silent stretch, so a completely silent 30 s chunk
# still came out as a 32 kB file - past the old "< 16000 bytes = silence" check and
# straight into Whisper, which answered "Textning.nu". Seen live 2026-09-18: four
# phone calls where every silent half-minute became a fake line in the transcript.
. (Join-Path $PSScriptRoot '_TestLib.ps1')

$naudio = Get-NAudioPath
if (-not $naudio) { Skip-Test 'lib\NAudio.dll saknas (kor Install-Diktatorn.ps1 forst)' }
Add-Type -Path $naudio
Import-AppCSharp 'Diktatorn.ps1' 'csPrep' 'AudioPrep' @($naudio)
Import-AppVariable 'Diktatorn.ps1' 'minVoicedSamples'
Import-AppVariable 'Diktatorn.ps1' 'whisperCredits'
Import-AppVariable 'Diktatorn.ps1' 'whisperOnlyIf'
Import-AppFunction 'Diktatorn.ps1' @('Remove-WhisperNoise')

$speech  = Join-Path $env:TEMP 'dikt_chunk_speech.wav'
$silence = Join-Path $env:TEMP 'dikt_chunk_silence.wav'
$blips   = Join-Path $env:TEMP 'dikt_chunk_blips.wav'
$clean   = Join-Path $env:TEMP 'dikt_chunk_clean.wav'

$buf = New-Object 'single[]' 16000
$w = New-Object NAudio.Wave.WaveFileWriter($speech, (New-Object NAudio.Wave.WaveFormat(16000, 16, 1)))
for ($s = 0; $s -lt 3; $s++) {
    for ($i = 0; $i -lt 16000; $i++) {
        $n = $s * 16000 + $i
        $buf[$i] = [float](0.25 * [math]::Sin(2 * [math]::PI * 220 * $n / 16000) * (0.5 + 0.5 * [math]::Sin(2 * [math]::PI * 3 * $n / 16000)))
    }
    $w.WriteSamples($buf, 0, 16000)
}
$w.Dispose()
# 30 s like a real chunk. Blips: a few samples at 0.0002 (~-74 dB), the level measured
# on the real silent chunks.
foreach ($f in @(@{ p = $silence; blip = $false }, @{ p = $blips; blip = $true })) {
    $w = New-Object NAudio.Wave.WaveFileWriter($f.p, (New-Object NAudio.Wave.WaveFormat(16000, 16, 1)))
    for ($s = 0; $s -lt 30; $s++) {
        [Array]::Clear($buf, 0, $buf.Length)
        if ($f.blip) { $buf[0] = 0.0002; $buf[8000] = -0.0002 }
        $w.WriteSamples($buf, 0, 16000)
    }
    $w.Dispose()
}

# Same gate expression as Get-ChunkText / Measure-Chunk / Rebuild-Transcript.
function Test-ChunkGate([string]$wav) {
    Remove-Item $clean -ErrorAction SilentlyContinue
    [AudioPrep]::Clean($wav, $clean)
    return ((Test-Path $clean) -and ([AudioPrep]::VoicedSamples($clean) -ge $minVoicedSamples))
}
Check 'tal transkriberas'                     (Test-ChunkGate $speech)
Check 'digital tystnad hoppas over'           (-not (Test-ChunkGate $silence))
Check 'enstaka blippar (~-74 dB) hoppas over' (-not (Test-ChunkGate $blips))
# The regression itself: the old size check could never reject a silent chunk.
[AudioPrep]::Clean($silence, $clean)
$sz = (Get-Item $clean).Length
Check 'gamla storleksgrinden hade slappt igenom tystnaden' ($sz -ge 16000) "$sz byte efter Clean"

$o = [char]0xF6   # the real Swedish letter, so 'f.r' in the pattern is tested against it
Check 'Textning.nu bort'                       ($null -eq (Remove-WhisperNoise 'Textning.nu'))
Check 'Svensktextning.nu bort'                 ($null -eq (Remove-WhisperNoise 'Svensktextning.nu'))
Check 'Tack till elever och personal ... bort' ($null -eq (Remove-WhisperNoise 'Tack till elever och personal vid Sakerhetssakerheten.'))
Check 'Tack for att du tittade bort'           ($null -eq (Remove-WhisperNoise ('Tack f' + $o + 'r att du tittade!')))
$r = Remove-WhisperNoise 'Ja men hej Edward! Daniel Hesse har. Textning.nu'
Check 'eftertext rensas ur riktigt tal'        ($r -eq 'Ja men hej Edward! Daniel Hesse har.') "fick '$r'"
$r = Remove-WhisperNoise 'Hej, Juri, det ar Peter i Receptifarma'
Check 'riktigt tal orort'                      ($r -eq 'Hej, Juri, det ar Peter i Receptifarma') "fick '$r'"
$r = Remove-WhisperNoise ('Jag vill tacka f' + $o + 'r att du tittade pa offerten igar.')
Check 'tack-fras mitt i en mening behalls'     ($r -like 'Jag vill tacka*offerten igar.') "fick '$r'"

Remove-Item $speech, $silence, $blips, $clean -ErrorAction SilentlyContinue
Complete-Test
