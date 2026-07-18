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
$journalDir = Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) 'Journal'
$scriptsDir = Join-Path ([System.Environment]::GetFolderPath('MyDocuments')) 'SalesScripts'
$tmpDict   = Join-Path $env:TEMP 'whisprflow_dict.wav'
$tmpJournal = Join-Path $env:TEMP 'whisprflow_journal.wav'
$logFile   = Join-Path $env:TEMP 'diktatorn.log'
$micCfg    = Join-Path $root 'diktatorn-mic.txt'   # remembers which microphone to use
$preferMic = 'USB PnP Sound Device'                # default mic (substring match), not the room/camera
$backendCfg = Join-Path $root 'diktatorn-backend.txt'   # 'local' or 'groq'
$groqKeyFile = Join-Path $root 'diktatorn-groq.txt'     # Groq API key (plaintext, local only)
$groqModel  = 'whisper-large-v3-turbo'
New-Item -ItemType Directory -Force $outDir | Out-Null
New-Item -ItemType Directory -Force $journalDir | Out-Null
New-Item -ItemType Directory -Force $scriptsDir | Out-Null
if (-not (Get-ChildItem $scriptsDir -Filter '*.md' -ErrorAction SilentlyContinue)) {
    $exampleScript = Join-Path $root 'exempel-saljsamtal.md'
    if (Test-Path $exampleScript) { Copy-Item $exampleScript $scriptsDir -ErrorAction SilentlyContinue }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Talanalys (private speech analysis; only YOUR mic lines are ever analyzed) ---
$talanalysCfg = Join-Path $root 'diktatorn-talanalys.txt'   # 'off' | 'stats' | 'coach'
$trendCsv     = Join-Path $outDir 'talanalys-trend.csv'
# AI coach engine: selectable provider. All three speak the OpenAI chat-completions
# protocol, so one implementation serves them all (url + key + model differ).
$coachCfg          = Join-Path $root 'diktatorn-coach.txt'         # 'groq' | 'ollama' | 'openrouter'
$coachModelCfg     = Join-Path $root 'diktatorn-coach-model.txt'   # optional: one line overriding the provider's default model
$openrouterKeyFile = Join-Path $root 'diktatorn-openrouter.txt'    # OpenRouter API key (sk-or-...)
$coachArchive      = Join-Path $outDir 'coach-arkiv.md'            # coach memory: past reports (local, private)
$coachDefaults = @{
    groq       = @{ url = 'https://api.groq.com/openai/v1/chat/completions'; model = 'llama-3.3-70b-versatile' }
    ollama     = @{ url = 'http://localhost:11434/v1/chat/completions';      model = 'llama3.1' }
    openrouter = @{ url = 'https://openrouter.ai/api/v1/chat/completions';   model = 'openrouter/auto' }
}
$meetModeCfg  = Join-Path $root 'diktatorn-meetmode.txt'    # 'live' | 'deferred' (transcribe after the meeting; kind to weak GPUs)
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
    // Loudness of a 16-bit PCM file, 0..1. Room noise measures ~0.004 (-48 dB);
    // real speech ~0.10 (-20 dB). Used to reject near-silent takes before they
    // reach Whisper, which otherwise invents plausible sentences out of hiss.
    public static double Rms(string path) {
        using (var reader = new AudioFileReader(path)) {
            float[] buf = new float[16000];
            double sum = 0; long n = 0; int read;
            while ((read = reader.Read(buf, 0, buf.Length)) > 0) {
                for (int i = 0; i < read; i++) { sum += (double)buf[i] * buf[i]; n++; }
            }
            return n > 0 ? Math.Sqrt(sum / n) : 0.0;
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
# GPU choice matters enormously: on a laptop/desktop with both an integrated and a
# discrete GPU, DirectX often lists the integrated one first. Taking [0] blindly
# measured 0.3x realtime on an integrated Radeon versus 10.9x on the discrete
# RTX beside it — a 34x difference, and the reason local mode felt unusable.
# Prefer a discrete card; let diktatorn-gpu.txt override.
$gpuCfg = Join-Path $root 'diktatorn-gpu.txt'
$script:adapters = @(Get-Adapters | Where-Object { $_ -notlike '*Basic Render*' })
if (-not $script:adapters) { $script:adapters = @(Get-Adapters) }
# A discrete card names its model line; integrated ones are generic
# ("AMD Radeon(TM) Graphics", "Intel(R) UHD Graphics").
function Test-DiscreteAdapter([string]$name) {
    return ($name -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Radeon (RX|Pro)|Arc\b')
}
function Resolve-Adapter {
    if (Test-Path $gpuCfg) {
        $saved = (Get-Content $gpuCfg -Raw -ErrorAction SilentlyContinue).Trim()
        $hit = @($script:adapters | Where-Object { $_ -eq $saved })[0]
        if ($hit) { return $hit }
    }
    $disc = @($script:adapters | Where-Object { Test-DiscreteAdapter $_ })[0]
    if ($disc) { return $disc }
    return $script:adapters[0]
}
$script:adapter = Resolve-Adapter
$adapter = $script:adapter
Write-Log "GPU: $adapter  (tillgangliga: $($script:adapters -join ', '))"
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
    $script:model = Import-WhisperModel -path (Join-Path $modelDir $file) -adapter $script:adapter
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
    $path = Join-Path $modelDir $file
    if (-not (Test-Path $path)) {
        # Installed users only have one model on disk - fetch the chosen one on demand.
        Set-Status 'laddar ner modell...' $icoWork
        $tray.ShowBalloonTip(4000, 'Diktatorn', "Modellen $file laddas ner - det kan ta nagra minuter...", 'Info')
        [System.Windows.Forms.Application]::DoEvents()
        try {
            Invoke-WebRequest "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$file" -OutFile $path
        } catch {
            Write-Log "model download ${file}: $($_.Exception.Message)"
            Remove-Item $path -ErrorAction SilentlyContinue
            $tray.ShowBalloonTip(4000, 'Diktatorn', 'Nedladdningen misslyckades - modellen byttes inte.', 'Error')
            Set-Status 'redo' $icoIdle
            return
        }
    }
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
    if ($t -eq 'coach' -and -not (Get-CoachKey $script:coach)) {
        $tray.ShowBalloonTip(4000, 'Diktatorn', "AI-coachen behover en API-nyckel for vald motor ($($script:coach)).", 'Warning')
    }
    $script:talanalys = $t
    try { [System.IO.File]::WriteAllText($talanalysCfg, $t) } catch {}
    foreach ($it in $script:talanalysMenuItems) { $it.Checked = ($it.Tag -eq $t) }
}

# --- Coach engine selection: groq (free cloud) | ollama (local) | openrouter (your pick) ---
function Resolve-Coach {
    if (Test-Path $coachCfg) {
        $c = (Get-Content $coachCfg -Raw -ErrorAction SilentlyContinue).Trim()
        if ($c -in @('groq', 'ollama', 'openrouter')) { return $c }
    }
    return 'groq'
}
$script:coach = Resolve-Coach
function Get-CoachKey([string]$provider) {
    switch ($provider) {
        'groq'       { return (Get-GroqKey) }
        'openrouter' {
            if ($env:OPENROUTER_API_KEY) { return $env:OPENROUTER_API_KEY }
            if (Test-Path $openrouterKeyFile) { $k = (Get-Content $openrouterKeyFile -Raw -ErrorAction SilentlyContinue).Trim(); if ($k) { return $k } }
            return $null
        }
        default      { return 'local' }   # Ollama needs no key; non-null sentinel
    }
}
function Set-Coach([string]$c) {
    if ($c -eq 'openrouter' -and -not (Get-CoachKey 'openrouter')) {
        $tray.ShowBalloonTip(4000, 'Diktatorn', 'OpenRouter behover en API-nyckel. Hogerklicka -> Ange OpenRouter API-nyckel.', 'Warning')
    }
    if ($c -eq 'ollama') {
        $tray.ShowBalloonTip(4000, 'Diktatorn', 'Kraver att Ollama kor lokalt (ollama.com). Modell valjs i diktatorn-coach-model.txt.', 'Info')
    }
    $script:coach = $c
    try { [System.IO.File]::WriteAllText($coachCfg, $c) } catch {}
    foreach ($it in $script:coachMenuItems) { $it.Checked = ($it.Tag -eq $c) }
}

# --- Meeting transcription mode: live (growing transcript) | deferred (transcribe on stop) ---
function Resolve-MeetMode {
    if (Test-Path $meetModeCfg) {
        $m = (Get-Content $meetModeCfg -Raw -ErrorAction SilentlyContinue).Trim()
        if ($m -eq 'deferred') { return 'deferred' }
    }
    return 'live'
}
$script:meetMode = Resolve-MeetMode
function Set-MeetMode([string]$m) {
    $script:meetMode = $m
    try { [System.IO.File]::WriteAllText($meetModeCfg, $m) } catch {}
    foreach ($it in $script:meetModeMenuItems) { $it.Checked = ($it.Tag -eq $m) }
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
$miInfo = $menu.Items.Add('Ctrl+Shift = diktera  |  +D toggel  |  +N journal  |  +M mote'); $miInfo.Enabled = $false
$miStats = $menu.Items.Add('Talhastighet: - '); $miStats.Enabled = $false
[void]$menu.Items.Add('-')
$miMeeting = $menu.Items.Add('Starta motesinspelning (Ctrl+Shift+M)')
$miOpenLive = $menu.Items.Add('Visa transkript (live)')
$miOpenLive.Enabled = $false
$miOpenLive.add_Click({ if ($script:meetOutFile -and (Test-Path $script:meetOutFile)) { Invoke-Item $script:meetOutFile } })
$miJournal = $menu.Items.Add('Oppna dagens journal')
$miJournal.add_Click({
    $f = Join-Path $journalDir ((Get-Date -Format 'yyyy-MM-dd') + '.md')
    if (Test-Path $f) { Invoke-Item $f }
    else { $tray.ShowBalloonTip(2500, 'Diktatorn', 'Ingen journal idag an. Tryck Ctrl+Shift+N och prata.', 'Info') }
})
$miScript = $menu.Items.Add('Salj-script...')
$miScript.add_Click({ Open-ScriptPicker })
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
if ($script:adapters.Count -gt 1) {
    $miGpu = New-Object System.Windows.Forms.ToolStripMenuItem 'Grafikkort (lokal transkribering)'
    $script:gpuMenuItems = @()
    foreach ($a in $script:adapters) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $a
        $item.Tag = $a
        $item.Checked = ($a -eq $script:adapter)
        $item.add_Click({
            $chosen = [string]$this.Tag
            try { [System.IO.File]::WriteAllText($gpuCfg, $chosen) } catch {}
            $script:adapter = $chosen
            foreach ($it in $script:gpuMenuItems) { $it.Checked = ($it.Tag -eq $chosen) }
            Set-Status 'byter grafikkort...' $icoWork
            try {
                Reload-Model $script:modelFile
                if (Test-DiscreteAdapter $chosen) {
                    $tray.ShowBalloonTip(3000, 'Diktatorn', "Anvander nu: $chosen", 'Info')
                } else {
                    $tray.ShowBalloonTip(7000, 'Diktatorn', "Anvander nu: $chosen`n`nOBS: integrerad grafik - lokal transkribering blir mycket langsam.", 'Warning')
                }
            } catch {
                Write-Log "GPU-byte misslyckades: $($_.Exception.Message)"
                $tray.ShowBalloonTip(4000, 'Diktatorn', "Kunde inte anvanda $chosen", 'Error')
            }
            Set-Status 'redo' $icoIdle
        })
        [void]$miGpu.DropDownItems.Add($item)
        $script:gpuMenuItems += $item
    }
    [void]$menu.Items.Add($miGpu)
}
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
$miCoach = New-Object System.Windows.Forms.ToolStripMenuItem 'Coach-motor (AI-coach)'
$script:coachMenuItems = @()
foreach ($c in @(
    @{t='groq';       l='Groq (gratis, moln)'},
    @{t='ollama';     l='Ollama (lokal, privat)'},
    @{t='openrouter'; l='OpenRouter (eget modellval)'}
)) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $c.l
    $item.Tag = $c.t
    $item.Checked = ($c.t -eq $script:coach)
    $item.add_Click({ Set-Coach ([string]$this.Tag) })
    [void]$miCoach.DropDownItems.Add($item)
    $script:coachMenuItems += $item
}
[void]$menu.Items.Add($miCoach)
$miMode = New-Object System.Windows.Forms.ToolStripMenuItem 'Motestranskribering'
$script:meetModeMenuItems = @()
foreach ($m in @(
    @{t='live';     l='Live (vaxande transkript)'},
    @{t='deferred'; l='Efter motet (skonar datorn)'}
)) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $m.l
    $item.Tag = $m.t
    $item.Checked = ($m.t -eq $script:meetMode)
    $item.add_Click({ Set-MeetMode ([string]$this.Tag) })
    [void]$miMode.DropDownItems.Add($item)
    $script:meetModeMenuItems += $item
}
[void]$menu.Items.Add($miMode)
$miKey = $menu.Items.Add('Ange Groq API-nyckel...')
$miKey.add_Click({
    Add-Type -AssemblyName Microsoft.VisualBasic
    $cur = Get-GroqKey
    $val = [Microsoft.VisualBasic.Interaction]::InputBox('Klistra in din Groq API-nyckel (gsk_...):', 'Groq API-nyckel', $cur)
    if ($val) { try { [System.IO.File]::WriteAllText($groqKeyFile, $val.Trim()); $tray.ShowBalloonTip(2500, 'Diktatorn', 'Groq-nyckel sparad.', 'Info') } catch {} }
})
$miORKey = $menu.Items.Add('Ange OpenRouter API-nyckel...')
$miORKey.add_Click({
    Add-Type -AssemblyName Microsoft.VisualBasic
    $cur = Get-CoachKey 'openrouter'
    $val = [Microsoft.VisualBasic.Interaction]::InputBox('Klistra in din OpenRouter API-nyckel (sk-or-...):', 'OpenRouter API-nyckel', $cur)
    if ($val) { try { [System.IO.File]::WriteAllText($openrouterKeyFile, $val.Trim()); $tray.ShowBalloonTip(2500, 'Diktatorn', 'OpenRouter-nyckel sparad.', 'Info') } catch {} }
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

# --- Journal: dictate a note -> appended to today's journal file (never typed at the cursor) ---
$script:journaling = $false
function Start-Journal {
    if ($script:meeting -or $script:meetFinishing -or $script:dictating) { return }
    Remove-Item $tmpJournal -ErrorAction SilentlyContinue
    if (-not $script:micRec.Start($tmpJournal, $script:micDevice)) {
        Write-Log 'Start-Journal: mic could not be opened'
        $tray.ShowBalloonTip(3000, 'Diktatorn', 'Mikrofonen kunde inte oppnas.', 'Warning')
        return
    }
    $script:journaling = $true
    Set-Status 'SPELAR IN (journal)...' $icoRec
}
function Stop-Journal {
    $script:journaling = $false
    Set-Status 'transkriberar journal...' $icoWork
    $script:micRec.Stop()
    [System.Windows.Forms.Application]::DoEvents()
    try {
        # Whisper invents plausible sentences out of near-silence, so a mis-press would
        # otherwise write a fabricated entry into a personal journal. Gate on actually
        # voiced audio, same guard the meeting chunks use.
        $cleanJ = Join-Path $env:TEMP 'whisprflow_journal_clean.wav'
        [AudioPrep]::Clean($tmpJournal, $cleanJ)
        $rmsJ = if (Test-Path $cleanJ) { [AudioPrep]::Rms($cleanJ) } else { 0 }
        # 0.01 = -40 dB, comfortably between measured room noise (~-49 dB) and speech (~-20 dB)
        if (-not (Test-Path $cleanJ) -or ((Get-Item $cleanJ).Length -lt 16000) -or ($rmsJ -lt 0.01)) {
            Write-Log ("Journal: for tyst (rms {0:N4}) - ingen anteckning" -f $rmsJ)
            $tray.ShowBalloonTip(3000, 'Diktatorn', 'Inget tal hordes - ingen anteckning sparad.', 'Info')
            return
        }
        $text = Get-TranscriptText $cleanJ
        if ($text) {
            $file = Join-Path $journalDir ((Get-Date -Format 'yyyy-MM-dd') + '.md')
            if (-not (Test-Path $file)) {
                [System.IO.File]::WriteAllText($file, ('# Journal ' + (Get-Date -Format 'yyyy-MM-dd') + "`r`n"), [System.Text.UTF8Encoding]::new($true))
            }
            Add-Content -Path $file -Value ("`r`n## " + (Get-Date -Format 'HH:mm') + "`r`n`r`n" + $text) -Encoding UTF8
            $tray.ShowBalloonTip(2000, 'Diktatorn', 'Journalanteckning sparad.', 'Info')
        }
    } catch {
        Write-Log "Stop-Journal: $($_.Exception.Message)"
        $tray.ShowBalloonTip(3000, 'Diktatorn', "Fel: $($_.Exception.Message)", 'Error')
    }
    finally { Set-Status 'redo' $icoIdle }
}

# --- Sales script screen: always-on-top checklist guiding a prepared call. Items are
# checked manually, or AUTOMATICALLY during a live meeting: new transcript chunks are
# matched against unchecked items by the coach engine ("Budget? -> covered").
$script:scriptForm = $null
$script:scriptChecks = @()
$script:scriptLastLine = 0

function Parse-SalesScript([string]$path) {
    $items = @()
    foreach ($line in (Get-Content $path -Encoding UTF8)) {
        $t = $line.Trim()
        if (-not $t) { continue }
        if ($t -match '^#{1,3}\s*(.+)$') { $items += @{ kind = 'section'; text = $Matches[1].Trim() } }
        elseif ($t -match '^[-*]\s*(?:\[[ xX]\]\s*)?(.+)$') { $items += @{ kind = 'item'; text = $Matches[1].Trim() } }
    }
    return ,$items
}

function Open-ScriptWindow([string]$path) {
    if ($script:scriptForm -and -not $script:scriptForm.IsDisposed) { $script:scriptForm.Close() }
    $items = Parse-SalesScript $path
    if (@($items).Count -eq 0) {
        $tray.ShowBalloonTip(3000, 'Diktatorn', 'Scriptet ar tomt. Anvand ## rubriker och - punkter.', 'Warning')
        return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Saljscript - ' + [System.IO.Path]::GetFileNameWithoutExtension($path)
    $f.TopMost = $true
    $f.Size = New-Object System.Drawing.Size(390, 580)
    $f.StartPosition = 'Manual'
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $f.Location = New-Object System.Drawing.Point(($wa.Right - 410), 60)
    $f.FormBorderStyle = 'SizableToolWindow'
    $status = New-Object System.Windows.Forms.Label
    $status.Dock = 'Bottom'; $status.Height = 22
    $status.Text = 'Manuell avbockning - auto nar mote kor live.'
    $panel = New-Object System.Windows.Forms.FlowLayoutPanel
    $panel.Dock = 'Fill'; $panel.FlowDirection = 'TopDown'; $panel.WrapContents = $false
    $panel.AutoScroll = $true; $panel.Padding = '8,8,8,8'
    $script:scriptChecks = @()
    foreach ($it in $items) {
        if ($it.kind -eq 'section') {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $it.text; $l.AutoSize = $true
            $l.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
            $l.Margin = '0,10,0,2'
            [void]$panel.Controls.Add($l)
        } else {
            $cb = New-Object System.Windows.Forms.CheckBox
            $cb.Text = $it.text; $cb.AutoSize = $true
            $cb.MaximumSize = New-Object System.Drawing.Size(340, 0)
            $cb.Margin = '12,2,0,2'
            [void]$panel.Controls.Add($cb)
            $script:scriptChecks += $cb
        }
    }
    $f.Controls.Add($panel); $f.Controls.Add($status)
    $script:scriptForm = $f
    $script:scriptStatus = $status
    $script:scriptLastLine = 0
    $f.Show()
}

# --- Script manager: list / edit / create / AI-generate the call scripts ---
$script:mgrForm = $null

function Get-ScriptFiles { return @(Get-ChildItem $scriptsDir -Filter '*.md' -ErrorAction SilentlyContinue | Sort-Object Name) }

function New-ScriptName([string]$title) {
    # Keep filenames ASCII-safe: the folder is user-facing and gets synced/mailed around.
    $sw_a = [char]229; $sw_ao = [char]228; $sw_o = [char]246
    $n = $title -replace [string]$sw_a, 'a' -replace [string]$sw_ao, 'a' -replace [string]$sw_o, 'o'
    $n = $n -replace [char]197, 'A' -replace [char]196, 'A' -replace [char]214, 'O'
    $n = ($n -replace '[^\w\s-]', '' -replace '\s+', '-').Trim('-')
    if (-not $n) { $n = 'script' }
    return "$n.md"
}

# Ask the coach engine for a script. Returns markdown, or throws.
function Get-AIScript([string]$brief, [string]$existing) {
    $sys = 'You write sales-call scripts as MARKDOWN CHECKLISTS in SWEDISH. Output ONLY the markdown, no preamble, no code fences. Use "## Rubrik" for each phase of the call and "- punkt" for each item under it. Every item must be something the seller DOES or ASKS, phrased so it can be ticked off during the call - short, concrete, one action each. Cover the natural arc: opening, needs discovery, decision process, pitch, objections, close with a concrete next step. 5-7 sections, 3-5 items each. No filler, no explanations, no numbering.'
    if ($existing) {
        $usr = "Forbattra det har saljscriptet. Behall det som fungerar, gor punkterna vassare och mer konkreta, fyll luckor i samtalsbagen.`n`nBESKRIVNING AV MOTET:`n$brief`n`nNUVARANDE SCRIPT:`n$existing"
    } else {
        $usr = "Skriv ett saljscript for det har motet:`n$brief"
    }
    $md = Invoke-CoachLLM $sys $usr
    # Models sometimes wrap the answer in a fence despite being told not to
    $md = $md -replace '(?m)^```[a-z]*\s*$', ''
    return $md.Trim()
}

# Every control and helper the button handlers touch lives in $script: scope on
# purpose. Event handlers run long after Open-ScriptManager has returned, and a
# handler that closes over the function's LOCALS finds them gone by then — the
# buttons silently do nothing (verified: clicks produced no effect at all).
$script:mgrList = $null
$script:mgrEditor = $null
$script:mgrStatus = $null
$script:mgrCurrent = $null
$script:mgrDirty = $false

function Update-ScriptList([string]$selectName) {
    $script:mgrList.Items.Clear()
    foreach ($fi in Get-ScriptFiles) { [void]$script:mgrList.Items.Add($fi.Name) }
    if ($selectName) {
        $ix = $script:mgrList.Items.IndexOf($selectName)
        if ($ix -ge 0) { $script:mgrList.SelectedIndex = $ix; return }
    }
    if ($script:mgrList.Items.Count -gt 0) { $script:mgrList.SelectedIndex = 0 }
}
function Save-CurrentScript {
    if (-not $script:mgrCurrent) { return $true }
    try {
        [System.IO.File]::WriteAllText($script:mgrCurrent, $script:mgrEditor.Text, [System.Text.UTF8Encoding]::new($true))
        $script:mgrDirty = $false
        $script:mgrStatus.Text = " Sparat: $([System.IO.Path]::GetFileName($script:mgrCurrent))"
        return $true
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show("Kunde inte spara: $($_.Exception.Message)", 'Diktatorn')
        return $false
    }
}
function Confirm-ScriptSave {
    if (-not $script:mgrDirty -or -not $script:mgrCurrent) { return $true }
    $r = [System.Windows.Forms.MessageBox]::Show('Spara andringarna?', 'Diktatorn', 'YesNoCancel', 'Question')
    if ($r -eq 'Cancel') { return $false }
    if ($r -eq 'Yes') { return (Save-CurrentScript) }
    $script:mgrDirty = $false
    return $true
}
function Invoke-ScriptAI([bool]$improve) {
    if (-not (Get-CoachKey $script:coach)) {
        [void][System.Windows.Forms.MessageBox]::Show("Coach-motorn ($($script:coach)) saknar API-nyckel. Valj motor eller ange nyckel i tray-menyn.", 'Diktatorn')
        return
    }
    if ($improve -and -not $script:mgrCurrent) { return }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $prompt = if ($improve) { 'Vad ska forbattras? (t.ex. "fler fragor om budget", "kortare oppning")' }
              else { 'Beskriv motet: vem du traffar, vad du saljer, vilket steg i processen.' }
    $brief = [Microsoft.VisualBasic.Interaction]::InputBox($prompt, 'AI-script', '')
    if (-not $brief) { return }
    $script:mgrForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $script:mgrStatus.Text = " Fragar $($script:coach)..."
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $md = Get-AIScript $brief $(if ($improve) { $script:mgrEditor.Text } else { $null })
        if (-not $md) { throw 'Tomt svar fran modellen' }
        if ($improve) {
            $script:mgrEditor.Text = $md
            $script:mgrDirty = $true
            $script:mgrStatus.Text = ' Forbattrat - granska och spara'
        } else {
            $title = ($brief -split '[.,\n]')[0]
            if ($title.Length -gt 40) { $title = $title.Substring(0, 40) }
            $path = Join-Path $scriptsDir (New-ScriptName $title)
            $i = 2
            while (Test-Path $path) { $path = Join-Path $scriptsDir ((New-ScriptName $title) -replace '\.md$', "-$i.md"); $i++ }
            [System.IO.File]::WriteAllText($path, $md, [System.Text.UTF8Encoding]::new($true))
            Update-ScriptList ([System.IO.Path]::GetFileName($path))
            $script:mgrStatus.Text = ' Genererat - granska innan du anvander det'
        }
    } catch {
        Write-Log "AI-script: $($_.Exception.Message)"
        [void][System.Windows.Forms.MessageBox]::Show("Kunde inte generera: $($_.Exception.Message)", 'Diktatorn')
        $script:mgrStatus.Text = ' Misslyckades'
    } finally { $script:mgrForm.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Open-ScriptManager {
    if ($script:mgrForm -and -not $script:mgrForm.IsDisposed) { $script:mgrForm.Activate(); return }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Saljscript'
    $f.Size = New-Object System.Drawing.Size(880, 600)
    $f.StartPosition = 'CenterScreen'
    $f.MinimumSize = New-Object System.Drawing.Size(700, 440)
    $script:mgrForm = $f

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Dock = 'Bottom'; $bar.Height = 42; $bar.Padding = '6,6,6,6'
    $script:mgrStatus = New-Object System.Windows.Forms.Label
    $script:mgrStatus.Dock = 'Bottom'; $script:mgrStatus.Height = 20; $script:mgrStatus.Text = ' '

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $script:mgrList = New-Object System.Windows.Forms.ListBox
    $script:mgrList.Dock = 'Fill'
    $script:mgrList.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $split.Panel1.Controls.Add($script:mgrList)
    $script:mgrEditor = New-Object System.Windows.Forms.TextBox
    $script:mgrEditor.Multiline = $true; $script:mgrEditor.Dock = 'Fill'
    $script:mgrEditor.ScrollBars = 'Both'; $script:mgrEditor.AcceptsTab = $true
    $script:mgrEditor.WordWrap = $false
    $script:mgrEditor.Font = New-Object System.Drawing.Font('Consolas', 10)
    $split.Panel2.Controls.Add($script:mgrEditor)

    $f.Controls.Add($split); $f.Controls.Add($bar); $f.Controls.Add($script:mgrStatus)
    $split.SplitterDistance = 230

    $mk = {
        param($text, $width, $handler)
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $text; $b.Width = $width; $b.Height = 28
        $b.add_Click($handler)
        [void]$bar.Controls.Add($b)
    }
    & $mk 'Spara'           80 { [void](Save-CurrentScript) }
    & $mk 'Nytt'            70 {
        if (-not (Confirm-ScriptSave)) { return }
        Add-Type -AssemblyName Microsoft.VisualBasic
        $t = [Microsoft.VisualBasic.Interaction]::InputBox('Namn pa scriptet:', 'Nytt saljscript', 'Nytt samtal')
        if (-not $t) { return }
        $path = Join-Path $scriptsDir (New-ScriptName $t)
        if (Test-Path $path) { [void][System.Windows.Forms.MessageBox]::Show('Det finns redan ett script med det namnet.', 'Diktatorn'); return }
        [System.IO.File]::WriteAllText($path, "# $t`r`n`r`n## Oppning`r`n- `r`n`r`n## Behovsanalys`r`n- `r`n`r`n## Avslut`r`n- `r`n", [System.Text.UTF8Encoding]::new($true))
        Update-ScriptList ([System.IO.Path]::GetFileName($path))
    }
    & $mk 'Generera med AI' 130 { Invoke-ScriptAI $false }
    & $mk 'Forbattra'       95 { Invoke-ScriptAI $true }
    & $mk 'Kopiera'         85 {
        if (-not $script:mgrCurrent) { return }
        $base = [System.IO.Path]::GetFileNameWithoutExtension($script:mgrCurrent)
        $path = Join-Path $scriptsDir "$base-kopia.md"
        $i = 2
        while (Test-Path $path) { $path = Join-Path $scriptsDir "$base-kopia$i.md"; $i++ }
        Copy-Item $script:mgrCurrent $path
        Update-ScriptList ([System.IO.Path]::GetFileName($path))
    }
    & $mk 'Ta bort'         85 {
        if (-not $script:mgrCurrent) { return }
        $name = [System.IO.Path]::GetFileName($script:mgrCurrent)
        if ([System.Windows.Forms.MessageBox]::Show("Ta bort $name?", 'Diktatorn', 'YesNo', 'Warning') -ne 'Yes') { return }
        try { Remove-Item $script:mgrCurrent -Force } catch {}
        $script:mgrCurrent = $null; $script:mgrDirty = $false; $script:mgrEditor.Text = ''
        Update-ScriptList $null
    }
    & $mk 'Anvand i samtal' 130 {
        if (-not $script:mgrCurrent) { return }
        if (-not (Confirm-ScriptSave)) { return }
        Open-ScriptWindow $script:mgrCurrent
    }
    & $mk 'Oppna mappen'   110 { Invoke-Item $scriptsDir }

    $script:mgrEditor.add_TextChanged({ if ($script:mgrCurrent) { $script:mgrDirty = $true } })
    $script:mgrList.add_SelectedIndexChanged({
        if (-not $script:mgrList.SelectedItem) { return }
        $path = Join-Path $scriptsDir $script:mgrList.SelectedItem
        if ($path -eq $script:mgrCurrent) { return }
        if (-not (Confirm-ScriptSave)) { return }
        $script:mgrCurrent = $path
        try { $script:mgrEditor.Text = [System.IO.File]::ReadAllText($path) } catch { $script:mgrEditor.Text = '' }
        $script:mgrDirty = $false
        $script:mgrStatus.Text = " $($script:mgrList.SelectedItem)"
    })
    $f.add_FormClosing({ if (-not (Confirm-ScriptSave)) { $_.Cancel = $true } })

    Update-ScriptList $null
    $f.Show()
}

function Open-ScriptPicker { Open-ScriptManager }

# --- Meeting: chunked dual-stream -> continuous labeled transcript + talk-time stats ---
# Mic chunks = you ("Du"), loopback chunks = everyone else ("Ovriga"). No ML diarization
# needed: the label IS the stream the audio came from.
$script:meeting  = $false
$script:meetFinishing = $false
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
# Generic OpenAI-protocol chat call, used by every coach provider. Decodes the response
# explicitly as UTF-8 (PS 5.1 Invoke-RestMethod mis-decodes JSON bodies as Latin-1).
function Invoke-CoachLLM([string]$system, [string]$user) {
    $p = $script:coach
    $def = $coachDefaults[$p]
    $model = $def.model
    if (Test-Path $coachModelCfg) { $m = (Get-Content $coachModelCfg -Raw -ErrorAction SilentlyContinue).Trim(); if ($m) { $model = $m } }
    $key = Get-CoachKey $p
    if (-not $key) { throw "Ingen API-nyckel for coach-motorn ($p)" }
    $headers = @{}
    if ($p -ne 'ollama') { $headers['Authorization'] = "Bearer $key" }
    $body = @{ model = $model; temperature = 0.4; max_tokens = 500; messages = @(
        @{ role = 'system'; content = $system },
        @{ role = 'user'; content = $user }
    ) } | ConvertTo-Json -Depth 5
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $def.url -Method Post -Headers $headers `
        -ContentType 'application/json; charset=utf-8' `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
    $json = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    return $json.choices[0].message.content.Trim()
}

# Coach memory: past reports live in a local markdown archive; the last two are fed back
# to the coach so it can follow up on its own previous advice ("did the exercise work?").
function Get-CoachMemory {
    if (-not (Test-Path $coachArchive)) { return '' }
    try {
        $raw = Get-Content $coachArchive -Raw -Encoding UTF8
        $parts = @(($raw -split '(?m)^## ') | Where-Object { $_ -and $_.Trim() -and ($_ -notmatch '^# ') })
        return (@($parts | Select-Object -Last 2 | ForEach-Object { '## ' + $_.Trim() }) -join "`n`n")
    } catch { return '' }
}
function Add-CoachMemory([string]$report) {
    try {
        if (-not (Test-Path $coachArchive)) {
            [System.IO.File]::WriteAllText($coachArchive, "# Coach-arkiv (privat - bara du)`r`n`r`n", [System.Text.UTF8Encoding]::new($true))
        }
        Add-Content -Path $coachArchive -Value ("## " + (Get-Date -Format 'yyyy-MM-dd HH:mm') + "`r`n`r`n" + $report + "`r`n") -Encoding UTF8
    } catch { Write-Log "coach-arkiv: $($_.Exception.Message)" }
}

# AI coach: gets ONLY your lines + stats + its own past reports. Structured framework,
# trend-aware, ends with ONE exercise it will follow up on next meeting.
function Get-CoachReport([string]$youText, [string]$statsSummary) {
    if (-not $youText) { return $null }
    if ($youText.Length -gt 12000) { $youText = $youText.Substring(0, 4000) + ' [...] ' + $youText.Substring($youText.Length - 8000) }
    $sys = 'You are an experienced, direct but friendly sales/communication coach. You receive ONLY the user''s own lines from a meeting (the other side is intentionally excluded), speech statistics, recent trend data, and your own previous coaching reports. Reply in SWEDISH using exactly these numbered sections, 1-2 sentences each: 1) Uppfoljning - compare against your previous reports and the exercise you gave; call out progress or regression with numbers. If no previous reports, say this is the baseline. 2) Balans & lyssnande - talk share, monologues. 3) Fragor - quantity and quality of questions asked. 4) Tydlighet - filler words, clarity. 5) Ovning till nasta mote - ONE concrete, measurable exercise. No preamble. Max 170 words.'
    $mem = Get-CoachMemory
    if (-not $mem) { $mem = '(inga tidigare rapporter)' }
    $trendRaw = ''
    if (Test-Path $trendCsv) { try { $trendRaw = (Get-Content $trendCsv | Select-Object -Last 6) -join "`n" } catch {} }
    $usr = "TIDIGARE COACHRAPPORTER:`n$mem`n`nTREND-CSV (senaste moten):`n$trendRaw`n`nDAGENS STATISTIK:`n$statsSummary`n`nMINA REPLIKER FRAN DAGENS MOTE:`n$youText"
    $report = Invoke-CoachLLM $sys $usr
    if ($report) { Add-CoachMemory $report }
    return $report
}

# Deferred mode: during the meeting we only MEASURE voiced seconds per chunk (cheap CPU-only
# cleanup, no Whisper) so the crocodile warning still works; transcription happens on stop.
function Measure-Chunk([int]$i) {
    $y = 0.0; $o = 0.0
    $clean = Join-Path $script:meetDir 'clean.wav'
    foreach ($s in @(
        @{ wav = (Join-Path $script:meetDir ('chunk_{0:D4}_sys.wav' -f $i)); you = $false },
        @{ wav = (Join-Path $script:meetDir ('chunk_{0:D4}_mic.wav' -f $i)); you = $true }
    )) {
        try {
            if ((Test-Path $s.wav) -and ((Get-Item $s.wav).Length -gt 8192)) {
                [AudioPrep]::Clean($s.wav, $clean)
                if ((Test-Path $clean) -and ((Get-Item $clean).Length -gt 16000)) {
                    if ($s.you) { $y = Get-WavSeconds $clean } else { $o = Get-WavSeconds $clean }
                }
            }
        } catch { Write-Log "measure ${i}: $($_.Exception.Message)" }
    }
    $script:chunkListYou.Add($y); $script:chunkListOthers.Add($o)
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
        if ($script:chunkListYou.Count -le $i) {   # deferred mode already measured this chunk live
            $script:chunkListYou.Add($chunkYou); $script:chunkListOthers.Add($chunkOthers)   # rolling window + monolog data
        }
        $script:meetProcessed++
        if ($any) { Save-LiveTranscript }
        if ($script:meetFinishing) {   # post-meeting batch: show progress, keep the tray alive
            Set-Status "transkriberar mote... $($script:meetProcessed)/$upTo" $icoWork
            [System.Windows.Forms.Application]::DoEvents()
        }
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
        $script:meetModeActive = $script:meetMode          # snapshot: live or deferred for THIS meeting
        $script:meetFinishing = $false
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
    $script:meetFinishing = $true   # blocks dictation hotkeys while the post-meeting batch runs
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
    } finally { $script:meetFinishing = $false; Set-Status 'redo' $icoIdle }
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
        if ($script:meetModeActive -eq 'deferred') {
            while ($script:chunkListYou.Count -lt $ready) { Measure-Chunk $script:chunkListYou.Count }   # stats only, no Whisper
        } elseif ($script:meetProcessed -lt $ready) {
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
        # Sales-script auto-check: match new transcript lines against unchecked items.
        if ($script:scriptForm -and -not $script:scriptForm.IsDisposed -and ($script:meetLines.Count -gt $script:scriptLastLine)) {
            $newText = (@($script:meetLines | Select-Object -Skip $script:scriptLastLine) -join "`n")
            $script:scriptLastLine = $script:meetLines.Count
            $open = @($script:scriptChecks | Where-Object { -not $_.Checked })
            if ($open.Count -gt 0 -and (Get-CoachKey $script:coach)) {
                try {
                    $numbered = @(); for ($k = 0; $k -lt $open.Count; $k++) { $numbered += ('{0}. {1}' -f ($k + 1), $open[$k].Text) }
                    $ans = Invoke-CoachLLM 'You match sales-call checklist items against a conversation snippet (Swedish or English). Reply ONLY with comma-separated numbers of the items that are clearly covered/addressed in the snippet, or NONE. Be conservative: only mark items genuinely discussed.' ("CHECKLIST:`n" + ($numbered -join "`n") + "`n`nSNIPPET:`n" + $newText)
                    if ($ans -notmatch 'NONE') {
                        foreach ($m in [regex]::Matches($ans, '\d+')) {
                            $ix = [int]$m.Value - 1
                            if ($ix -ge 0 -and $ix -lt $open.Count) { $open[$ix].Checked = $true }
                        }
                    }
                    $done = @($script:scriptChecks | Where-Object { $_.Checked }).Count
                    $st = "Avklarat: $done/$($script:scriptChecks.Count)"
                    $tot0 = $script:meetSecsYou + $script:meetSecsOthers
                    if ($tot0 -gt 30) { $st += "  |  din talandel: $([math]::Round(100 * $script:meetSecsYou / $tot0))%" }
                    $script:scriptStatus.Text = $st
                } catch { Write-Log "script-check: $($_.Exception.Message)" }
            }
        }
        $mins = [math]::Round(((Get-Date) - $script:meetStart).TotalMinutes)
        if ($script:meetModeActive -eq 'deferred') { Set-Status "MOTE $mins min - spelar in (transkriberas efter motet)" $icoMeet }
        else { Set-Status "MOTE $mins min - $($script:meetLines.Count) rader (live)" $icoMeet }
    } catch { Write-Log "meetTimer: $($_.Exception.Message)" }
    finally { $script:meetBusy = $false }
})

# --- Hotkeys: 1 = dictation toggle (Ctrl+Shift+D), 2 = meeting toggle (Ctrl+Shift+M) ---
$hk = New-Object WfNative
# RegisterHotKey fails if another app already owns the combo. Swallowing that
# (a bare [void]) makes the key silently dead — report it instead.
$hkFailed = @()
foreach ($h in @(
    @{ id = 1; vk = 0x44; name = 'Ctrl+Shift+D (diktering)' },
    @{ id = 2; vk = 0x4D; name = 'Ctrl+Shift+M (mote)' },
    @{ id = 3; vk = 0x4E; name = 'Ctrl+Shift+N (journal)' }
)) {
    if (-not $hk.Register($h.id, [uint32]6, [uint32]$h.vk)) {
        $hkFailed += $h.name
        Write-Log "Hotkey upptagen av annan app: $($h.name)"
    }
}
if ($hkFailed.Count -gt 0) {
    $tray.ShowBalloonTip(6000, 'Diktatorn', "Dessa kortkommandon ar upptagna av en annan app och fungerar inte:`n" + ($hkFailed -join "`n"), 'Warning')
}
# Integrated graphics run Whisper roughly 30x slower than a discrete card
# (measured: 0.3x vs 10.9x realtime on the same clip), which makes local mode
# feel broken rather than slow. Say so, and say what to do about it.
if (-not (Test-DiscreteAdapter $script:adapter)) {
    $better = @($script:adapters | Where-Object { Test-DiscreteAdapter $_ })[0]
    if ($better) {
        $tray.ShowBalloonTip(9000, 'Diktatorn',
            "Lokal transkribering kor pa integrerad grafik ($script:adapter) och blir da mycket langsam.`n`nDu har $better - valj det under Grafikkort i menyn.",
            'Warning')
    } else {
        $tray.ShowBalloonTip(9000, 'Diktatorn',
            "Inget dedikerat grafikkort hittades - lokal transkribering blir langsam pa $script:adapter.`n`nVal Groq moln under Transkribering for snabbare resultat.",
            'Warning')
    }
    Write-Log "VARNING: integrerad grafik i bruk ($script:adapter)"
}
$script:pttSuppressed = $false
$hk.add_HotkeyPressed({
    param($id)
    $script:pttSuppressed = $true   # a combo with a letter fired; block push-to-talk until modifiers released
    if ($id -eq 1) { if (-not $script:meeting -and -not $script:meetFinishing -and -not $script:journaling) { if ($script:dictating) { Stop-Dictation } else { [void](Start-Dictation) } } }
    elseif ($id -eq 2) { if ($script:meeting) { Stop-Meeting } else { Start-Meeting } }
    elseif ($id -eq 3) { if ($script:journaling) { Stop-Journal } else { Start-Journal } }
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
        if ($script:meeting -or $script:meetFinishing -or $script:journaling -or $script:pttSuppressed) { return }
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
    try { if ($script:dictating -or $script:journaling) { $script:micRec.Stop() } } catch {}
    try { if ($script:scriptForm -and -not $script:scriptForm.IsDisposed) { $script:scriptForm.Close() } } catch {}
    $hk.Dispose(); $tray.Visible = $false; $appContext.ExitThread()
})

$tray.ShowBalloonTip(2500, 'Diktatorn', 'Redo. Hall Ctrl+Shift for att diktera, Ctrl+Shift+M for mote.', 'Info')
[System.Windows.Forms.Application]::Run($appContext)
