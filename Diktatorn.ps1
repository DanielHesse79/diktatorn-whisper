# Diktatorn  -  global dictation + meeting transcription for Const-me Whisper
#
#   DICTATION (types text at the cursor in any app):
#     * Hold Ctrl+Shift  (push-to-talk): speak, release -> text is typed.
#     * Ctrl+Shift+D     (toggle):       press to start, press again to stop.
#   MEETING (captures system/computer audio = remote participants):
#     * Ctrl+Shift+M  or tray menu: start; press again to stop.
#       Records the whole meeting, transcribes on stop, saves + opens a transcript.
#
# Runs in the system tray. No window steals focus, so dictated text lands in the active app.

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePsd = Join-Path $root 'WhisperPS\WhisperPS\WhisperPS.psd1'
$modelPath = Join-Path $root 'Models\ggml-medium.bin'
$naudioDll = Join-Path $root 'lib\NAudio.dll'
$adapter   = $null   # GPU adapter, auto-detected after the WhisperPS module loads
$language  = 'sv'
$outDir    = Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) 'Transcriptions'
$tmpDict   = Join-Path $env:TEMP 'whisprflow_dict.wav'
$tmpMeet   = Join-Path $env:TEMP 'whisprflow_meeting.wav'        # system audio (loopback)
$tmpMeetMic = Join-Path $env:TEMP 'whisprflow_meeting_mic.wav'   # your mic
$tmpMeetMixed = Join-Path $env:TEMP 'whisprflow_meeting_mix.wav' # mixed
$tmpMeetClean = Join-Path $env:TEMP 'whisprflow_meeting_16k.wav' # cleaned -> transcribed
$micCfg    = Join-Path $root 'diktatorn-mic.txt'   # remembers which microphone to use
$preferMic = 'USB PnP Sound Device'                # default mic (substring match), not the room/camera
$backendCfg = Join-Path $root 'diktatorn-backend.txt'   # 'local' or 'groq'
$groqKeyFile = Join-Path $root 'diktatorn-groq.txt'     # Groq API key (plaintext, local only)
$groqModel  = 'whisper-large-v3-turbo'
New-Item -ItemType Directory -Force $outDir | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Native: message-only hotkey window + key polling + unicode typing ---
$cs = @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Collections.Generic;

public class WfNative : NativeWindow {
    public event Action<int> HotkeyPressed;
    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;
    List<int> ids = new List<int>();

    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vKey);
    public static bool IsDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    public WfNative() {
        CreateParams cp = new CreateParams();
        cp.Parent = (IntPtr)(-3); // HWND_MESSAGE
        this.CreateHandle(cp);
    }
    public bool Register(int id, uint modifiers, uint vk) {
        bool ok = RegisterHotKey(this.Handle, id, modifiers | MOD_NOREPEAT, vk);
        if (ok) ids.Add(id);
        return ok;
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY && HotkeyPressed != null) HotkeyPressed((int)m.WParam);
        base.WndProc(ref m);
    }
    public void Dispose() {
        foreach (int id in ids) UnregisterHotKey(this.Handle, id);
        this.DestroyHandle();
    }

    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KEYBDINPUT ki; public int p1; public int p2; }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int cb);
    const uint INPUT_KEYBOARD=1, KEYEVENTF_KEYUP=0x2, KEYEVENTF_UNICODE=0x4;
    const ushort VK_RETURN=0x0D;
    public static void TypeText(string text) {
        foreach (char c in text) {
            if (c == '\n') { SendVk(VK_RETURN); continue; }
            if (c == '\r') continue;
            INPUT[] inp = new INPUT[2];
            inp[0].type = INPUT_KEYBOARD; inp[0].ki.wScan = c; inp[0].ki.dwFlags = KEYEVENTF_UNICODE;
            inp[1].type = INPUT_KEYBOARD; inp[1].ki.wScan = c; inp[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            SendInput(2, inp, Marshal.SizeOf(typeof(INPUT)));
        }
    }
    static void SendVk(ushort vk) {
        INPUT[] inp = new INPUT[2];
        inp[0].type = INPUT_KEYBOARD; inp[0].ki.wVk = vk;
        inp[1].type = INPUT_KEYBOARD; inp[1].ki.wVk = vk; inp[1].ki.dwFlags = KEYEVENTF_KEYUP;
        SendInput(2, inp, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms

# --- Native: WASAPI loopback meeting recorder (DataAvailable handled in C# -> thread-safe) ---
Add-Type -Path $naudioDll
$csRec = @"
using System;
using System.Threading;
using NAudio.Wave;
public class MeetingRecorder {
    // Captures BOTH system audio (loopback = remote participants) and the mic (you), to two files.
    WasapiLoopbackCapture sys;
    WaveInEvent mic;
    WaveFileWriter sysW, micW;
    ManualResetEvent sysStopped = new ManualResetEvent(false);
    ManualResetEvent micStopped = new ManualResetEvent(false);
    bool micOn = false;
    public bool MicCaptured { get { return micOn; } }
    public void Start(string sysPath, string micPath, int micDevice) {
        var prev = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);   // events on a bg thread, not the blocked UI thread
        sys = new WasapiLoopbackCapture();
        mic = new WaveInEvent();
        SynchronizationContext.SetSynchronizationContext(prev);
        sysW = new WaveFileWriter(sysPath, sys.WaveFormat);
        sys.DataAvailable += (s, e) => { if (sysW != null) sysW.Write(e.Buffer, 0, e.BytesRecorded); };
        sys.RecordingStopped += (s, e) => { if (sysW != null) { sysW.Dispose(); sysW = null; } sys.Dispose(); sysStopped.Set(); };
        sysStopped.Reset();
        sys.StartRecording();
        // Mic is best-effort: if it can't open, we still get system audio.
        try {
            mic.DeviceNumber = micDevice;
            mic.WaveFormat = new WaveFormat(16000, 16, 1);
            micW = new WaveFileWriter(micPath, mic.WaveFormat);
            mic.DataAvailable += (s, e) => { if (micW != null) micW.Write(e.Buffer, 0, e.BytesRecorded); };
            mic.RecordingStopped += (s, e) => { if (micW != null) { micW.Dispose(); micW = null; } mic.Dispose(); micStopped.Set(); };
            micStopped.Reset();
            mic.StartRecording();
            micOn = true;
        } catch {
            micOn = false;
            if (micW != null) { micW.Dispose(); micW = null; }
        }
    }
    public void Stop() {
        if (sys != null) sys.StopRecording();
        if (micOn && mic != null) mic.StopRecording();
        sysStopped.WaitOne(5000);
        if (micOn) micStopped.WaitOne(5000);
    }
}
public class MicRecorder {
    WaveInEvent wi;
    WaveFileWriter writer;
    ManualResetEvent stopped = new ManualResetEvent(false);
    public void Start(string path, int deviceNumber) {
        var prev = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);   // raise events on a bg thread, not the blocked UI thread
        wi = new WaveInEvent();
        SynchronizationContext.SetSynchronizationContext(prev);
        wi.DeviceNumber = deviceNumber;                 // pick the exact mic, not the room/camera
        wi.WaveFormat = new WaveFormat(16000, 16, 1);   // exactly what Whisper wants
        writer = new WaveFileWriter(path, wi.WaveFormat);
        wi.DataAvailable += (s, e) => { if (writer != null) writer.Write(e.Buffer, 0, e.BytesRecorded); };
        wi.RecordingStopped += (s, e) => {
            if (writer != null) { writer.Dispose(); writer = null; }
            if (wi != null) wi.Dispose();
            stopped.Set();
        };
        stopped.Reset();
        wi.StartRecording();
    }
    public void Stop() { if (wi != null) { wi.StopRecording(); stopped.WaitOne(5000); } }
}
"@
Add-Type -TypeDefinition $csRec -ReferencedAssemblies $naudioDll

# --- Native: audio cleanup (16 kHz mono + drop long silences that make Whisper loop) ---
$csPrep = @"
using System;
using System.Collections.Generic;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
public static class AudioPrep {
    public static void Clean(string inPath, string outPath) {
        using (var reader = new AudioFileReader(inPath)) {
            ISampleProvider sp = reader;
            if (sp.WaveFormat.Channels == 2) sp = new StereoToMonoSampleProvider(sp) { LeftVolume = 0.5f, RightVolume = 0.5f };
            var rs = new WdlResamplingSampleProvider(sp, 16000);
            float thr = 0.0075f;        // ~ -42 dB: below this counts as silence
            int maxSilent = 16000;      // keep at most ~1 s of contiguous near-silence
            float[] buf = new float[16000];
            int read; int silent = 0;
            using (var writer = new WaveFileWriter(outPath, new WaveFormat(16000, 16, 1))) {
                while ((read = rs.Read(buf, 0, buf.Length)) > 0) {
                    var keep = new List<short>(read);
                    for (int i = 0; i < read; i++) {
                        float s = buf[i];
                        if (Math.Abs(s) < thr) { silent++; if (silent > maxSilent) continue; }
                        else silent = 0;
                        int v = (int)(s * 32767f);
                        if (v > 32767) v = 32767; else if (v < -32768) v = -32768;
                        keep.Add((short)v);
                    }
                    if (keep.Count > 0) writer.WriteSamples(keep.ToArray(), 0, keep.Count);
                }
            }
        }
    }
}
public static class AudioMix {
    static ISampleProvider Mono16k(AudioFileReader r) {
        ISampleProvider sp = r;
        if (sp.WaveFormat.Channels == 2) sp = new StereoToMonoSampleProvider(sp) { LeftVolume = 0.5f, RightVolume = 0.5f };
        return new WdlResamplingSampleProvider(sp, 16000);
    }
    // Mix two recordings (system + mic) into one 16 kHz mono file. Streams, so memory stays low.
    public static void Mix(string aPath, string bPath, string outPath) {
        using (var ar = new AudioFileReader(aPath))
        using (var br = new AudioFileReader(bPath)) {
            var a = Mono16k(ar); var b = Mono16k(br);
            float[] ba = new float[16000], bb = new float[16000];
            using (var w = new WaveFileWriter(outPath, new WaveFormat(16000, 16, 1))) {
                while (true) {
                    int ra = a.Read(ba, 0, ba.Length);
                    int rb = b.Read(bb, 0, bb.Length);
                    int n = Math.Max(ra, rb);
                    if (n == 0) break;
                    var outBuf = new short[n];
                    for (int i = 0; i < n; i++) {
                        float s = 0f;
                        if (i < ra) s += ba[i];
                        if (i < rb) s += bb[i];
                        if (s > 1f) s = 1f; else if (s < -1f) s = -1f;
                        outBuf[i] = (short)(s * 32767f);
                    }
                    w.WriteSamples(outBuf, 0, n);
                }
            }
        }
    }
}
"@
Add-Type -TypeDefinition $csPrep -ReferencedAssemblies $naudioDll

# --- Native: Groq cloud transcription (OpenAI-compatible /audio/transcriptions) ---
$csCloud = @"
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
public static class Cloud {
    static string Post(string apiKey, string path, string model, string language, string responseFormat) {
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        using (var client = new HttpClient()) {
            client.Timeout = TimeSpan.FromSeconds(180);
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
            using (var form = new MultipartFormDataContent()) {
                var file = new ByteArrayContent(File.ReadAllBytes(path));
                file.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
                form.Add(file, "file", "audio.wav");
                form.Add(new StringContent(model), "model");
                if (!string.IsNullOrEmpty(language)) form.Add(new StringContent(language), "language");
                form.Add(new StringContent(responseFormat), "response_format");
                var resp = client.PostAsync("https://api.groq.com/openai/v1/audio/transcriptions", form).Result;
                string body = resp.Content.ReadAsStringAsync().Result;
                if (!resp.IsSuccessStatusCode) throw new Exception("Groq HTTP " + (int)resp.StatusCode + ": " + body);
                return body.Trim();
            }
        }
    }
    // Plain text (dictation).
    public static string Transcribe(string apiKey, string path, string model, string language) {
        return Post(apiKey, path, model, language, "text");
    }
    // JSON with per-segment timestamps (meetings).
    public static string TranscribeVerbose(string apiKey, string path, string model, string language) {
        return Post(apiKey, path, model, language, "verbose_json");
    }
}
"@
Add-Type -TypeDefinition $csCloud -ReferencedAssemblies System.Net.Http

# --- Model loading (selectable: base=fast, small=balanced, medium=accurate) ---
Import-Module $modulePsd 3>$null
# Auto-detect a real GPU (skip the software "Basic Render Driver"); fall back to the first adapter.
$adapter = @(Get-Adapters | Where-Object { $_ -notlike '*Basic Render*' })[0]
if (-not $adapter) { $adapter = @(Get-Adapters)[0] }
$modelCfg     = Join-Path $root 'diktatorn-model.txt'
$modelDir     = Join-Path $root 'Models'
$modelChoices = [ordered]@{ 'Snabb (base)' = 'ggml-base.bin'; 'Balanserad (small)' = 'ggml-small.bin'; 'Noggrann (medium)' = 'ggml-medium.bin' }
function Resolve-ModelFile {
    if (Test-Path $modelCfg) { $s = (Get-Content $modelCfg -Raw -ErrorAction SilentlyContinue).Trim(); if ($s -and (Test-Path (Join-Path $modelDir $s))) { return $s } }
    return 'ggml-small.bin'
}
# Prepare a real warmup clip (transcribing pure silence crashes the native lib).
Add-Type -AssemblyName System.Speech
$warm = Join-Path $env:TEMP 'diktatorn_warm.wav'
if (-not (Test-Path $warm)) {
    $sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $sp.SetOutputToWaveFile($warm); $sp.Speak('uppvarmning'); $sp.Dispose()
}
function Reload-Model([string]$file) {
    $script:model = Import-WhisperModel -path (Join-Path $modelDir $file) -adapter $adapter
    $script:modelFile = $file
    try { $null = Transcribe-File -model $script:model -path $warm -language $language } catch {}
}
$script:modelFile = Resolve-ModelFile
Reload-Model $script:modelFile

# --- Microphone selection ---
$script:micNames = @()
for ($i = 0; $i -lt [NAudio.Wave.WaveIn]::DeviceCount; $i++) {
    $script:micNames += [NAudio.Wave.WaveIn]::GetCapabilities($i).ProductName
}
function Resolve-MicDevice {
    $saved = $null
    if (Test-Path $micCfg) { $saved = (Get-Content $micCfg -Raw -ErrorAction SilentlyContinue).Trim() }
    if ($saved) { for ($i=0; $i -lt $script:micNames.Count; $i++) { if ($script:micNames[$i] -eq $saved) { return $i } } }
    for ($i=0; $i -lt $script:micNames.Count; $i++) { if ($script:micNames[$i] -like "*$preferMic*") { return $i } }
    return 0
}
$script:micDevice = Resolve-MicDevice
function Set-MicDevice([int]$idx) {
    $script:micDevice = $idx
    try { [System.IO.File]::WriteAllText($micCfg, $script:micNames[$idx]) } catch {}
    foreach ($it in $script:micMenuItems) { $it.Checked = ($it.Tag -eq $idx) }
}
function Set-Model([string]$file) {
    if ($script:dictating -or $script:meeting) { return }
    Set-Status 'byter modell...' $icoWork
    [System.Windows.Forms.Application]::DoEvents()
    Reload-Model $file
    try { [System.IO.File]::WriteAllText($modelCfg, $file) } catch {}
    foreach ($it in $script:modelMenuItems) { $it.Checked = ($it.Tag -eq $file) }
    Set-Status 'redo' $icoIdle
}

# --- Backend selection: local (GPU) vs Groq cloud ---
function Get-GroqKey {
    if ($env:GROQ_API_KEY) { return $env:GROQ_API_KEY }
    if (Test-Path $groqKeyFile) { $k = (Get-Content $groqKeyFile -Raw -ErrorAction SilentlyContinue).Trim(); if ($k) { return $k } }
    return $null
}
function Resolve-Backend {
    if (Test-Path $backendCfg) { $b = (Get-Content $backendCfg -Raw -ErrorAction SilentlyContinue).Trim(); if ($b -eq 'groq') { return 'groq' } }
    return 'local'
}
$script:backend = Resolve-Backend
function Set-Backend([string]$b) {
    if ($b -eq 'groq' -and -not (Get-GroqKey)) {
        $tray.ShowBalloonTip(4000, 'Diktatorn', 'Ingen Groq-nyckel. Hogerklicka -> Ange Groq API-nyckel.', 'Warning')
    }
    $script:backend = $b
    try { [System.IO.File]::WriteAllText($backendCfg, $b) } catch {}
    foreach ($it in $script:backendMenuItems) { $it.Checked = ($it.Tag -eq $b) }
}

# --- Tray ---
function New-DotIcon([System.Drawing.Color]$c) {
    $bmp = New-Object System.Drawing.Bitmap 16,16
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $br = New-Object System.Drawing.SolidBrush $c; $g.FillEllipse($br, 2, 2, 12, 12); $g.Dispose(); $br.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icoIdle = New-DotIcon ([System.Drawing.Color]::FromArgb(80,160,80))
$icoRec  = New-DotIcon ([System.Drawing.Color]::FromArgb(210,60,60))
$icoWork = New-DotIcon ([System.Drawing.Color]::FromArgb(230,180,40))
$icoMeet = New-DotIcon ([System.Drawing.Color]::FromArgb(70,120,210))

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icoIdle; $tray.Text = 'Diktatorn - redo'; $tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miInfo = $menu.Items.Add('Hall Ctrl+Shift = diktera  |  Ctrl+Shift+D = toggel'); $miInfo.Enabled = $false
$miStats = $menu.Items.Add('Talhastighet: - '); $miStats.Enabled = $false
[void]$menu.Items.Add('-')
$miMeeting = $menu.Items.Add('Starta motesinspelning (Ctrl+Shift+M)')
[void]$menu.Items.Add('-')
$miMic = New-Object System.Windows.Forms.ToolStripMenuItem 'Mikrofon (diktering)'
$script:micMenuItems = @()
for ($i = 0; $i -lt $script:micNames.Count; $i++) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $script:micNames[$i]
    $item.Tag = $i
    $item.Checked = ($i -eq $script:micDevice)
    $item.add_Click({ Set-MicDevice ([int]$this.Tag) })
    [void]$miMic.DropDownItems.Add($item)
    $script:micMenuItems += $item
}
[void]$menu.Items.Add($miMic)
$miModel = New-Object System.Windows.Forms.ToolStripMenuItem 'Modell (snabbhet vs noggrannhet)'
$script:modelMenuItems = @()
foreach ($label in $modelChoices.Keys) {
    $file = $modelChoices[$label]
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
    $item.Tag = $file
    $item.Checked = ($file -eq $script:modelFile)
    $item.add_Click({ Set-Model ([string]$this.Tag) })
    [void]$miModel.DropDownItems.Add($item)
    $script:modelMenuItems += $item
}
[void]$menu.Items.Add($miModel)
$miBackend = New-Object System.Windows.Forms.ToolStripMenuItem 'Transkribering (lokal / moln)'
$script:backendMenuItems = @()
foreach ($b in @(@{t='local'; l='Lokal (GPU, privat)'}, @{t='groq'; l='Groq moln (snabbt)'})) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $b.l
    $item.Tag = $b.t
    $item.Checked = ($b.t -eq $script:backend)
    $item.add_Click({ Set-Backend ([string]$this.Tag) })
    [void]$miBackend.DropDownItems.Add($item)
    $script:backendMenuItems += $item
}
[void]$menu.Items.Add($miBackend)
$miKey = $menu.Items.Add('Ange Groq API-nyckel...')
$miKey.add_Click({
    Add-Type -AssemblyName Microsoft.VisualBasic
    $cur = Get-GroqKey
    $val = [Microsoft.VisualBasic.Interaction]::InputBox('Klistra in din Groq API-nyckel (gsk_...):', 'Groq API-nyckel', $cur)
    if ($val) { try { [System.IO.File]::WriteAllText($groqKeyFile, $val.Trim()); $tray.ShowBalloonTip(2500, 'Diktatorn', 'Groq-nyckel sparad.', 'Info') } catch {} }
})
[void]$menu.Items.Add('-')
$miQuit = $menu.Items.Add('Avsluta')
$tray.ContextMenuStrip = $menu

function Set-Status([string]$txt, $icon) { $tray.Text = ('Diktatorn - ' + $txt); $tray.Icon = $icon }

# --- Shared transcription ---
# $lang = '' (or $null) means auto-detect (WhisperPS auto-detects when -language is omitted).
function Get-Transcript([string]$wav, [string]$lang = $language) {
    if (-not (Test-Path $wav) -or (Get-Item $wav).Length -lt 2048) { return $null }
    if ($lang) { Transcribe-File -model $script:model -path $wav -language $lang }
    else { Transcribe-File -model $script:model -path $wav }
}
# Returns plain transcript text, dispatching to the selected backend.
function Get-TranscriptText([string]$wav) {
    if (-not (Test-Path $wav) -or (Get-Item $wav).Length -lt 2048) { return $null }
    if ($script:backend -eq 'groq') {
        $key = Get-GroqKey
        if (-not $key) { $tray.ShowBalloonTip(4000, 'Diktatorn', 'Ingen Groq-nyckel angiven.', 'Warning'); return $null }
        return ([Cloud]::Transcribe($key, $wav, $groqModel, $language)).Trim()
    }
    $seg = Transcribe-File -model $script:model -path $wav -language $language
    return ((($seg | ForEach-Object { $_.Text }) -join ' ').Trim()) -replace '\s+', ' '
}

# --- Speaking-rate stats ---
function Get-WavSeconds([string]$path) {
    try { $r = New-Object NAudio.Wave.WaveFileReader($path); $s = $r.TotalTime.TotalSeconds; $r.Dispose(); return $s } catch { return 0 }
}
$script:statChars = 0; $script:statSecs = 0.0; $script:statCount = 0
function Update-Stats([string]$text, [double]$secs) {
    if ($secs -lt 0.3 -or -not $text) { return }
    $chars = $text.Length
    $script:statChars += $chars; $script:statSecs += $secs; $script:statCount++
    $cpm = [math]::Round($chars / ($secs / 60))
    $wpm = [math]::Round(($text -split '\s+').Count / ($secs / 60))
    $avg = [math]::Round($script:statChars / ($script:statSecs / 60))
    $miStats.Text = "Talhastighet: $cpm tkn/min (~$wpm ord/min)  |  snitt $avg over $($script:statCount) st"
}

# --- Dictation (mic via NAudio, 16 kHz/16-bit/mono) ---
$script:dictating = $false
$script:micRec = New-Object MicRecorder
function Start-Dictation {
    $script:dictating = $true
    Set-Status 'SPELAR IN (diktering)...' $icoRec
    Remove-Item $tmpDict -ErrorAction SilentlyContinue
    $script:micRec.Start($tmpDict, $script:micDevice)
}
function Stop-Dictation {
    $script:dictating = $false
    Set-Status 'transkriberar...' $icoWork
    $script:micRec.Stop()
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $secs = Get-WavSeconds $tmpDict
        $text = Get-TranscriptText $tmpDict
        if ($text) {
            Start-Sleep -Milliseconds 40; [WfNative]::TypeText($text + ' ')
            Update-Stats $text $secs
        }
    } catch { $tray.ShowBalloonTip(3000, 'Diktatorn', "Fel: $($_.Exception.Message)", 'Error') }
    finally { Set-Status 'redo' $icoIdle }
}

# --- Meeting (system audio via WASAPI loopback) ---
$script:meeting  = $false
$script:meetRec  = New-Object MeetingRecorder
function Start-Meeting {
    if ($script:dictating) { return }
    $script:meeting = $true
    $miMeeting.Text = 'Stoppa motesinspelning (Ctrl+Shift+M)'
    Set-Status 'SPELAR IN MOTE (datorljud + mick)...' $icoMeet
    Remove-Item $tmpMeet, $tmpMeetMic, $tmpMeetMixed -ErrorAction SilentlyContinue
    $script:meetRec.Start($tmpMeet, $tmpMeetMic, $script:micDevice)
    $tray.ShowBalloonTip(2500, 'Diktatorn', 'Motesinspelning startad (datorljud + din mick).', 'Info')
}
function Stop-Meeting {
    $script:meeting = $false
    $miMeeting.Text = 'Starta motesinspelning (Ctrl+Shift+M)'
    Set-Status 'transkriberar mote...' $icoWork
    $script:meetRec.Stop()
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $sysOk = (Test-Path $tmpMeet) -and ((Get-Item $tmpMeet).Length -gt 2048)
        $micOk = $script:meetRec.MicCaptured -and (Test-Path $tmpMeetMic) -and ((Get-Item $tmpMeetMic).Length -gt 2048)
        if (-not $sysOk -and -not $micOk) {
            $tray.ShowBalloonTip(3000, 'Diktatorn', 'Inget ljud fangades.', 'Warning'); return
        }
        # Combine mic (you) + system (others), then clean: 16 kHz mono + drop long silences.
        $src = $tmpMeet
        try {
            if ($sysOk -and $micOk) { [AudioMix]::Mix($tmpMeet, $tmpMeetMic, $tmpMeetMixed); $combined = $tmpMeetMixed }
            elseif ($micOk) { $combined = $tmpMeetMic }
            else { $combined = $tmpMeet }
            [AudioPrep]::Clean($combined, $tmpMeetClean)
            $src = if ((Test-Path $tmpMeetClean) -and ((Get-Item $tmpMeetClean).Length -gt 2048)) { $tmpMeetClean } else { $combined }
        } catch { $src = $tmpMeet }
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
        $outFile = Join-Path $outDir "Mote_$stamp.txt"
        if ($script:backend -eq 'groq') {
            $key = Get-GroqKey
            if (-not $key) { $tray.ShowBalloonTip(4000, 'Diktatorn', 'Ingen Groq-nyckel angiven.', 'Warning'); return }
            $json = [Cloud]::TranscribeVerbose($key, $src, $groqModel, '')   # '' = auto-detect (sv/en)
            $obj = $json | ConvertFrom-Json
            if ($obj.segments) {
                $lines = $obj.segments | ForEach-Object { '[{0}] {1}' -f ([TimeSpan]::FromSeconds([double]$_.start).ToString('hh\:mm\:ss')), ($_.text).Trim() }
                [System.IO.File]::WriteAllText($outFile, ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($true))
            } elseif ($obj.text) {
                [System.IO.File]::WriteAllText($outFile, $obj.text.Trim(), [System.Text.UTF8Encoding]::new($true))
            } else { return }
        } else {
            $seg = Get-Transcript $src ''   # '' = auto-detect (sv/en)
            if (-not $seg) { $tray.ShowBalloonTip(3000, 'Diktatorn', 'Inget ljud fangades.', 'Warning'); return }
            $seg | Export-Text -path $outFile -timestamps
        }
        $tray.ShowBalloonTip(3000, 'Diktatorn', "Mote transkriberat: $([System.IO.Path]::GetFileName($outFile))", 'Info')
        Invoke-Item $outFile
    } catch { $tray.ShowBalloonTip(4000, 'Diktatorn', "Fel: $($_.Exception.Message)", 'Error') }
    finally { Set-Status 'redo' $icoIdle }
}

# --- Hotkeys: 1 = dictation toggle (Ctrl+Shift+D), 2 = meeting toggle (Ctrl+Shift+M) ---
$hk = New-Object WfNative
[void]$hk.Register(1, [uint32]6, [uint32]0x44)   # Ctrl+Shift+D
[void]$hk.Register(2, [uint32]6, [uint32]0x4D)   # Ctrl+Shift+M
$script:pttSuppressed = $false
$hk.add_HotkeyPressed({
    param($id)
    $script:pttSuppressed = $true   # a combo with a letter fired; block push-to-talk until modifiers released
    if ($id -eq 1) { if (-not $script:meeting) { if ($script:dictating) { Stop-Dictation } else { Start-Dictation } } }
    elseif ($id -eq 2) { if ($script:meeting) { Stop-Meeting } else { Start-Meeting } }
})

# --- Push-to-talk: poll Ctrl+Shift held (no other letter) for >threshold ---
$VK_SHIFT = 0x10; $VK_CONTROL = 0x11
$script:pttActive = $false
$script:pttCandidateTick = 0
$pttDelayMs = 250
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 40
$timer.add_Tick({
    $both = ([WfNative]::IsDown($VK_CONTROL)) -and ([WfNative]::IsDown($VK_SHIFT))
    if ($both) {
        if ($script:meeting -or $script:pttSuppressed) { return }
        if ($script:pttActive) { return }
        if (-not $script:dictating) {
            if ($script:pttCandidateTick -eq 0) { $script:pttCandidateTick = [Environment]::TickCount }
            elseif (([Environment]::TickCount - $script:pttCandidateTick) -ge $pttDelayMs) {
                $script:pttActive = $true
                Start-Dictation
            }
        }
    } else {
        $script:pttSuppressed = $false
        $script:pttCandidateTick = 0
        if ($script:pttActive) {
            $script:pttActive = $false
            Stop-Dictation
        }
    }
})
$timer.Start()

# --- Lifecycle ---
$appContext = New-Object System.Windows.Forms.ApplicationContext
$miMeeting.add_Click({ if ($script:meeting) { Stop-Meeting } else { Start-Meeting } })
$miQuit.add_Click({
    try { $timer.Stop() } catch {}
    try { if ($script:meeting) { $script:meetRec.Stop() } } catch {}
    try { if ($script:dictating) { $script:micRec.Stop() } } catch {}
    $hk.Dispose(); $tray.Visible = $false; $appContext.ExitThread()
})

$tray.ShowBalloonTip(2500, 'Diktatorn', 'Redo. Hall Ctrl+Shift for att diktera, Ctrl+Shift+M for mote.', 'Info')
[System.Windows.Forms.Application]::Run($appContext)
