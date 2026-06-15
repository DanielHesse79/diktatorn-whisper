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
    [switch] $Autostart
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

# 5. Icon (generate the cartoon "generalissimo" .ico)
$icon = Join-Path $root 'Diktatorn.ico'
$genIcon = Join-Path $root 'Generate-Icon.ps1'
if ((-not (Test-Path $icon)) -and (Test-Path $genIcon)) {
    Step 'Skapar ikon...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $genIcon -Root $root | Out-Null
}

# 6. Shortcuts
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

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Step 'Klart! Starta Diktatorn fran skrivbordet eller Startmenyn.'
