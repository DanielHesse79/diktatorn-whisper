<#
.SYNOPSIS
    Installs Diktatorn's dependencies (not redistributed in the repo) and creates shortcuts.
.DESCRIPTION
    Downloads Whisper.dll + WhisperDesktop.exe (Const-me/Whisper 1.12), the WhisperPS module,
    NAudio.dll (NuGet), and a Whisper model (Hugging Face). Then creates Desktop + Start-Menu
    shortcuts that launch Diktatorn hidden in the system tray.
.PARAMETER Model
    Which model to download: base (fast), small (balanced, default), or medium (accurate).
.PARAMETER Autostart
    Also add Diktatorn to the per-user Startup folder (launches at login).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Diktatorn.ps1 -Model small -Autostart
#>
[CmdletBinding()]
param(
    [ValidateSet('base', 'small', 'medium')] [string] $Model = 'small',
    [switch] $Autostart,
    [switch] $NoShortcuts   # skip shortcut creation (e.g. when the Setup.exe handles it)
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }

$wd = 'https://github.com/Const-me/Whisper/releases/download/1.12.0'
$tmp = Join-Path $env:TEMP ('diktatorn-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null

# 1. Whisper.dll + WhisperDesktop.exe
if (-not (Test-Path (Join-Path $root 'Whisper.dll'))) {
    Step 'Laddar ner WhisperDesktop (Whisper.dll + exe)...'
    $z = Join-Path $tmp 'WhisperDesktop.zip'
    Invoke-WebRequest "$wd/WhisperDesktop.zip" -OutFile $z
    Expand-Archive $z -DestinationPath $root -Force
} else { Step 'Whisper.dll finns redan - hoppar over.' }

# 2. WhisperPS module
if (-not (Test-Path (Join-Path $root 'WhisperPS\WhisperPS\WhisperPS.psd1'))) {
    Step 'Laddar ner WhisperPS-modulen...'
    $z = Join-Path $tmp 'WhisperPS.zip'
    Invoke-WebRequest "$wd/WhisperPS.zip" -OutFile $z
    Expand-Archive $z -DestinationPath (Join-Path $root 'WhisperPS') -Force
} else { Step 'WhisperPS finns redan - hoppar over.' }

# 3. NAudio.dll (net35) from NuGet
$naudio = Join-Path $root 'lib\NAudio.dll'
if (-not (Test-Path $naudio)) {
    Step 'Laddar ner NAudio...'
    New-Item -ItemType Directory -Force (Join-Path $root 'lib') | Out-Null
    $z = Join-Path $tmp 'naudio.zip'
    Invoke-WebRequest 'https://www.nuget.org/api/v2/package/NAudio/1.10.0' -OutFile $z
    $ex = Join-Path $tmp 'naudio'; Expand-Archive $z -DestinationPath $ex -Force
    Copy-Item (Join-Path $ex 'lib\net35\NAudio.dll') $naudio -Force
} else { Step 'NAudio.dll finns redan - hoppar over.' }

# 4. Whisper model
$modelFile = "ggml-$Model.bin"
$modelPath = Join-Path $root "Models\$modelFile"
if (-not (Test-Path $modelPath)) {
    Step "Laddar ner modell ($modelFile) - kan ta nagra minuter..."
    New-Item -ItemType Directory -Force (Join-Path $root 'Models') | Out-Null
    Invoke-WebRequest "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$modelFile" -OutFile $modelPath -Resume
} else { Step "$modelFile finns redan - hoppar over." }

# 4b. GPU benchmark: MEASURE transcription speed (not guess from the card's name), then
#     auto-configure meeting mode and write a human-readable recommendation.
Step 'Matar transkriberings-hastigheten pa din dator (ca 30-60 s)...'
try {
    Import-Module (Join-Path $root 'WhisperPS\WhisperPS\WhisperPS.psd1') 3>$null
    $adapters = @(Get-Adapters)
    $gpu = @($adapters | Where-Object { $_ -notlike '*Basic Render*' })[0]
    if (-not $gpu) { $gpu = $adapters[0] }
    Add-Type -AssemblyName System.Speech
    Add-Type -Path (Join-Path $root 'lib\NAudio.dll')
    $bwav = Join-Path $env:TEMP 'diktatorn_bench.wav'
    $sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $sp.SetOutputToWaveFile($bwav)
    $sp.Speak('This is a benchmark of the transcription speed on this computer. We measure how fast the model runs compared to real time. The second run is the one that counts, because the model is then warm.')
    $sp.Dispose()
    $rd = New-Object NAudio.Wave.WaveFileReader($bwav); $audioSec = $rd.TotalTime.TotalSeconds; $rd.Dispose()
    $m = Import-WhisperModel -path $modelPath -adapter $gpu
    $null = Transcribe-File -model $m -path $bwav -language en                                   # cold warm-up
    $t = Measure-Command { $null = Transcribe-File -model $m -path $bwav -language en }          # warm = measured
    $rtf = [math]::Round($audioSec / [math]::Max(0.1, $t.TotalSeconds), 1)
    # Live meeting mode needs ~3-4x realtime (two streams + analysis pass per 30 s window).
    $mode = if ($rtf -ge 4) { 'live' } else { 'deferred' }
    [System.IO.File]::WriteAllText((Join-Path $root 'diktatorn-meetmode.txt'), $mode)
    $rec = @(
        "Diktatorn - automatisk rekommendation ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))",
        "GPU: $gpu",
        "Uppmatt hastighet (modell: $Model): ${rtf}x realtid",
        ""
    )
    if ($rtf -ge 8) {
        $rec += "Din dator ar snabb. Motestranskribering: LIVE. Du kan aven byta modell till"
        $rec += "'Noggrann (medium)' i menyn for battre kvalitet (laddas ner automatiskt vid val)."
    } elseif ($rtf -ge 4) {
        $rec += "Din dator klarar live-transkribering med modellen '$Model'. Motestranskribering: LIVE."
        $rec += "Undvik 'Noggrann (medium)' for moten, eller byt till 'Efter motet' i menyn."
    } else {
        $rec += "Din grafik ar for langsam for live-transkribering. Motestranskribering har satts"
        $rec += "till 'EFTER MOTET' (spelar in under motet, transkriberar nar du trycker stopp)."
        $rec += "Tips: Groq-molnlaget (gratis API-nyckel, se manualen) ger snabb transkribering"
        $rec += "aven pa klena datorer."
    }
    $recFile = Join-Path $root 'Diktatorn-rekommendation.txt'
    [System.IO.File]::WriteAllText($recFile, (($rec -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($true))
    foreach ($line in $rec) { Step $line }
} catch {
    Step "Benchmark hoppades over ($($_.Exception.Message)) - standardinstallningar behalls."
}

# 5. Icon (generate the cartoon "generalissimo" .ico)
$icon = Join-Path $root 'Diktatorn.ico'
$genIcon = Join-Path $root 'Generate-Icon.ps1'
if ((-not (Test-Path $icon)) -and (Test-Path $genIcon)) {
    Step 'Skapar ikon...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $genIcon -Root $root | Out-Null
}

# 6. Shortcuts (skipped when the Setup.exe creates them itself)
if (-not $NoShortcuts) {
    Step 'Skapar genvagar...'
    $vbs = Join-Path $root 'Diktatorn.vbs'
    $ws = New-Object -ComObject WScript.Shell
    $targets = @([System.Environment]::GetFolderPath('Desktop'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
    if ($Autostart) { $targets += [System.Environment]::GetFolderPath('Startup') }
    foreach ($dir in $targets) {
        $lnk = $ws.CreateShortcut((Join-Path $dir 'Diktatorn.lnk'))
        $lnk.TargetPath = 'wscript.exe'
        $lnk.Arguments = "`"$vbs`""
        $lnk.WorkingDirectory = $root
        if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
        $lnk.Description = 'Diktatorn - dictation (Ctrl+Shift / Ctrl+Shift+D) + meeting (Ctrl+Shift+M)'
        $lnk.Save()
    }
}

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Step 'Klart! Starta Diktatorn fran skrivbordet eller Startmenyn.'
