; Inno Setup script for Diktatorn
; Builds a per-user Setup.exe. Bundles the app scripts; downloads the heavy
; dependencies (Whisper.dll, WhisperPS, NAudio, model) as a post-install step.
; Compile:  "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" Diktatorn.iss

#define MyAppName "Diktatorn"
#define MyAppVersion "1.4.0"
#define MyAppPublisher "Daniel Hesse"
#define MyAppURL "https://github.com/DanielHesse79/diktatorn-whisper"

[Setup]
AppId={{7C9E6F12-3A4B-4D5E-8F1A-2B3C4D5E6F70}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={localappdata}\Diktatorn
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist
OutputBaseFilename=Diktatorn-Setup
SetupIconFile=Diktatorn.ico
UninstallDisplayIcon={app}\Diktatorn.ico
WizardStyle=modern
Compression=lzma2
SolidCompression=yes

[Languages]
Name: "swedish"; MessagesFile: "compiler:Languages\Swedish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Types]
Name: "full";   Description: "Allt (rekommenderas)"
Name: "custom"; Description: "Valj sjalv"; Flags: iscustom

[Components]
Name: "core"; Description: "Diktatorn - diktering, journal och motestranskribering"; Types: full custom; Flags: fixed
Name: "salj"; Description: "Saljcoach - saljscript med automatisk avbockning under motet"; Types: full

[Tasks]
Name: "desktopicon"; Description: "Skapa en genvag pa skrivbordet"; GroupDescription: "Genvagar:"
Name: "autostart"; Description: "Starta Diktatorn automatiskt vid inloggning"; GroupDescription: "Genvagar:"

[Files]
Source: "Diktatorn.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "Telefonassistent.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "Diktatorn.vbs";        DestDir: "{app}"; Flags: ignoreversion
Source: "Generate-Icon.ps1";    DestDir: "{app}"; Flags: ignoreversion
Source: "Diktatorn.ico";        DestDir: "{app}"; Flags: ignoreversion
Source: "Install-Diktatorn.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.md";            DestDir: "{app}"; Flags: ignoreversion
Source: "SaljScript.ps1";       DestDir: "{app}"; Flags: ignoreversion; Components: salj
Source: "exempel-saljsamtal.md"; DestDir: "{app}"; Flags: ignoreversion; Components: salj
Source: "Anvandarmanual.md";    DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE";              DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Diktatorn"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Diktatorn.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\Diktatorn.ico"
Name: "{autodesktop}\Diktatorn"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Diktatorn.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\Diktatorn.ico"; Tasks: desktopicon
Name: "{userstartup}\Diktatorn"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\Diktatorn.vbs"""; WorkingDir: "{app}"; IconFilename: "{app}\Diktatorn.ico"; Tasks: autostart

[Run]
; Download Whisper.dll + WhisperPS + NAudio + the model into {app}. Needs internet; may take a few minutes.
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Install-Diktatorn.ps1"" -NoShortcuts -Model small"; \
  StatusMsg: "Laddar ner Whisper-motorn och sprakmodellen (kan ta nagra minuter)..."; \
  Flags: runhidden waituntilterminated
; Offer to launch right after install
Filename: "{sys}\wscript.exe"; Parameters: """{app}\Diktatorn.vbs"""; Description: "Starta Diktatorn nu"; Flags: postinstall nowait skipifsilent


[InstallDelete]
; Inno tar inte bort filer fran en komponent som avmarkeras vid ominstallation.
; Utan det har skulle SaljScript.ps1 ligga kvar och Diktatorn ladda den anda.
Type: files; Name: "{app}\SaljScript.ps1";       Components: not salj
Type: files; Name: "{app}\exempel-saljsamtal.md"; Components: not salj

[UninstallDelete]
Type: filesandordirs; Name: "{app}\WhisperPS"
Type: filesandordirs; Name: "{app}\lib"
Type: filesandordirs; Name: "{app}\Models"
Type: files; Name: "{app}\Whisper.dll"
Type: files; Name: "{app}\WhisperDesktop.exe"
Type: files; Name: "{app}\lz4.txt"
Type: files; Name: "{app}\Diktatorn.png"
Type: files; Name: "{app}\diktatorn-mic.txt"
Type: files; Name: "{app}\diktatorn-model.txt"
Type: files; Name: "{app}\diktatorn-backend.txt"
Type: files; Name: "{app}\diktatorn-groq.txt"
Type: files; Name: "{app}\diktatorn-openrouter.txt"
Type: files; Name: "{app}\diktatorn-telefon-utgang.txt"
Type: files; Name: "{app}\diktatorn-telefon-server.txt"
Type: files; Name: "{app}\diktatorn-overlay.txt"
