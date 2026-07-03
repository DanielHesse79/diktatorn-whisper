# Diktatorn  -  global dictation + meeting transcription for Const-me Whisper
#
#   DICTATION (types text at the cursor in any app):
#     * Hold Ctrl+Shift  (push-to-talk): speak, release -> text is typed.
#     * Ctrl+Shift+D     (toggle):       press to start, press again to stop.
#   MEETING (records system audio = the others, and your mic = you):
#     * Ctrl+Shift+M  or tray menu: start; press again to stop.
#       Continuous: both streams are rotated into 30 s chunks that are transcribed
#       DURING the meeting with speaker labels (Du = mic, Ovriga = system audio).
#       The transcript file grows live; talk-time stats are appended at the end.
#
# Runs in the system tray. No window steals focus, so dictated text lands in the active app.

$ErrorActionPreference = 'Stop'

# --- Single instance: a second copy would fight over the global hotkeys ---
try {
    $script:singleton = New-Object System.Threading.Mutex($false, 'DiktatornSingleton')
    if (-not $script:singleton.WaitOne(0)) { exit }
} catch [System.Threading.AbandonedMutexException] { }   # previous instance died holding it: we own it now

$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePsd = Join-Path $root 'WhisperPS\WhisperPS\WhisperPS.psd1'
$naudioDll = Join-Path $root 'lib\NAudio.dll'
$adapter   = $null   # GPU adapter, auto-detected after the WhisperPS module loads
$language  = 'sv'    # dictation language (meetings auto-detect)
$chunkSec  = if ($env:DIKTATORN_CHUNK_SEC) { [int]$env:DIKTATORN_CHUNK_SEC } else { 30 }   # meeting chunk length (30 s = Whisper's native window)
$outDir    = Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) 'Transcriptions'
$tmpDict   = Join-Path $env:TEMP 'whisprflow_dict.wav'
$logFile   = Join-Path $env:TEMP 'diktatorn.log'
$micCfg    = Join-Path $root 'diktatorn-mic.txt'   # remembers which microphone to use
$preferMic = 'USB PnP Sound Device'                # default mic (substring match), not the room/camera
$backendCfg = Join-Path $root 'diktatorn-backend.txt'   # 'local' or 'groq'
$groqKeyFile = Join-Path $root 'diktatorn-groq.txt'     # Groq API key (plaintext, local only)
$groqModel  = 'whisper-large-v3-turbo'
New-Item -ItemType Directory -Force $outDir | Out-Null
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Talanalys (private speech analysis; only YOUR mic lines are ever analyzed) ---
$talanalysCfg = Join-Path $root 'diktatorn-talanalys.txt'   # 'off' | 'stats' | 'coach'
$coachModel   = 'llama-3.3-70b-versatile'                   # Groq LLM (same free API key)
$trendCsv     = Join-Path $outDir 'talanalys-trend.csv'
# Crocodile warning (big mouth, small ears): rolling-window talk-share alert during meetings.
$crocWinSec      = if ($env:DIKTATORN_CROC_WIN_SEC)      { [int]$env:DIKTATORN_CROC_WIN_SEC }      else { 600 }
$crocPct         = if ($env:DIKTATORN_CROC_PCT)          { [int]$env:DIKTATORN_CROC_PCT }          else { 70 }
$crocMinSpeech   = if ($env:DIKTATORN_CROC_MIN_SPEECH)   { [int]$env:DIKTATORN_CROC_MIN_SPEECH }   else { 120 }
$crocCooldownSec = if ($env:DIKTATORN_CROC_COOLDOWN_SEC) { [int]$env:DIKTATORN_CROC_COOLDOWN_SEC } else { 600 }
# Verbatim bias prompt: makes Whisper KEEP filler words in the analysis pass (never shown in the transcript).
$sw_a = [string][char]229; $sw_o = [string][char]246   # a-ring / o-umlaut (source file stays ASCII)
$verbatimPrompt = "Eh, ${sw_o}h, ehm, hmm, um, uh, allts${sw_a}, ass${sw_a}, typ, liksom, ba, you know, s${sw_a} att, ju."
$fillerPatterns = [ordered]@{
    'eh'                = '\be+h+m?\b'
    (${sw_o} + 'h')     = ('\b' + ${sw_o} + '+h+m?\b')
    'um/uh/hmm'         = '\b(um+|uh+|hm+)\b'
    ('allts' + ${sw_a}) = ('\b(allts' + ${sw_a} + '|ass' + ${sw_a} + ')\b')
    'typ'               = '\btyp\b'
    'liksom'            = '\bliksom\b'
    'ba'                = '\bba\b'
    'you know'          = '\byou know\b'
}

function Write-Log([string]$msg) {
    try { Add-Content -Path $logFile -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) } catch {}
}

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
    // Records system audio (loopback = the others) and the mic (you) as SEPARATE streams,
    // rotated into chunk files (chunk_NNNN_sys.wav / chunk_NNNN_mic.wav). Separate streams =
    // we know who spoke: mic = you, loopback = everyone else. Rotation runs on the recorder's
    // OWN threadpool timer (not the UI thread), so chunk i always covers wall-time
    // [i*chunkSec, (i+1)*chunkSec) with exact timestamps even if PS-side transcription lags
    // or loopback goes silent. Every writer touch is exception-guarded; a stream dying
    // mid-meeting sets a *Faulted flag the PS side can surface instead of failing silently.
    WasapiLoopbackCapture sys;
    WaveInEvent mic;
    WaveFileWriter sysW, micW;
    readonly object sysLock = new object();
    readonly object micLock = new object();
    ManualResetEvent sysStopped = new ManualResetEvent(false);
    ManualResetEvent micStopped = new ManualResetEvent(false);
    Timer rotator;
    string dir;
    int index = 0;
    int chunkMs;
    volatile bool micOn = false, running = false, sysFaulted = false, micFaulted = false;
    public bool MicCaptured { get { return micOn; } }
    public bool SysFaulted { get { return sysFaulted; } }
    public bool MicFaulted { get { return micFaulted; } }
    public int ChunkIndex { get { lock (sysLock) { return index; } } }   // chunks 0..index-1 final; after Stop(), chunk `index` too
    string SysPath(int i) { return System.IO.Path.Combine(dir, "chunk_" + i.ToString("D4") + "_sys.wav"); }
    string MicPath(int i) { return System.IO.Path.Combine(dir, "chunk_" + i.ToString("D4") + "_mic.wav"); }
    static void SafeDispose(WaveFileWriter w) { if (w != null) { try { w.Dispose(); } catch { } } }

    public void Start(string chunkDir, int micDevice, int chunkSeconds) {
        dir = chunkDir; index = 0; chunkMs = chunkSeconds * 1000; running = true;
        sysFaulted = false; micFaulted = false;
        var prev = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);   // events on a bg thread, not the blocked UI thread
        sys = new WasapiLoopbackCapture();
        mic = new WaveInEvent();
        SynchronizationContext.SetSynchronizationContext(prev);
        sysW = new WaveFileWriter(SysPath(0), sys.WaveFormat);
        sys.DataAvailable += (s, e) => { lock (sysLock) { if (sysW != null) { try { sysW.Write(e.Buffer, 0, e.BytesRecorded); } catch { } } } };
        sys.RecordingStopped += (s, e) => { if (e != null && e.Exception != null) sysFaulted = true; lock (sysLock) { SafeDispose(sysW); sysW = null; } try { sys.Dispose(); } catch { } sysStopped.Set(); };
        sysStopped.Reset();
        sys.StartRecording();
        // Mic is best-effort: if it can't open we still get system audio.
        try {
            mic.DeviceNumber = micDevice;
            mic.WaveFormat = new WaveFormat(16000, 16, 1);
            micW = new WaveFileWriter(MicPath(0), mic.WaveFormat);
            mic.DataAvailable += (s, e) => { lock (micLock) { if (micW != null) { try { micW.Write(e.Buffer, 0, e.BytesRecorded); } catch { } } } };
            mic.RecordingStopped += (s, e) => { if (e != null && e.Exception != null) micFaulted = true; lock (micLock) { SafeDispose(micW); micW = null; } try { mic.Dispose(); } catch { } micStopped.Set(); };
            micStopped.Reset();
            mic.StartRecording();
            micOn = true;
        } catch {
            micOn = false; micFaulted = true;
            lock (micLock) { SafeDispose(micW); micW = null; }
            micStopped.Set();
        }
        rotator = new Timer(delegate { Rotate(); }, null, chunkMs, chunkMs);
    }

    void Rotate() {
        if (!running) return;
        int next;
        lock (sysLock) {
            if (!running) return;
            next = index + 1;
            SafeDispose(sysW); sysW = null;                       // finalize the just-closed chunk
            try { sysW = new WaveFileWriter(SysPath(next), sys.WaveFormat); } catch { sysFaulted = true; }
        }
        if (micOn) {
            lock (micLock) {
                SafeDispose(micW); micW = null;
                try { micW = new WaveFileWriter(MicPath(next), mic.WaveFormat); } catch { micFaulted = true; }
            }
        }
        lock (sysLock) { index = next; }                         // publish only after both writers rotated
    }

    public void Stop() {
        running = false;
        if (rotator != null) {
            var wh = new ManualResetEvent(false);
            try { rotator.Dispose(wh); wh.WaitOne(2000); } catch { }   // wait out any in-flight Rotate
            rotator = null;
        }
        try { if (sys != null) sys.StopRecording(); } catch { }
        try { if (micOn && mic != null) mic.StopRecording(); } catch { }
        sysStopped.WaitOne(5000);
        if (micOn) micStopped.WaitOne(5000);
        // Finalize the last chunk's writers in case RecordingStopped already fired (spontaneous death) or never runs.
        lock (sysLock) { SafeDispose(sysW); sysW = null; }
        lock (micLock) { SafeDispose(micW); micW = null; }
    }
}
public class MicRecorder {
    WaveInEvent wi;
    WaveFileWriter writer;
    readonly object wLock = new object();
    ManualResetEvent stopped = new ManualResetEvent(false);
    // Returns false if the device could not be opened (leaves nothing leaked/locked).
    public bool Start(string path, int deviceNumber) {
        var prev = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);   // raise events on a bg thread, not the blocked UI thread
        wi = new WaveInEvent();
        SynchronizationContext.SetSynchronizationContext(prev);
        wi.DeviceNumber = deviceNumber;                 // pick the exact mic, not the room/camera
        wi.WaveFormat = new WaveFormat(16000, 16, 1);   // exactly what Whisper wants
        writer = new WaveFileWriter(path, wi.WaveFormat);
        wi.DataAvailable += (s, e) => { lock (wLock) { if (writer != null) { try { writer.Write(e.Buffer, 0, e.BytesRecorded); } catch { } } } };
        wi.RecordingStopped += (s, e) => { lock (wLock) { if (writer != null) { try { writer.Dispose(); } catch { } writer = null; } } if (wi != null) wi.Dispose(); stopped.Set(); };
        stopped.Reset();
        try {
            wi.StartRecording();
            return true;
        } catch {
            // StartRecording threw (bad/busy device): dispose the open writer so the temp file isn't left locked.
            lock (wLock) { if (writer != null) { try { writer.Dispose(); } catch { } writer = null; } }
            try { wi.Dispose(); } catch { }
            wi = null;
            stopped.Set();
            return false;
        }
    }
    public void Stop() { if (wi != null) { try { wi.StopRecording(); } catch { } stopped.WaitOne(5000); } }
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
    static string Post(string apiKey, string path, string model, string language, string responseFormat, string prompt) {
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
                if (!string.IsNullOrEmpty(prompt)) form.Add(new StringContent(prompt, System.Text.Encoding.UTF8), "prompt");
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
        return Post(apiKey, path, model, language, "text", null);
    }
    // Plain text with a bias prompt (verbatim analysis pass keeps filler words).
    public static string TranscribeWithPrompt(string apiKey, string path, string model, string language, string prompt) {
        return Post(apiKey, path, model, language, "text", prompt);
    }
    // JSON with per-segment timestamps (meetings).
    public static string TranscribeVerbose(string apiKey, string path, string model, string language) {
        return Post(apiKey, path, model, language, "verbose_json", null);
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

# --- Talanalys mode: off | stats (local counters + live warning) | coach (+ Groq LLM report) ---
function Resolve-Talanalys {
    if (Test-Path $talanalysCfg) {
        $t = (Get-Content $talanalysCfg -Raw -ErrorAction SilentlyContinue).Trim()
        if ($t -in @('stats', 'coach')) { return $t }
    }
    return 'off'
}
$script:talanalys = Resolve-Talanalys
function Set-Talanalys([string]$t) {
    if ($t -eq 'coach' -and -not (Get-GroqKey)) {
        $tray.ShowBalloonTip(4000, 'Diktatorn', 'AI-coachen behover en Groq-nyckel. Hogerklicka -> Ange Groq API-nyckel.', 'Warning')
    }
    $script:talanalys = $t
    try { [System.IO.File]::WriteAllText($talanalysCfg, $t) } catch {}
    foreach ($it in $script:talanalysMenuItems) { $it.Checked = ($it.Tag -eq $t) }
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
$miOpenLive = $menu.Items.Add('Visa transkript (live)')
$miOpenLive.Enabled = $false
$miOpenLive.add_Click({ if ($script:meetOutFile -and (Test-Path $script:meetOutFile)) { Invoke-Item $script:meetOutFile } })
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
$miTal = New-Object System.Windows.Forms.ToolStripMenuItem 'Talanalys (privat, bara du)'
$script:talanalysMenuItems = @()
foreach ($t in @(
    @{t='off';   l='Av'},
    @{t='stats'; l='Statistik + krokodilvarning'},
    @{t='coach'; l='Statistik + AI-coach (Groq)'}
)) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $t.l
    $item.Tag = $t.t
    $item.Checked = ($t.t -eq $script:talanalys)
    $item.add_Click({ Set-Talanalys ([string]$this.Tag) })
    [void]$miTal.DropDownItems.Add($item)
    $script:talanalysMenuItems += $item
}
[void]$menu.Items.Add($miTal)
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
    Remove-Item $tmpDict -ErrorAction SilentlyContinue
    if (-not $script:micRec.Start($tmpDict, $script:micDevice)) {
        Write-Log 'Start-Dictation: mic could not be opened'
        $tray.ShowBalloonTip(3000, 'Diktatorn', 'Mikrofonen kunde inte oppnas. Valj en annan mick i menyn.', 'Warning')
        return $false
    }
    $script:dictating = $true
    Set-Status 'SPELAR IN (diktering)...' $icoRec
    return $true
}
function Cancel-Dictation {
    # Abort an in-progress dictation without transcribing/typing (e.g. a stray PTT before a meeting).
    $script:dictating = $false; $script:pttActive = $false
    try { $script:micRec.Stop() } catch {}
    Set-Status 'redo' $icoIdle
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
    } catch {
        Write-Log "Stop-Dictation: $($_.Exception.Message)"
        $tray.ShowBalloonTip(3000, 'Diktatorn', "Fel: $($_.Exception.Message)", 'Error')
    }
    finally { Set-Status 'redo' $icoIdle }
}

# --- Meeting: chunked dual-stream -> continuous labeled transcript + talk-time stats ---
# Mic chunks = you ("Du"), loopback chunks = everyone else ("Ovriga"). No ML diarization
# needed: the label IS the stream the audio came from.
$script:meeting  = $false
$script:meetRec  = $null
$labelYou    = 'Du'
$labelOthers = [string][char]214 + 'vriga'   # "Ovriga" with a proper capital O-umlaut in output

# Transcribe one chunk file: clean -> silence/size gate -> backend -> text + voiced seconds.
# Returns $null for a legitimately SILENT chunk (safe to drop). THROWS on a transcription
# error (bad key, HTTP failure, native crash) so the caller keeps the audio for recovery.
function Get-ChunkText([string]$wav) {
    if (-not (Test-Path $wav) -or ((Get-Item $wav).Length -lt 8192)) { return $null }   # no/negligible audio
    $clean = Join-Path $script:meetDir 'clean.wav'
    [AudioPrep]::Clean($wav, $clean)                                                    # throws -> caller preserves audio
    if (-not (Test-Path $clean) -or ((Get-Item $clean).Length -lt 16000)) { return $null }   # <0.5 s voiced = silence
    $secs = Get-WavSeconds $clean
    if ($script:backend -eq 'groq') {
        $key = Get-GroqKey
        if (-not $key) { throw 'Ingen Groq-nyckel' }
        $text = ([Cloud]::Transcribe($key, $clean, $groqModel, '')).Trim()   # '' = auto-detect sv/en
    } else {
        $seg = Get-Transcript $clean ''
        $text = ((($seg | ForEach-Object { $_.Text }) -join ' ').Trim()) -replace '\s+', ' '
    }
    if (-not $text -or $text -match '^[\s\.\-\!\?]*$') { return $null }
    @{ text = $text; secs = $secs }
}

# --- Talanalys helpers (only ever fed YOUR mic audio/lines, never the others') ---
# Verbatim pass: re-transcribe the already-cleaned mic chunk with a filler-bias prompt.
# The result is ONLY used for counting; the visible transcript stays clean.
function Get-VerbatimText([string]$cleanWav) {
    try {
        if ($script:backend -eq 'groq') {
            $key = Get-GroqKey
            if (-not $key) { return $null }
            return ([Cloud]::TranscribeWithPrompt($key, $cleanWav, $groqModel, '', $verbatimPrompt)).Trim()
        }
        $seg = Transcribe-File -model $script:model -path $cleanWav -prompt $verbatimPrompt
        return ((($seg | ForEach-Object { $_.Text }) -join ' ').Trim())
    } catch { Write-Log "verbatim: $($_.Exception.Message)"; return $null }
}
function Count-Fillers([string]$text) {
    if (-not $text) { return }
    foreach ($name in $fillerPatterns.Keys) {
        $n = [regex]::Matches($text, $fillerPatterns[$name], 'IgnoreCase').Count
        if ($n -gt 0) {
            if ($script:meetFillers.ContainsKey($name)) { $script:meetFillers[$name] += $n } else { $script:meetFillers[$name] = $n }
        }
    }
}
# Trend: one CSV row per meeting -> your progress over time (local file, private).
function Get-TrendPrev {
    if (-not (Test-Path $trendCsv)) { return $null }
    $rows = @(Get-Content $trendCsv | Select-Object -Skip 1 | Where-Object { $_ } | Select-Object -Last 5)
    if ($rows.Count -eq 0) { return $null }
    $sh = @(); $fi = @()
    foreach ($r in $rows) { $c = $r -split ';'; if ($c.Count -ge 4) { $sh += [double]$c[2]; $fi += [double]$c[3] } }
    if ($sh.Count -eq 0) { return $null }
    @{ n = $sh.Count
       share = [math]::Round(($sh | Measure-Object -Average).Average)
       fill  = [math]::Round(($fi | Measure-Object -Average).Average, 1) }
}
function Add-TrendRow([int]$mins, [int]$sharePct, [double]$fillPerMin, [int]$questions, [double]$monologMin) {
    try {
        if (-not (Test-Path $trendCsv)) {
            [System.IO.File]::WriteAllText($trendCsv, "datum;minuter;talandel_pct;utfyllnad_per_min;fragor;langsta_monolog_min`r`n", [System.Text.UTF8Encoding]::new($true))
        }
        $row = ('{0};{1};{2};{3};{4};{5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $mins, $sharePct,
            $fillPerMin.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture), $questions,
            $monologMin.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture))
        Add-Content -Path $trendCsv -Value $row
    } catch { Write-Log "trend: $($_.Exception.Message)" }
}
# AI coach: gets ONLY your lines + your stats. Decodes the response explicitly as UTF-8
# (PS 5.1 Invoke-RestMethod mis-decodes JSON bodies as Latin-1).
function Get-CoachReport([string]$youText, [string]$statsSummary) {
    $key = Get-GroqKey
    if (-not $key -or -not $youText) { return $null }
    if ($youText.Length -gt 12000) { $youText = $youText.Substring(0, 4000) + ' [...] ' + $youText.Substring($youText.Length - 8000) }
    $sys = 'You are an experienced, direct but friendly sales/communication coach. You receive ONLY the user''s own lines from a meeting (the other side is intentionally excluded) plus speech statistics. Reply in SWEDISH: 3-5 short, concrete coaching points (listening vs talking, questions asked, filler words, one specific exercise for next meeting). No preamble. Max 130 words.'
    $body = @{ model = $coachModel; temperature = 0.4; max_tokens = 400; messages = @(
        @{ role = 'system'; content = $sys },
        @{ role = 'user'; content = "STATISTIK:`n$statsSummary`n`nMINA REPLIKER:`n$youText" }
    ) } | ConvertTo-Json -Depth 5
    $resp = Invoke-WebRequest -UseBasicParsing -Uri 'https://api.groq.com/openai/v1/chat/completions' -Method Post `
        -Headers @{ Authorization = "Bearer $key" } -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    $json = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    return $json.choices[0].message.content.Trim()
}

# Process finished chunk pairs [meetProcessed, upTo): transcribe each stream independently,
# label (Du/Ovriga), accumulate stats. A stream is deleted ONLY once transcribed or confirmed
# silent; on a transcription error its audio is KEPT (meetFailed=$true) so nothing is lost.
function Process-ReadyChunks([int]$upTo) {
    while ($script:meetProcessed -lt $upTo) {
        $i = $script:meetProcessed
        $ts = [TimeSpan]::FromSeconds($i * $chunkSec).ToString('hh\:mm\:ss')
        $any = $false
        $chunkYou = 0.0; $chunkOthers = 0.0
        foreach ($stream in @(
            @{ wav = (Join-Path $script:meetDir ('chunk_{0:D4}_sys.wav' -f $i)); label = $labelOthers; you = $false },
            @{ wav = (Join-Path $script:meetDir ('chunk_{0:D4}_mic.wav' -f $i)); label = $labelYou;    you = $true  }
        )) {
            try {
                $r = Get-ChunkText $stream.wav
                if ($r) {
                    $script:meetLines.Add("[$ts] $($stream.label): $($r.text)")
                    if ($stream.you) {
                        $script:meetSecsYou += $r.secs; $script:meetWordsYou += ($r.text -split '\s+').Count
                        $chunkYou = $r.secs
                        if ($script:meetAnalysis -ne 'off') {
                            # Private analysis pass: your questions + a verbatim re-take for filler words.
                            $script:meetQuestions += ([regex]::Matches($r.text, '\?')).Count
                            $v = Get-VerbatimText (Join-Path $script:meetDir 'clean.wav')   # clean.wav = this mic chunk
                            Count-Fillers ($(if ($v) { $v } else { $r.text }))
                        }
                    }
                    else { $script:meetSecsOthers += $r.secs; $script:meetWordsOthers += ($r.text -split '\s+').Count; $chunkOthers = $r.secs }
                    $any = $true
                }
                Remove-Item $stream.wav -ErrorAction SilentlyContinue   # transcribed or silent -> safe to drop
            } catch {
                $script:meetFailed = $true
                Write-Log "chunk ${i} ($($stream.label)): $($_.Exception.Message)"   # keep the audio (not deleted)
            }
        }
        $script:chunkListYou.Add($chunkYou); $script:chunkListOthers.Add($chunkOthers)   # rolling window + monolog data
        $script:meetProcessed++
        if ($any) { Save-LiveTranscript }
    }
}

function Save-LiveTranscript([switch]$final) {
    $body = New-Object 'System.Collections.Generic.List[string]'
    $body.Add("Mote $($script:meetStamp)  (${labelYou} = din mikrofon, ${labelOthers} = datorljudet)")
    $body.Add('=' * 60)
    foreach ($l in $script:meetLines) { $body.Add($l) }
    if ($final) {
        $totalMin = [math]::Round((New-TimeSpan -Start $script:meetStart -End (Get-Date)).TotalMinutes)
        $vy = $script:meetSecsYou; $vo = $script:meetSecsOthers; $tot = $vy + $vo
        if ($tot -gt 0) {
            $py = [math]::Round(100 * $vy / $tot); $po = 100 - $py
            $body.Add(''); $body.Add('-' * 60)
            $body.Add("Talfordelning: ${labelYou} $([math]::Round($vy/60,1)) min ($py%)  |  ${labelOthers} $([math]::Round($vo/60,1)) min ($po%)")
            $body.Add("Ord: ${labelYou} $($script:meetWordsYou)  |  ${labelOthers} $($script:meetWordsOthers)")
            $body.Add("Motets langd: $totalMin min")
        }
        if ($script:meetAnalysis -ne 'off') {
            $body.Add(''); $body.Add('-' * 60)
            $body.Add("Talanalys (privat - endast dina repliker analyserade)")
            $fTot = 0; foreach ($v in $script:meetFillers.Values) { $fTot += $v }
            $mins = [math]::Max(0.1, $script:meetSecsYou / 60)
            $fPerMin = [math]::Round($fTot / $mins, 1)
            $top = ($script:meetFillers.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { "$($_.Key) ($($_.Value))" }) -join ', '
            $fLine = "Utfyllnadsord: $fTot st ($fPerMin/min)"
            if ($top) { $fLine += "  -  mest: $top" }
            $body.Add($fLine)
            $body.Add("Fragor stallda: $($script:meetQuestions)")
            # Longest monolog: consecutive chunks where you talk and the others barely do.
            $run = 0; $best = 0
            for ($k = 0; $k -lt $script:chunkListYou.Count; $k++) {
                if (($script:chunkListYou[$k] -ge 4) -and ($script:chunkListOthers[$k] -le 1.5)) { $run++; if ($run -gt $best) { $best = $run } }
                else { $run = 0 }
            }
            $monoMin = [math]::Round($best * $chunkSec / 60, 1)
            $body.Add("Langsta monolog: ~$monoMin min")
            $prev = Get-TrendPrev
            if ($prev) { $body.Add("Trend (snitt $($prev.n) senaste): talandel $($prev.share)% - utfyllnad $($prev.fill)/min") }
            if ($script:meetCoach) {
                $body.Add(''); $body.Add('AI-coach (endast dina repliker skickades):')
                foreach ($cl in ($script:meetCoach -split "`n")) { $body.Add($cl.TrimEnd()) }
            }
        }
        if ($script:meetFailed) { $body.Add(''); $body.Add("OBS: delar kunde inte transkriberas - orort ljud finns kvar i: $($script:meetDir)") }
        if ($script:meetRec -and ($script:meetRec.SysFaulted -or $script:meetRec.MicFaulted)) {
            $body.Add("OBS: en ljudstrom avbrots under motet (enhet urkopplad?) - delar kan saknas.")
        }
    }
    try { [System.IO.File]::WriteAllText($script:meetOutFile, (($body -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($true)) }
    catch { Write-Log "Save-LiveTranscript: $($_.Exception.Message)" }
}

function Start-Meeting {
    if ($script:meeting) { return }
    if ($script:dictating) { Cancel-Dictation }   # a slow Ctrl+Shift+M chord can arm PTT dictation; drop it
    try {
        $script:meetDir = Join-Path $env:TEMP ('diktatorn_meet_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Force $script:meetDir | Out-Null
        $script:meetLines = New-Object 'System.Collections.Generic.List[string]'
        $script:meetProcessed = 0; $script:meetBusy = $false; $script:meetFailed = $false
        $script:meetSecsYou = 0.0; $script:meetSecsOthers = 0.0
        $script:meetWordsYou = 0;  $script:meetWordsOthers = 0
        $script:meetAnalysis = $script:talanalys           # snapshot: mid-meeting toggles apply to the NEXT meeting
        $script:meetFillers = @{}; $script:meetQuestions = 0; $script:meetCoach = $null
        $script:chunkListYou = New-Object 'System.Collections.Generic.List[double]'
        $script:chunkListOthers = New-Object 'System.Collections.Generic.List[double]'
        $script:crocLastWarn = 0
        $script:meetStart = Get-Date
        $script:meetStamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $script:meetOutFile = Join-Path $outDir ('Mote_' + (Get-Date -Format 'yyyy-MM-dd_HHmmss') + '.txt')
        $script:meetRec = New-Object MeetingRecorder
        $script:meetRec.Start($script:meetDir, $script:micDevice, $chunkSec)   # rotation runs inside the recorder
        $script:meeting = $true
        Save-LiveTranscript
        $meetTimer.Start()
        $miMeeting.Text = 'Stoppa motesinspelning (Ctrl+Shift+M)'
        $miOpenLive.Enabled = $true
        Set-Status 'SPELAR IN MOTE (live)...' $icoMeet
        $tray.ShowBalloonTip(2500, 'Diktatorn', 'Motesinspelning startad. Transkriptet vaxer live - se menyn.', 'Info')
    } catch {
        $script:meeting = $false
        try { $meetTimer.Stop() } catch {}
        try { if ($script:meetRec) { $script:meetRec.Stop() } } catch {}
        Write-Log "Start-Meeting: $($_.Exception.Message)"
        $tray.ShowBalloonTip(4000, 'Diktatorn', "Kunde inte starta motesinspelning: $($_.Exception.Message)", 'Error')
        Set-Status 'redo' $icoIdle
        Remove-Item $script:meetDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-Meeting {
    if (-not $script:meeting) { return }
    $script:meeting = $false
    $meetTimer.Stop()
    $miMeeting.Text = 'Starta motesinspelning (Ctrl+Shift+M)'
    $miOpenLive.Enabled = $false
    Set-Status 'transkriberar mote...' $icoWork
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $script:meetRec.Stop()
        Process-ReadyChunks ($script:meetRec.ChunkIndex + 1)   # remaining chunks incl. the final partial one
        if (($script:meetLines.Count -eq 0) -and -not $script:meetFailed) {
            $tray.ShowBalloonTip(3000, 'Diktatorn', 'Inget tal fangades under motet.', 'Warning')
            Remove-Item $script:meetOutFile -ErrorAction SilentlyContinue
            Remove-Item $script:meetDir -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        if (($script:meetAnalysis -eq 'coach') -and ($script:meetSecsYou -gt 5)) {
            Set-Status 'AI-coach analyserar...' $icoWork
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $youText = (@($script:meetLines | Where-Object { $_ -match ("\] " + [regex]::Escape($labelYou) + ":") } |
                    ForEach-Object { ($_ -replace '^\[[0-9:]+\]\s*\S+:\s*', '') })) -join "`n"
                $tot = $script:meetSecsYou + $script:meetSecsOthers
                $share = if ($tot -gt 0) { [math]::Round(100 * $script:meetSecsYou / $tot) } else { 0 }
                $fTot = 0; foreach ($v in $script:meetFillers.Values) { $fTot += $v }
                $stats = "Talandel: $share% av motet. Fragor stallda: $($script:meetQuestions). Utfyllnadsord: $fTot. Din taltid: $([math]::Round($script:meetSecsYou/60,1)) min."
                $script:meetCoach = Get-CoachReport $youText $stats
            } catch { Write-Log "coach: $($_.Exception.Message)" }   # coach failure never blocks the transcript
        }
        Save-LiveTranscript -final
        if ($script:meetAnalysis -ne 'off') {
            $tot = $script:meetSecsYou + $script:meetSecsOthers
            if ($tot -gt 30) {
                $share = [math]::Round(100 * $script:meetSecsYou / $tot)
                $fTot = 0; foreach ($v in $script:meetFillers.Values) { $fTot += $v }
                $fPerMin = [math]::Round($fTot / [math]::Max(0.1, $script:meetSecsYou / 60), 1)
                $run = 0; $best = 0
                for ($k = 0; $k -lt $script:chunkListYou.Count; $k++) {
                    if (($script:chunkListYou[$k] -ge 4) -and ($script:chunkListOthers[$k] -le 1.5)) { $run++; if ($run -gt $best) { $best = $run } } else { $run = 0 }
                }
                Add-TrendRow ([int][math]::Round((New-TimeSpan -Start $script:meetStart -End (Get-Date)).TotalMinutes)) $share $fPerMin $script:meetQuestions ([math]::Round($best * $chunkSec / 60, 1))
            }
        }
        if ($script:meetFailed) {
            $tray.ShowBalloonTip(6000, 'Diktatorn', 'Mote delvis transkriberat. Orort ljud sparat i temp (se slutet av filen).', 'Warning')
            # KEEP $meetDir: it holds the chunk audio that failed to transcribe
        } else {
            $tray.ShowBalloonTip(3000, 'Diktatorn', "Mote transkriberat: $([System.IO.Path]::GetFileName($script:meetOutFile))", 'Info')
            Remove-Item $script:meetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Invoke-Item $script:meetOutFile
    } catch {
        Write-Log "Stop-Meeting: $($_.Exception.Message)"
        # Do NOT delete $meetDir on error - the raw chunk audio is the only copy left.
        $tray.ShowBalloonTip(6000, 'Diktatorn', "Fel vid motesavslut. Ljud sparat i: $($script:meetDir)", 'Error')
    } finally { Set-Status 'redo' $icoIdle }
}

# Meeting timer: rotation happens inside the recorder, so this just transcribes finished
# chunks (a few per tick to drain any backlog without freezing the UI) and updates status.
$meetTimer = New-Object System.Windows.Forms.Timer
$meetTimer.Interval = 1000
$meetTimer.add_Tick({
    if (-not $script:meeting -or $script:meetBusy) { return }
    $script:meetBusy = $true
    try {
        $ready = $script:meetRec.ChunkIndex
        if ($script:meetProcessed -lt $ready) {
            Process-ReadyChunks ([math]::Min($ready, $script:meetProcessed + 3))
        }
        # Crocodile warning: rolling-window talk share (big mouth, small ears -> listen more).
        if ($script:meetAnalysis -ne 'off') {
            $winChunks = [math]::Max(1, [math]::Ceiling($crocWinSec / $chunkSec))
            $n = $script:chunkListYou.Count
            if ($n -ge $winChunks) {
                $y = 0.0; $o = 0.0
                for ($k = $n - $winChunks; $k -lt $n; $k++) { $y += $script:chunkListYou[$k]; $o += $script:chunkListOthers[$k] }
                $tot = $y + $o
                if ($tot -ge $crocMinSpeech) {
                    $share = 100 * $y / $tot
                    $now = [Environment]::TickCount
                    if (($share -ge $crocPct) -and (($now - $script:crocLastWarn) -ge ($crocCooldownSec * 1000))) {
                        $script:crocLastWarn = $now
                        $winMin = [math]::Max(1, [int]($crocWinSec / 60))
                        $tray.ShowBalloonTip(5000, 'Diktatorn', "Krokodilvarning: du har pratat $([math]::Round($share)) % senaste $winMin min. Stor mun, sm${sw_a} ${sw_o}ron - lyssna mer.", 'Warning')
                        Write-Log ("croc-warning: share=" + [math]::Round($share) + "% window=" + $winChunks + " chunks")
                    }
                }
            }
        }
        $mins = [math]::Round(((Get-Date) - $script:meetStart).TotalMinutes)
        Set-Status "MOTE $mins min - $($script:meetLines.Count) rader (live)" $icoMeet
    } catch { Write-Log "meetTimer: $($_.Exception.Message)" }
    finally { $script:meetBusy = $false }
})

# --- Hotkeys: 1 = dictation toggle (Ctrl+Shift+D), 2 = meeting toggle (Ctrl+Shift+M) ---
$hk = New-Object WfNative
[void]$hk.Register(1, [uint32]6, [uint32]0x44)   # Ctrl+Shift+D
[void]$hk.Register(2, [uint32]6, [uint32]0x4D)   # Ctrl+Shift+M
$script:pttSuppressed = $false
$hk.add_HotkeyPressed({
    param($id)
    $script:pttSuppressed = $true   # a combo with a letter fired; block push-to-talk until modifiers released
    if ($id -eq 1) { if (-not $script:meeting) { if ($script:dictating) { Stop-Dictation } else { [void](Start-Dictation) } } }
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
                if (Start-Dictation) { $script:pttActive = $true } else { $script:pttSuppressed = $true }
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
    try { if ($script:meeting) { Stop-Meeting } } catch {}   # finish + save the transcript, don't lose it
    try { if ($script:dictating) { $script:micRec.Stop() } } catch {}
    $hk.Dispose(); $tray.Visible = $false; $appContext.ExitThread()
})

$tray.ShowBalloonTip(2500, 'Diktatorn', 'Redo. Hall Ctrl+Shift for att diktera, Ctrl+Shift+M for mote.', 'Info')
[System.Windows.Forms.Application]::Run($appContext)
