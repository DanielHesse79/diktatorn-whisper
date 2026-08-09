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
$meetLangCfg  = Join-Path $root 'diktatorn-meetlang.txt'    # 'sv' | 'en' (no auto: local engine can't detect, only mistranslate)
$keepAudioCfg = Join-Path $root 'diktatorn-keepaudio.txt'   # 'on' | 'off' (keep meeting audio for re-transcription)
$audioArchive = Join-Path $outDir 'Motesljud'              # kept meeting audio, purged after 7 days
$keepAudioDays = 7
# Start-of-meeting audio checks fire once each (mic peak early, system-audio seconds later).
$micCheckSec = if ($env:DIKTATORN_MICCHECK_SEC) { [int]$env:DIKTATORN_MICCHECK_SEC } else { 8 }
$sysCheckSec = if ($env:DIKTATORN_SYSCHECK_SEC) { [int]$env:DIKTATORN_SYSCHECK_SEC } else { 35 }
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

# --- Swedish characters in user-facing text ---
# The .ps1 files are kept ASCII-only on purpose: PS 5.1 reads non-ASCII source
# unreliably depending on the file's encoding and the console code page, which
# has already produced mojibake once. That constraint must NOT leak into the UI,
# so build Swedish letters from code points instead of typing them literally.
#   ~a = a-ring   ~e = a-umlaut   ~o = o-umlaut   (uppercase ~A ~E ~O)
# Mnemonic: the umlauts historically come from ae / oe.
# Tokens are tilde-prefixed, NOT braces: {o}-style placeholders collide with .NET
# composite formatting, so a string using both -f and a placeholder threw at
# runtime and silently killed the rest of the function (hit live in Update-LiveTab -
# talk share, crocodile warning and script status all vanished). Both forms are
# safe now: (SvText 'M~ote') and (SvText ('Du {0:N1} min' -f $x)).
# The name is SvText, not Sv: 'sv' is a built-in alias for Set-Variable, and
# aliases outrank functions in command resolution - so every (Sv 'text') quietly
# ran Set-Variable and returned nothing, blanking the whole UI. Same trap waits
# for any short name; check with Get-Alias before shortening this one.
function SvText([string]$s) {
    $s.Replace('~a',  [string][char]0xE5).Replace('~e', [string][char]0xE4).Replace('~o',  [string][char]0xF6).
       Replace('~A',  [string][char]0xC5).Replace('~E', [string][char]0xC4).Replace('~O',  [string][char]0xD6)
}

# --- Shared UI look: one palette + font scale for every window ---
$script:uiInk     = [System.Drawing.Color]::FromArgb(32, 38, 46)      # primary text
$script:uiMuted   = [System.Drawing.Color]::FromArgb(112, 122, 134)   # secondary text
$script:uiAccent  = [System.Drawing.Color]::FromArgb(58, 110, 200)    # you / active
$script:uiAccent2 = [System.Drawing.Color]::FromArgb(150, 158, 168)   # others / passive
$script:uiOk      = [System.Drawing.Color]::FromArgb(46, 140, 80)
$script:uiWarn    = [System.Drawing.Color]::FromArgb(200, 70, 70)
$script:uiBg      = [System.Drawing.Color]::FromArgb(247, 248, 250)   # window background
$script:uiCard    = [System.Drawing.Color]::White
$script:uiLine    = [System.Drawing.Color]::FromArgb(224, 228, 234)
function UiFont([single]$size, [string]$style = 'Regular') {
    New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::$style)
}

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
    // Live level metering so the PS side can warn a few seconds in if a stream is
    // silent (muted mic, or loopback capturing the wrong/idle playback device) -
    // a silent meeting otherwise only shows up as an empty transcript afterward.
    long micBytesTotal = 0, sysBytesTotal = 0;
    volatile float micPeakLevel = 0f;
    volatile float micLevelNow = 0f, sysLevelNow = 0f;   // last-buffer peak, for live VU meters
    public float MicPeak { get { return micPeakLevel; } }
    public float MicLevel { get { return micLevelNow; } }
    public float SysLevel { get { return sysLevelNow; } }
    public double MicSeconds { get { return Interlocked.Read(ref micBytesTotal) / 32000.0; } }   // 16 kHz * 2 bytes
    public double SysSeconds {
        get {
            int bps = 1;
            try { if (sys != null) bps = sys.WaveFormat.AverageBytesPerSecond; } catch { }
            if (bps <= 0) bps = 1;
            return Interlocked.Read(ref sysBytesTotal) / (double)bps;
        }
    }
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
        sys.DataAvailable += (s, e) => {
            lock (sysLock) { if (sysW != null) { try { sysW.Write(e.Buffer, 0, e.BytesRecorded); } catch { } } }
            Interlocked.Add(ref sysBytesTotal, e.BytesRecorded);
            float sp = 0f;                                        // instantaneous peak, 0..1
            int bits = 16; try { bits = sys.WaveFormat.BitsPerSample; } catch { }
            if (bits == 32) { for (int i = 0; i + 3 < e.BytesRecorded; i += 4) { float v = BitConverter.ToSingle(e.Buffer, i); float a = Math.Abs(v); if (a > sp) sp = a; } }
            else { for (int i = 0; i + 1 < e.BytesRecorded; i += 2) { short v = (short)(e.Buffer[i] | (e.Buffer[i + 1] << 8)); float a = Math.Abs((int)v) / 32768f; if (a > sp) sp = a; } }
            sysLevelNow = sp;
        };
        sys.RecordingStopped += (s, e) => { if (e != null && e.Exception != null) sysFaulted = true; lock (sysLock) { SafeDispose(sysW); sysW = null; } try { sys.Dispose(); } catch { } sysStopped.Set(); };
        sysStopped.Reset();
        sys.StartRecording();
        // Mic is best-effort: if it can't open we still get system audio.
        try {
            mic.DeviceNumber = micDevice;
            mic.WaveFormat = new WaveFormat(16000, 16, 1);
            micW = new WaveFileWriter(MicPath(0), mic.WaveFormat);
            mic.DataAvailable += (s, e) => {
                lock (micLock) { if (micW != null) { try { micW.Write(e.Buffer, 0, e.BytesRecorded); } catch { } } }
                Interlocked.Add(ref micBytesTotal, e.BytesRecorded);
                float p = 0f;                                          // 16-bit PCM peak, 0..1
                for (int i = 0; i + 1 < e.BytesRecorded; i += 2) {
                    short v = (short)(e.Buffer[i] | (e.Buffer[i + 1] << 8));
                    float a = Math.Abs((int)v) / 32768f;
                    if (a > p) p = a;
                }
                micLevelNow = p;
                if (p > micPeakLevel) micPeakLevel = p;
            };
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
# RTX beside it - a 34x difference, and the reason local mode felt unusable.
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
        $tray.ShowBalloonTip(4000, 'Diktatorn', (SvText 'Ingen Groq-nyckel. H~ogerklicka -> Ange Groq API-nyckel.'), 'Warning')
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
        $tray.ShowBalloonTip(4000, 'Diktatorn', (SvText "AI-coachen beh~over en API-nyckel f~or vald motor ($($script:coach))."), 'Warning')
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
        $tray.ShowBalloonTip(4000, 'Diktatorn', (SvText 'OpenRouter beh~over en API-nyckel. H~ogerklicka -> Ange OpenRouter API-nyckel.'), 'Warning')
    }
    if ($c -eq 'ollama') {
        $tray.ShowBalloonTip(4000, 'Diktatorn', (SvText 'Kr~ever att Ollama k~or lokalt (ollama.com). Modell v~eljs i diktatorn-coach-model.txt.'), 'Info')
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

# --- Meeting language ---
# Explicit sv/en only. There is deliberately NO auto-detect: it isn't reliably
# buildable on the local engine, and the failure mode is a silent mistranslation
# that reads like a working transcript.
#   * WhisperPS exposes no language-detection command - only a forced -language.
#   * Forcing the wrong language TRANSLATES rather than reveals: -language en on
#     Swedish audio -> English prose; -language sv on English audio -> Swedish
#     prose. So the text content can never disclose the spoken language.
#   * Omitting -language defaults to English (the original bug: real Swedish
#     meetings came out fully in English).
# Real language-ID lives only in the cloud (Groq), which would ship meeting audio
# off-machine and defeat local mode. Meetings are single-language and the user
# knows which before starting, so an explicit choice is the honest design.
function Resolve-MeetLang {
    if (Test-Path $meetLangCfg) {
        $l = (Get-Content $meetLangCfg -Raw -ErrorAction SilentlyContinue).Trim()
        if ($l -in @('sv', 'en')) { return $l }
    }
    return 'sv'
}
$script:meetLang = Resolve-MeetLang
function Set-MeetLang([string]$l) {
    if ($l -notin @('sv', 'en')) { return }
    $script:meetLang = $l
    try { [System.IO.File]::WriteAllText($meetLangCfg, $l) } catch {}
    foreach ($it in $script:meetLangMenuItems) { $it.Checked = ($it.Tag -eq $l) }
}
# Concrete language handed to the backends - always 'sv' or 'en', never empty.
function Get-ActiveMeetLang { return $script:meetLang }

# --- Keep meeting audio (opt-in): a 7-day safety net so a mis-set language or a
# botched transcription isn't unrecoverable. Audio is otherwise deleted on success. ---
function Resolve-KeepAudio {
    if (Test-Path $keepAudioCfg) { return ((Get-Content $keepAudioCfg -Raw -ErrorAction SilentlyContinue).Trim() -eq 'on') }
    return $false
}
$script:keepAudio = Resolve-KeepAudio
function Set-KeepAudio([bool]$on) {
    $script:keepAudio = $on
    try { [System.IO.File]::WriteAllText($keepAudioCfg, $(if ($on) { 'on' } else { 'off' })) } catch {}
    if ($script:keepAudioMenuItem) { $script:keepAudioMenuItem.Checked = $on }
    if ($on) { $tray.ShowBalloonTip(5000, 'Diktatorn', (SvText "M~otesljud sparas nu i $keepAudioDays dagar i mappen M~otesljud (Transcriptions)."), 'Info') }
}
# Copy a meeting's chunk audio into the dated archive before the temp dir is cleaned.
function Save-MeetingAudio {
    if (-not $script:meetKeepAudio -or -not $script:meetDir -or -not (Test-Path $script:meetDir)) { return }
    try {
        New-Item -ItemType Directory -Force $audioArchive | Out-Null
        $dest = Join-Path $audioArchive ([System.IO.Path]::GetFileNameWithoutExtension($script:meetOutFile))
        New-Item -ItemType Directory -Force $dest | Out-Null
        Copy-Item (Join-Path $script:meetDir '*.wav') $dest -ErrorAction SilentlyContinue
        Write-Log "Motesljud sparat: $dest"
    } catch { Write-Log "Save-MeetingAudio: $($_.Exception.Message)" }
}
# Delete archived audio older than the retention window. Runs at startup and after each meeting.
function Clear-OldMeetingAudio {
    if (-not (Test-Path $audioArchive)) { return }
    try {
        $cutoff = (Get-Date).AddDays(-$keepAudioDays)
        Get-ChildItem $audioArchive -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; Write-Log "Gammalt motesljud rensat: $($_.Name)" }
    } catch { Write-Log "Clear-OldMeetingAudio: $($_.Exception.Message)" }
}

# --- Language prompt shown on Ctrl+Shift+M so the choice is made per meeting. ---
# Returns 'sv', 'en', or $null (cancelled). Pre-selects the current default.
# Form + choice are $script:-scoped: the click handlers fire on the dialog's
# nested message loop, and closures over function locals go null there.
function Show-MeetLangPrompt {
    $script:mlForm = New-Object System.Windows.Forms.Form
    $script:mlForm.Text = (SvText 'M~otesspr~ak')
    $script:mlForm.FormBorderStyle = 'FixedDialog'
    $script:mlForm.StartPosition = 'CenterScreen'
    $script:mlForm.MinimizeBox = $false; $script:mlForm.MaximizeBox = $false; $script:mlForm.TopMost = $true
    $script:mlForm.ClientSize = New-Object System.Drawing.Size(320, 130)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = (SvText 'Vilket spr~ak talas p~a m~otet?')
    $lbl.AutoSize = $true; $lbl.Location = New-Object System.Drawing.Point(16, 18)
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $script:mlForm.Controls.Add($lbl)

    $script:meetLangChoice = $null
    $onClick = { $script:meetLangChoice = [string]$this.Tag; $script:mlForm.Close() }
    $bSv = New-Object System.Windows.Forms.Button
    $bSv.Text = 'Svenska'; $bSv.Tag = 'sv'; $bSv.Size = New-Object System.Drawing.Size(135, 40)
    $bSv.Location = New-Object System.Drawing.Point(16, 60); $bSv.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $bSv.add_Click($onClick); $script:mlForm.Controls.Add($bSv)
    $bEn = New-Object System.Windows.Forms.Button
    $bEn.Text = 'Engelska'; $bEn.Tag = 'en'; $bEn.Size = New-Object System.Drawing.Size(135, 40)
    $bEn.Location = New-Object System.Drawing.Point(169, 60); $bEn.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $bEn.add_Click($onClick); $script:mlForm.Controls.Add($bEn)
    $script:mlForm.AcceptButton = $(if ($script:meetLang -eq 'en') { $bEn } else { $bSv })   # Enter = current default

    [void]$script:mlForm.ShowDialog()
    $script:mlForm.Dispose()
    return $script:meetLangChoice
}

# --- Telefonassistent (AI som pratar i telefonsamtal; egen fil) ---
# Laddas efter NAudio men fore tray-menyn - funktionerna anvander $tray forst
# nar de anropas, sa ordningen har racker.
$script:taTillganglig = $false
try {
    . (Join-Path $PSScriptRoot 'Telefonassistent.ps1')
    $script:taTillganglig = $true
} catch {
    # Saknas filen eller VB-CABLE gar resten av Diktatorn igang anda.
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
$miInfo = $menu.Items.Add((SvText 'Ctrl+Shift = diktera  |  +D v~exla  |  +N journal  |  +M m~ote')); $miInfo.Enabled = $false
$miStats = $menu.Items.Add('Talhastighet: - '); $miStats.Enabled = $false
[void]$menu.Items.Add('-')
$miMeeting = $menu.Items.Add((SvText 'Starta m~otesinspelning (Ctrl+Shift+M)'))
$miOpenLive = $menu.Items.Add('Visa transkript (live)')
$miOpenLive.Enabled = $false
$miOpenLive.add_Click({ if ($script:meetOutFile -and (Test-Path $script:meetOutFile)) { Invoke-Item $script:meetOutFile } })
$miJournal = $menu.Items.Add((SvText '~Oppna dagens journal'))
$miJournal.add_Click({
    $f = Join-Path $journalDir ((Get-Date -Format 'yyyy-MM-dd') + '.md')
    if (Test-Path $f) { Invoke-Item $f }
    else { $tray.ShowBalloonTip(2500, 'Diktatorn', (SvText 'Ingen journal idag ~en. Tryck Ctrl+Shift+N och prata.'), 'Info') }
})
$miScript = $menu.Items.Add((SvText 'S~elj-script...'))
$miScript.add_Click({ Open-ScriptPicker })

# --- Telefonassistent i menyn ---
if ($script:taTillganglig) {
    [void]$menu.Items.Add('-')
    $miPhone = $menu.Items.Add('Starta telefonassistent')
    $miPhoneTon = $menu.Items.Add('Testa kabeln (ton till motparten)')
    $miPhoneTon.Enabled = $false

    # Utgang: dit AI:ns rost gar. Ska vara CABLE Input, annars hors den bara i
    # rummet i stallet for i samtalet.
    $miPhoneUt = New-Object System.Windows.Forms.ToolStripMenuItem 'Telefonassistent: utgang'
    $script:taUtMenuItems = @()
    $script:taValdUt = (Get-TaValdUtgang).Namn
    foreach ($e in Get-TaUtenheter) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $e.Namn
        $item.Tag = $e.Namn
        $item.Checked = ($e.Namn -eq $script:taValdUt)
        $item.add_Click({
            Set-TaUtgang ([string]$this.Tag)
            $script:taValdUt = [string]$this.Tag
            foreach ($it in $script:taUtMenuItems) { $it.Checked = ($it.Tag -eq $script:taValdUt) }
        })
        [void]$miPhoneUt.DropDownItems.Add($item)
        $script:taUtMenuItems += $item
    }
    [void]$menu.Items.Add($miPhoneUt)

    # Roll: svarare vantar in den som ringer, uppringare presenterar sig sjalv.
    $miPhoneRoll = New-Object System.Windows.Forms.ToolStripMenuItem 'Telefonassistent: roll'
    $script:taRollMenuItems = @()
    foreach ($r in @(@{ t = 'svarare'; l = 'Svarare (besvarar samtal)' }, @{ t = 'uppringare'; l = 'Uppringare (ringer ut)' })) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $r.l
        $item.Tag = $r.t
        $item.Checked = ($r.t -eq $script:taRoll)
        $item.add_Click({
            $script:taRoll = [string]$this.Tag
            foreach ($it in $script:taRollMenuItems) { $it.Checked = ($it.Tag -eq $script:taRoll) }
        })
        [void]$miPhoneRoll.DropDownItems.Add($item)
        $script:taRollMenuItems += $item
    }
    [void]$menu.Items.Add($miPhoneRoll)

    # Hjarnan (Telefonsvararen-servern) hittas normalt automatiskt. Ligger den
    # nagon annanstans pekas den ut har i stallet for att redigera kod.
    $miPhoneRot = $menu.Items.Add('Telefonassistent: serverkatalog...')
    $miPhoneRot.add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Valj mappen dar Telefonsvararens server.js ligger'
        $nu = Get-TaRoot
        if ($nu) { $dlg.SelectedPath = $nu }
        if ($dlg.ShowDialog() -eq 'OK') {
            if (Test-Path (Join-Path $dlg.SelectedPath 'server.js')) {
                Set-TaRoot $dlg.SelectedPath
                $tray.ShowBalloonTip(3000, 'Telefonassistent', 'Serverkatalog sparad.', 'Info')
            } else {
                $tray.ShowBalloonTip(4000, 'Telefonassistent', 'Ingen server.js i den mappen.', 'Warning')
            }
        }
    })
}

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
                    $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText "Anv~ender nu: $chosen"), 'Info')
                } else {
                    $tray.ShowBalloonTip(7000, 'Diktatorn', (SvText "Anv~ender nu: $chosen`n`nOBS: integrerad grafik - lokal transkribering blir mycket l~angsam."), 'Warning')
                }
            } catch {
                Write-Log "GPU-byte misslyckades: $($_.Exception.Message)"
                $tray.ShowBalloonTip(4000, 'Diktatorn', (SvText "Kunde inte anv~enda $chosen"), 'Error')
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
$miMode = New-Object System.Windows.Forms.ToolStripMenuItem (SvText 'M~otestranskribering')
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
$miMeetLang = New-Object System.Windows.Forms.ToolStripMenuItem (SvText 'M~otesspr~ak')
$script:meetLangMenuItems = @()
foreach ($l in @(
    @{t='sv';   l='Svenska'},
    @{t='en';   l='Engelska'}
)) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem $l.l
    $item.Tag = $l.t
    $item.Checked = ($l.t -eq $script:meetLang)
    $item.add_Click({ Set-MeetLang ([string]$this.Tag) })
    [void]$miMeetLang.DropDownItems.Add($item)
    $script:meetLangMenuItems += $item
}
[void]$menu.Items.Add($miMeetLang)
$script:keepAudioMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem (SvText "Spara m~otesljud ($keepAudioDays dagar)")
$script:keepAudioMenuItem.CheckOnClick = $true
$script:keepAudioMenuItem.Checked = $script:keepAudio
$script:keepAudioMenuItem.add_Click({ Set-KeepAudio $this.Checked })
[void]$menu.Items.Add($script:keepAudioMenuItem)
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
# Dashboard entry at the very top of the menu, plus double-click on the tray icon.
$miDash = New-Object System.Windows.Forms.ToolStripMenuItem (SvText '~Oppna Diktatorn...')
$miDash.Font = New-Object System.Drawing.Font($miDash.Font, [System.Drawing.FontStyle]::Bold)
$miDash.add_Click({ Open-Dashboard })
$menu.Items.Insert(0, $miDash)
$menu.Items.Insert(1, (New-Object System.Windows.Forms.ToolStripSeparator))
$tray.ContextMenuStrip = $menu
$tray.add_MouseDoubleClick({ param($s, $e) if ($e.Button -eq 'Left') { Open-Dashboard } })

function Set-Status([string]$txt, $icon) { $tray.Text = ('Diktatorn - ' + $txt); $tray.Icon = $icon }

# ============================================================================
# Dashboard window: one place for live meeting, settings, history, talanalys.
# The tray icon + hotkeys stay the fast path; this complements them. All state
# is $script:-scoped so tab-builder closures survive past Open-Dashboard's return.
# ============================================================================
$script:dashForm = $null
# Shared GPU switch so the dashboard and tray don't drift. Writes config, reloads
# the model on the new adapter, warns if it's integrated (30x slower).
function Set-Gpu([string]$chosen) {
    if (-not $chosen) { return }
    try { [System.IO.File]::WriteAllText($gpuCfg, $chosen) } catch {}
    $script:adapter = $chosen
    if ($script:gpuMenuItems) { foreach ($it in $script:gpuMenuItems) { $it.Checked = ($it.Tag -eq $chosen) } }
    Set-Status 'byter grafikkort...' $icoWork
    try {
        Reload-Model $script:modelFile
        if (Test-DiscreteAdapter $chosen) { $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText "Anv~ender nu: $chosen"), 'Info') }
        else { $tray.ShowBalloonTip(7000, 'Diktatorn', (SvText "Anv~ender nu: $chosen`n`nOBS: integrerad grafik - lokal transkribering blir mycket l~angsam."), 'Warning') }
    } catch {
        Write-Log "GPU-byte misslyckades: $($_.Exception.Message)"
        $tray.ShowBalloonTip(4000, 'Diktatorn', (SvText "Kunde inte anv~enda $chosen"), 'Error')
    }
    Set-Status 'redo' $icoIdle
}
function Open-Dashboard {
    if ($script:dashForm -and -not $script:dashForm.IsDisposed) {
        # Reopen a hidden window: Show it (Activate alone won't un-hide), refresh
        # the data tabs, and restart the live timer that FormClosing stopped.
        $script:dashForm.Show(); $script:dashForm.WindowState = 'Normal'; $script:dashForm.Activate()
        Refresh-HistoryList; Refresh-TrendView
        try { $script:dashTimer.Start() } catch {}
        return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Diktatorn'
    $f.Size = New-Object System.Drawing.Size(860, 660)
    $f.MinimumSize = New-Object System.Drawing.Size(700, 520)
    $f.StartPosition = 'CenterScreen'
    $f.BackColor = $script:uiBg
    $f.Font = UiFont 9.75
    try { $f.Icon = $icoIdle } catch {}
    $script:dashForm = $f

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'; $tabs.Padding = New-Object System.Drawing.Point(16, 8)
    $tabs.Font = UiFont 10
    $f.Controls.Add($tabs)

    $script:dashTabLive     = New-Object System.Windows.Forms.TabPage (SvText 'M~ote')
    $script:dashTabSettings = New-Object System.Windows.Forms.TabPage (SvText 'Inst~ellningar')
    $script:dashTabPhone    = New-Object System.Windows.Forms.TabPage 'Telefon'
    $script:dashTabHistory  = New-Object System.Windows.Forms.TabPage 'Historik'
    $script:dashTabTrend    = New-Object System.Windows.Forms.TabPage 'Talanalys'
    $pages = @($script:dashTabLive, $script:dashTabPhone, $script:dashTabSettings, $script:dashTabHistory, $script:dashTabTrend)
    foreach ($t in $pages) {
        $t.BackColor = $script:uiBg
        $t.Padding = New-Object System.Windows.Forms.Padding(4)
        [void]$tabs.TabPages.Add($t)
    }

    # A TabPage keeps its phantom 200x100 default size until the TabControl has a
    # window handle AND the page has been selected once. Anchoring children against
    # that baseline makes every control over-grow the moment the page snaps to full
    # size: cards came out 1404 px wide inside an 836 px tab, and the history buttons
    # and the whole trend chart were pushed hundreds of pixels below the window.
    # Create the handle, then give every page its real bounds BEFORE building it.
    $f.CreateControl()
    foreach ($t in $pages) { $t.Bounds = $tabs.DisplayRectangle }

    Build-LiveTab     $script:dashTabLive
    Build-PhoneTab    $script:dashTabPhone
    Build-SettingsTab $script:dashTabSettings
    Build-HistoryTab  $script:dashTabHistory
    Build-TrendTab    $script:dashTabTrend

    # Refresh the live tab while the window is open (cheap; only the live tab redraws).
    $script:dashTimer = New-Object System.Windows.Forms.Timer
    $script:dashTimer.Interval = 1000
    $script:dashTimer.add_Tick({ try { Update-LiveTab } catch {}; try { Update-PhoneTab } catch {} })
    $f.add_Shown({ $script:dashTimer.Start() })
    $f.add_FormClosing({
        try { $script:dashTimer.Stop() } catch {}
        # Refresh history/trend next open; hide instead of dispose so reopening is instant
        $_.Cancel = $true
        $script:dashForm.Hide()
    })
    $f.Show()
    Refresh-HistoryList
    Refresh-TrendView
}

function New-UiCard($parent, [int]$x, [int]$y, [int]$w, [int]$h, [string]$title) {
    # A card = white panel + optional small-caps heading. Panels are cheap and give
    # the flat WinForms surface the grouping it otherwise lacks.
    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point($x, $y)
    $card.Size = New-Object System.Drawing.Size($w, $h)
    $card.BackColor = $script:uiCard
    $card.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
    $card.add_Paint({
        param($s, $e)
        $pen = New-Object System.Drawing.Pen $script:uiLine
        $e.Graphics.DrawRectangle($pen, 0, 0, ($s.Width - 1), ($s.Height - 1))
        $pen.Dispose()
    })
    if ($title) {
        $h1 = New-Object System.Windows.Forms.Label
        $h1.Text = $title.ToUpper(); $h1.Location = New-Object System.Drawing.Point(16, 12)
        $h1.AutoSize = $true; $h1.Font = UiFont 8 'Bold'; $h1.ForeColor = $script:uiMuted
        # Labels treat '&' as a mnemonic prefix and swallow it - "TALANDEL & LJUD"
        # rendered as "TALANDEL LJUD" with a stray underline.
        $h1.UseMnemonic = $false
        $card.Controls.Add($h1)
    }
    $parent.Controls.Add($card)
    return $card
}

function Build-LiveTab($tab) {
    $pad = 16
    # Lay out against the page's real size. The floors keep the harnesses (which
    # build into a bare TabPage) producing the same layout as the live window.
    $w = [math]::Max(720, $tab.ClientSize.Width)
    $tabH = [math]::Max(540, $tab.ClientSize.Height)
    $cardW = $w - 2 * $pad

    # --- Header card: status dot + headline + elapsed --------------------------
    $head = New-UiCard $tab $pad $pad $cardW 88 $null
    $head.Anchor = 'Top,Left,Right'
    $script:dashDot = New-Object System.Windows.Forms.Panel
    $script:dashDot.Location = New-Object System.Drawing.Point(18, 32); $script:dashDot.Size = New-Object System.Drawing.Size(14, 14)
    $script:dashDot.add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $b = New-Object System.Drawing.SolidBrush $s.BackColor
        $e.Graphics.FillEllipse($b, 0, 0, 13, 13); $b.Dispose()
    })
    $script:dashDot.BackColor = $script:uiMuted
    $head.Controls.Add($script:dashDot)
    $script:dashLiveStatus = New-Object System.Windows.Forms.Label
    # An AutoSize 15 pt label is 33 px tall, so the hint has to clear y=18+33 - at
    # y=48 the status label (added first, therefore painted on top) sliced the top
    # off "Motet spelas in".
    $script:dashLiveStatus.Location = New-Object System.Drawing.Point(42, 18); $script:dashLiveStatus.AutoSize = $true
    $script:dashLiveStatus.Font = UiFont 15 'Regular'; $script:dashLiveStatus.ForeColor = $script:uiInk
    $head.Controls.Add($script:dashLiveStatus)
    $script:dashLiveHint = New-Object System.Windows.Forms.Label
    $script:dashLiveHint.Location = New-Object System.Drawing.Point(44, 55); $script:dashLiveHint.AutoSize = $true
    $script:dashLiveHint.Font = UiFont 9; $script:dashLiveHint.ForeColor = $script:uiMuted
    $head.Controls.Add($script:dashLiveHint)

    # --- Live card: everything that only means something during a meeting ------
    $script:dashLiveCard = New-UiCard $tab $pad 116 $cardW 190 (SvText 'Talandel & ljud')
    $script:dashLiveCard.Anchor = 'Top,Left,Right'

    # Talk share: one owner-drawn bar (rounded, labelled) instead of nested panels.
    $script:dashTalkBar = New-Object System.Windows.Forms.Panel
    $script:dashTalkBar.Location = New-Object System.Drawing.Point(16, 40)
    $script:dashTalkBar.Size = New-Object System.Drawing.Size(($cardW - 32), 30)
    $script:dashTalkBar.Anchor = 'Top,Left,Right'
    $script:dashTalkBar.add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $wd = $s.ClientSize.Width; $ht = $s.ClientSize.Height
        $tot = [double]$script:meetSecsYou + [double]$script:meetSecsOthers
        $bgB = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(238, 240, 244))
        $g.FillRectangle($bgB, 0, 0, $wd, $ht); $bgB.Dispose()
        if ($tot -gt 0) {
            $youW = [int]($wd * ([double]$script:meetSecsYou / $tot))
            $b1 = New-Object System.Drawing.SolidBrush $script:uiAccent
            $b2 = New-Object System.Drawing.SolidBrush $script:uiAccent2
            $g.FillRectangle($b1, 0, 0, $youW, $ht)
            $g.FillRectangle($b2, $youW, 0, ($wd - $youW), $ht)
            $pct = [int][math]::Round(100 * [double]$script:meetSecsYou / $tot)
            $fnt = UiFont 8.5 'Bold'
            $wht = [System.Drawing.Brushes]::White
            if ($youW -gt 46)        { $g.DrawString("DU $pct%", $fnt, $wht, 8, ($ht/2 - 8)) }
            if (($wd - $youW) -gt 74) { $g.DrawString((SvText "~OVRIGA $((100-$pct))%"), $fnt, $wht, ($youW + 8), ($ht/2 - 8)) }
            $fnt.Dispose()
            $b1.Dispose(); $b2.Dispose()
        }
        $pen = New-Object System.Drawing.Pen $script:uiLine
        $g.DrawRectangle($pen, 0, 0, ($wd - 1), ($ht - 1)); $pen.Dispose()
    })
    $script:dashLiveCard.Controls.Add($script:dashTalkBar)
    $script:dashTalkLabel = New-Object System.Windows.Forms.Label
    $script:dashTalkLabel.Location = New-Object System.Drawing.Point(16, 74); $script:dashTalkLabel.AutoSize = $true
    $script:dashTalkLabel.Font = UiFont 9; $script:dashTalkLabel.ForeColor = $script:uiMuted
    $script:dashLiveCard.Controls.Add($script:dashTalkLabel)

    # Level meters: owner-drawn segments, so they read as VU rather than as a
    # Windows progress bar (which implies "task completion", not "loudness").
    function New-Meter($parent, [string]$caption, [int]$yy) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $caption; $l.Location = New-Object System.Drawing.Point(16, ($yy + 3))
        $l.Size = New-Object System.Drawing.Size(150, 20); $l.Font = UiFont 9; $l.ForeColor = $script:uiInk
        $m = New-Object System.Windows.Forms.Panel
        $m.Location = New-Object System.Drawing.Point(170, $yy)
        $m.Size = New-Object System.Drawing.Size(($cardW - 170 - 16 - 78), 18)
        $m.Anchor = 'Top,Left,Right'
        $m.Tag = 0.0
        $m.add_Paint({
            param($s, $e)
            $g = $e.Graphics
            $lvl = [double]$s.Tag
            $segs = 28; $sw = [int]($s.ClientSize.Width / $segs)
            $lit = [int][math]::Round($segs * [math]::Min(1.0, $lvl * 3.0))
            for ($i = 0; $i -lt $segs; $i++) {
                $col = if ($i -lt $lit) {
                    if ($i -gt $segs * 0.85) { $script:uiWarn } elseif ($i -gt $segs * 0.6) { [System.Drawing.Color]::FromArgb(220, 170, 60) } else { $script:uiAccent }
                } else { [System.Drawing.Color]::FromArgb(234, 237, 241) }
                $b = New-Object System.Drawing.SolidBrush $col
                $g.FillRectangle($b, ($i * $sw), 0, ($sw - 2), $s.ClientSize.Height)
                $b.Dispose()
            }
        })
        $t = New-Object System.Windows.Forms.Label
        $t.Location = New-Object System.Drawing.Point(($cardW - 16 - 70), ($yy + 2)); $t.Size = New-Object System.Drawing.Size(70, 20)
        $t.Font = UiFont 8.5 'Bold'; $t.Anchor = 'Top,Right'
        $parent.Controls.Add($l); $parent.Controls.Add($m); $parent.Controls.Add($t)
        return @{ meter = $m; tag = $t }
    }
    $mMic = New-Meter $script:dashLiveCard 'Din mikrofon' 108
    $mSys = New-Meter $script:dashLiveCard (SvText 'Datorljud (~ovriga)') 134
    $script:dashMicMeter = $mMic.meter; $script:dashMicTag = $mMic.tag
    $script:dashSysMeter = $mSys.meter; $script:dashSysTag = $mSys.tag

    $script:dashCroc = New-Object System.Windows.Forms.Label
    $script:dashCroc.Location = New-Object System.Drawing.Point(16, 160); $script:dashCroc.AutoSize = $true
    $script:dashCroc.Font = UiFont 9.5 'Bold'; $script:dashCroc.ForeColor = $script:uiWarn
    $script:dashLiveCard.Controls.Add($script:dashCroc)
    $script:dashScriptLbl = New-Object System.Windows.Forms.Label
    $script:dashScriptLbl.Location = New-Object System.Drawing.Point(($cardW - 16 - 240), 160)
    $script:dashScriptLbl.Size = New-Object System.Drawing.Size(240, 21)
    $script:dashScriptLbl.TextAlign = 'MiddleRight'; $script:dashScriptLbl.Anchor = 'Top,Right'
    $script:dashScriptLbl.Font = UiFont 9; $script:dashScriptLbl.ForeColor = $script:uiMuted
    $script:dashLiveCard.Controls.Add($script:dashScriptLbl)

    # --- Transcript card -------------------------------------------------------
    $trTop = 116 + 190 + 10
    $script:dashTrCard = New-UiCard $tab $pad $trTop $cardW ($tabH - $trTop - $pad) 'Transkript'
    $script:dashTrCard.Anchor = 'Top,Left,Right,Bottom'
    $script:dashTranscript = New-Object System.Windows.Forms.TextBox
    $script:dashTranscript.Multiline = $true; $script:dashTranscript.ReadOnly = $true; $script:dashTranscript.ScrollBars = 'Vertical'
    $script:dashTranscript.BorderStyle = 'None'; $script:dashTranscript.BackColor = $script:uiCard
    $script:dashTranscript.ForeColor = $script:uiInk
    $script:dashTranscript.Location = New-Object System.Drawing.Point(16, 36)
    $script:dashTranscript.Size = New-Object System.Drawing.Size(($cardW - 32), ($script:dashTrCard.Height - 52))
    $script:dashTranscript.Anchor = 'Top,Left,Right,Bottom'
    $script:dashTranscript.Font = New-Object System.Drawing.Font('Consolas', 9.5)
    $script:dashTrCard.Controls.Add($script:dashTranscript)

    # --- Idle panel: shown INSTEAD of the live/transcript cards when no meeting.
    # A dead 0% bar and empty meters look like a rendering bug; say what to do.
    $script:dashIdle = New-UiCard $tab $pad 116 $cardW ($tabH - 116 - $pad) $null
    $script:dashIdle.Anchor = 'Top,Left,Right,Bottom'
    $il = New-Object System.Windows.Forms.Label
    $il.Text = (SvText 'Ingen inspelning p~ag~ar')
    $il.Location = New-Object System.Drawing.Point(24, 30); $il.AutoSize = $true
    $il.Font = UiFont 13; $il.ForeColor = $script:uiInk
    $script:dashIdle.Controls.Add($il)
    $ih = New-Object System.Windows.Forms.Label
    $ih.Text = (SvText "Starta ett m~ote med Ctrl+Shift+M. D~a visas talandel, ljudniv~aer och`ntranskriptet h~er i realtid.`n`nCtrl+Shift h~eller du inne f~or att diktera. Ctrl+Shift+N ger en journalanteckning.")
    $ih.Location = New-Object System.Drawing.Point(26, 64); $ih.AutoSize = $true
    $ih.Font = UiFont 9.5; $ih.ForeColor = $script:uiMuted
    $script:dashIdle.Controls.Add($ih)

    Update-LiveTab
}

function Update-LiveTab {
    if (-not $script:dashLiveStatus) { return }
    $live = [bool]($script:meeting -or $script:meetFinishing)

    # Swap between the idle panel and the live cards (rather than showing empty ones)
    if ($script:dashIdle.Visible -eq $live) {
        $script:dashIdle.Visible = -not $live
        $script:dashLiveCard.Visible = $live
        $script:dashTrCard.Visible = $live
    }

    if ($script:meeting) {
        $el = (Get-Date) - $script:meetStart
        $script:dashLiveStatus.Text = ('{0:00}:{1:00}' -f [int]$el.TotalMinutes, ($el.Seconds))
        $script:dashLiveStatus.ForeColor = $script:uiInk
        $script:dashLiveHint.Text = (SvText 'M~otet spelas in - Ctrl+Shift+M avslutar')
        $script:dashDot.BackColor = $script:uiAccent
    } elseif ($script:meetFinishing) {
        $script:dashLiveStatus.Text = 'Transkriberar...'
        $script:dashLiveStatus.ForeColor = $script:uiInk
        $script:dashLiveHint.Text = (SvText 'M~otet bearbetas, ett ~ogonblick')
        $script:dashDot.BackColor = [System.Drawing.Color]::FromArgb(230, 180, 40)
    } else {
        $script:dashLiveStatus.Text = 'Diktatorn'
        $script:dashLiveStatus.ForeColor = $script:uiInk
        $script:dashLiveHint.Text = 'Redo'
        $script:dashDot.BackColor = $script:uiOk
    }
    $script:dashDot.Invalidate()
    if (-not $live) { return }   # nothing below is meaningful without a meeting

    $you = [double]$script:meetSecsYou; $oth = [double]$script:meetSecsOthers; $tot = $you + $oth
    $script:dashTalkBar.Invalidate()
    if ($tot -gt 0) {
        $script:dashTalkLabel.Text = (SvText ('Du {0:N1} min  |  ~Ovriga {1:N1} min' -f ($you / 60), ($oth / 60)))
    } else {
        $script:dashTalkLabel.Text = (SvText 'V~entar p~a tal...')
    }

    $rec = $script:meetRec
    $micL = 0.0; $sysL = 0.0; $micOk = $false; $sysOk = $false
    if ($script:meeting -and $rec) {
        try { $micL = [double]$rec.MicLevel; $sysL = [double]$rec.SysLevel } catch {}
        try { $micOk = ($rec.MicCaptured -and $rec.MicPeak -ge 0.01); $sysOk = ($rec.SysSeconds -ge 2) } catch {}
    }
    $script:dashMicMeter.Tag = $micL; $script:dashMicMeter.Invalidate()
    $script:dashSysMeter.Tag = $sysL; $script:dashSysMeter.Invalidate()
    $script:dashMicTag.Text = $(if ($micOk) { 'OK' } else { 'TYST?' })
    $script:dashMicTag.ForeColor = $(if ($micOk) { $script:uiOk } else { $script:uiWarn })
    $script:dashSysTag.Text = $(if ($sysOk) { 'OK' } else { 'TYST?' })
    $script:dashSysTag.ForeColor = $(if ($sysOk) { $script:uiOk } else { $script:uiWarn })

    $script:dashCroc.Text = ''
    if ($script:meeting -and $script:chunkListYou -and $script:chunkListYou.Count -ge 1) {
        $win = [math]::Max(1, [math]::Ceiling($crocWinSec / $chunkSec))
        $n = $script:chunkListYou.Count; $a = [math]::Max(0, $n - $win)
        $wy = 0.0; $wo = 0.0
        for ($k = $a; $k -lt $n; $k++) { $wy += $script:chunkListYou[$k]; $wo += $script:chunkListOthers[$k] }
        $wt = $wy + $wo
        if ($wt -gt 0 -and (100 * $wy / $wt) -ge $crocPct) {
            $script:dashCroc.Text = (SvText 'Krokodilvarning - stor mun, sm~a ~oron. Lyssna mer.')
        }
    }

    if ($script:scriptChecks -and @($script:scriptChecks).Count -gt 0) {
        $done = @($script:scriptChecks | Where-Object { $_.Checked }).Count
        $script:dashScriptLbl.Text = (SvText "S~eljscript: $done / $(@($script:scriptChecks).Count) avklarat")
    } else { $script:dashScriptLbl.Text = '' }

    if ($script:meetLines -and $script:meetLines.Count -gt 0) {
        $tail = @($script:meetLines | Select-Object -Last 25) -join "`r`n"
        if ($script:dashTranscript.Text -ne $tail) {
            $script:dashTranscript.Text = $tail
            $script:dashTranscript.SelectionStart = $script:dashTranscript.Text.Length
            $script:dashTranscript.ScrollToCaret()
        }
    } elseif ($script:dashTranscript.Text) { $script:dashTranscript.Text = '' }
}
function Build-SettingsTab($tab) {
    $panel = New-Object System.Windows.Forms.TableLayoutPanel
    $panel.Dock = 'Fill'; $panel.ColumnCount = 2; $panel.AutoScroll = $true
    $panel.Padding = '10,10,10,10'
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute', 210)))
    [void]$panel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
    $tab.Controls.Add($panel)

    # Add a labelled dropdown. $items = display strings, $tags = matching values,
    # $current = value to preselect, $onPick = { param($val) ... }. Handler is wired
    # AFTER preselecting, so loading the current value doesn't fire a redundant Set-*.
    function Add-Row($label, $items, $tags, $current, $onPick) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = (SvText $label); $lbl.AutoSize = $false; $lbl.Width = 210; $lbl.Height = 30
        $lbl.TextAlign = 'MiddleLeft'; $lbl.Font = UiFont 10; $lbl.ForeColor = $script:uiInk
        $cb = New-Object System.Windows.Forms.ComboBox
        $cb.DropDownStyle = 'DropDownList'; $cb.Width = 470
        $cb.Font = UiFont 10; $cb.FlatStyle = 'Flat'; $cb.Margin = '3,4,3,4'
        foreach ($it in $items) { [void]$cb.Items.Add((SvText ([string]$it))) }
        $cb.Tag = @{ tags = $tags; onPick = $onPick }
        $ix = [array]::IndexOf($tags, $current); if ($ix -lt 0) { $ix = 0 }
        if ($cb.Items.Count -gt 0) { $cb.SelectedIndex = $ix }
        $cb.add_SelectedIndexChanged({
            $meta = $this.Tag
            & $meta.onPick $meta.tags[$this.SelectedIndex]
        })
        $panel.Controls.Add($lbl); $panel.Controls.Add($cb)
        return $cb
    }

    # Section heading spanning both columns - nine identical rows in a row read as
    # one undifferentiated wall; the headings give the eye somewhere to rest.
    function Add-Head($text, [int]$topGap) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = (SvText $text).ToUpper()
        $l.AutoSize = $false; $l.Height = (20 + $topGap); $l.Width = 400
        $l.TextAlign = 'BottomLeft'; $l.Font = UiFont 8 'Bold'; $l.ForeColor = $script:uiMuted
        $l.UseMnemonic = $false; $l.Margin = '3,0,3,2'
        $panel.Controls.Add($l)
        $panel.SetColumnSpan($l, 2)
    }

    Add-Head 'Ljud & modell' 0
    # Microphone
    $micNames = @($script:micNames); $micIdx = @(0..([math]::Max(0,$micNames.Count-1)))
    [void](Add-Row 'Mikrofon' $micNames $micIdx $script:micDevice { param($v) Set-MicDevice ([int]$v) })
    # Model
    $mLabels = @($modelChoices.Keys); $mFiles = @($modelChoices.Values)
    [void](Add-Row 'Modell (kvalitet)' $mLabels $mFiles $script:modelFile { param($v) Set-Model ([string]$v) })
    # Backend
    [void](Add-Row 'Transkribering' @('Lokal (GPU, privat)','Groq moln (snabbt)') @('local','groq') $script:backend { param($v) Set-Backend ([string]$v) })
    # GPU (only if more than one adapter)
    if ($script:adapters.Count -gt 1) {
        [void](Add-Row 'Grafikkort' @($script:adapters) @($script:adapters) $script:adapter { param($v) Set-Gpu ([string]$v) })
    }
    Add-Head 'M~ote' 14
    # Meeting mode
    [void](Add-Row 'M~otestranskribering' @('Live (v~exande)','Efter m~otet') @('live','deferred') $script:meetMode { param($v) Set-MeetMode ([string]$v) })
    # Meeting language
    [void](Add-Row 'M~otesspr~ak' @('Svenska','Engelska') @('sv','en') $script:meetLang { param($v) Set-MeetLang ([string]$v) })

    Add-Head 'Analys & data' 14
    # Coach engine
    [void](Add-Row 'Coach-motor' @('Groq (gratis moln)','Ollama (lokal)','OpenRouter') @('groq','ollama','openrouter') $script:coach { param($v) Set-Coach ([string]$v) })
    # Talanalys
    [void](Add-Row 'Talanalys' @('Av','Statistik','AI-coach') @('off','stats','coach') $script:talanalys { param($v) Set-Talanalys ([string]$v) })

    # Keep audio checkbox
    $lblKA = New-Object System.Windows.Forms.Label
    $lblKA.Text = (SvText "Spara m~otesljud"); $lblKA.Width = 210; $lblKA.Height = 30; $lblKA.TextAlign = 'MiddleLeft'
    $lblKA.Font = UiFont 10; $lblKA.ForeColor = $script:uiInk
    $chkKA = New-Object System.Windows.Forms.CheckBox
    $chkKA.Text = (SvText "Beh~all r~aljud i $keepAudioDays dagar (f~or ~aterskapning)")
    $chkKA.AutoSize = $true; $chkKA.Checked = $script:keepAudio
    $chkKA.Font = UiFont 10; $chkKA.Margin = '3,8,3,3'; $chkKA.ForeColor = $script:uiInk
    $chkKA.add_CheckedChanged({ Set-KeepAudio $this.Checked })
    $panel.Controls.Add($lblKA); $panel.Controls.Add($chkKA)

    # API key buttons
    $lblKeys = New-Object System.Windows.Forms.Label
    $lblKeys.Text = 'API-nycklar'; $lblKeys.Width = 210; $lblKeys.Height = 36; $lblKeys.TextAlign = 'MiddleLeft'
    $lblKeys.Font = UiFont 10; $lblKeys.ForeColor = $script:uiInk
    $keyPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $keyPanel.AutoSize = $true; $keyPanel.WrapContents = $false
    $bGroq = New-Object System.Windows.Forms.Button
    $bGroq.Text = 'Groq-nyckel...'; $bGroq.Width = 130; $bGroq.Height = 30
    $bGroq.FlatStyle = 'Flat'; $bGroq.BackColor = $script:uiCard; $bGroq.Font = UiFont 9.5
    $bGroq.FlatAppearance.BorderColor = $script:uiLine
    $bGroq.add_Click({
        Add-Type -AssemblyName Microsoft.VisualBasic
        $val = [Microsoft.VisualBasic.Interaction]::InputBox('Klistra in din Groq API-nyckel (gsk_...):', 'Groq API-nyckel', (Get-GroqKey))
        if ($val) { try { [System.IO.File]::WriteAllText($groqKeyFile, $val.Trim()); $tray.ShowBalloonTip(2500, 'Diktatorn', 'Groq-nyckel sparad.', 'Info') } catch {} }
    })
    $bOR = New-Object System.Windows.Forms.Button
    $bOR.Text = 'OpenRouter-nyckel...'; $bOR.Width = 160; $bOR.Height = 30
    $bOR.FlatStyle = 'Flat'; $bOR.BackColor = $script:uiCard; $bOR.Font = UiFont 9.5
    $bOR.FlatAppearance.BorderColor = $script:uiLine
    $bOR.add_Click({
        Add-Type -AssemblyName Microsoft.VisualBasic
        $val = [Microsoft.VisualBasic.Interaction]::InputBox('Klistra in din OpenRouter API-nyckel (sk-or-...):', 'OpenRouter API-nyckel', (Get-CoachKey 'openrouter'))
        if ($val) { try { [System.IO.File]::WriteAllText($openrouterKeyFile, $val.Trim()); $tray.ShowBalloonTip(2500, 'Diktatorn', 'OpenRouter-nyckel sparad.', 'Info') } catch {} }
    })
    [void]$keyPanel.Controls.Add($bGroq); [void]$keyPanel.Controls.Add($bOR)
    $panel.Controls.Add($lblKeys); $panel.Controls.Add($keyPanel)
}
function Build-PhoneTab($tab) {
    $pad = 16
    $w = [math]::Max(720, $tab.ClientSize.Width)
    $cardW = $w - 2 * $pad

    if (-not $script:taTillganglig) {
        $c = New-UiCard $tab $pad $pad $cardW 150 (SvText 'Telefon')
        $c.Anchor = 'Top,Left,Right'
        $l = New-Object System.Windows.Forms.Label
        $l.Text = (SvText "Telefondelen ~er inte laddad.`n`nDen kr~ever Telefonassistent.ps1 bredvid Diktatorn.ps1, NAudio och`nVB-CABLE. Utan den fungerar resten av appen som vanligt.")
        $l.Location = New-Object System.Drawing.Point(16, 44); $l.AutoSize = $true
        $l.Font = UiFont 9.5; $l.ForeColor = $script:uiMuted
        $c.Controls.Add($l)
        return
    }

    # --- Ring upp --------------------------------------------------------------
    $dial = New-UiCard $tab $pad $pad $cardW 176 (SvText 'Ring upp')
    $dial.Anchor = 'Top,Left,Right'

    $script:dashDialBox = New-Object System.Windows.Forms.TextBox
    $script:dashDialBox.Location = New-Object System.Drawing.Point(16, 44)
    $script:dashDialBox.Size = New-Object System.Drawing.Size(300, 34)
    $script:dashDialBox.Font = UiFont 14
    $script:dashDialBox.BorderStyle = 'FixedSingle'
    # Enter ringer - att tvinga fram musen for varje samtal ar hela grejen vi ville bort fran.
    $script:dashDialBox.add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Invoke-Dial }
    })
    $script:dashDialBox.add_TextChanged({ Update-DialPreview })
    $dial.Controls.Add($script:dashDialBox)

    $script:dashDialBtn = New-Object System.Windows.Forms.Button
    $script:dashDialBtn.Text = 'Ring'
    $script:dashDialBtn.Location = New-Object System.Drawing.Point(328, 44)
    $script:dashDialBtn.Size = New-Object System.Drawing.Size(96, 34)
    $script:dashDialBtn.Font = UiFont 10 'Bold'
    $script:dashDialBtn.FlatStyle = 'Flat'
    $script:dashDialBtn.BackColor = $script:uiAccent
    $script:dashDialBtn.ForeColor = [System.Drawing.Color]::White
    $script:dashDialBtn.FlatAppearance.BorderColor = $script:uiAccent
    $script:dashDialBtn.add_Click({ Invoke-Dial })
    $dial.Controls.Add($script:dashDialBtn)

    $lblApp = New-Object System.Windows.Forms.Label
    $lblApp.Text = (SvText 'L~emna ~over till'); $lblApp.Location = New-Object System.Drawing.Point(($cardW - 16 - 230 - 106), 51)
    $lblApp.AutoSize = $true; $lblApp.Font = UiFont 9.5; $lblApp.ForeColor = $script:uiInk
    $lblApp.Anchor = 'Top,Right'
    $dial.Controls.Add($lblApp)

    $script:dashDialApp = New-Object System.Windows.Forms.ComboBox
    $script:dashDialApp.DropDownStyle = 'DropDownList'
    $script:dashDialApp.Location = New-Object System.Drawing.Point(($cardW - 16 - 230), 47)
    $script:dashDialApp.Size = New-Object System.Drawing.Size(230, 28)
    $script:dashDialApp.Anchor = 'Top,Right'
    $script:dashDialApp.Font = UiFont 9.5; $script:dashDialApp.FlatStyle = 'Flat'
    $script:dashCallApps = @(Get-CallApps)
    foreach ($a in $script:dashCallApps) { [void]$script:dashDialApp.Items.Add($a.Namn) }
    $cur = Get-CallApp
    $ix = 0
    for ($i = 0; $i -lt $script:dashCallApps.Count; $i++) { if ($cur -and $script:dashCallApps[$i].Id -eq $cur.Id) { $ix = $i } }
    if ($script:dashDialApp.Items.Count -gt 0) { $script:dashDialApp.SelectedIndex = $ix }
    # Wire AFTER preselecting, same as the settings dropdowns - loading a value
    # must not count as the user picking one.
    $script:dashDialApp.add_SelectedIndexChanged({
        Set-CallApp $script:dashCallApps[$this.SelectedIndex].Id
        Update-DialPreview
    })
    $dial.Controls.Add($script:dashDialApp)

    $script:dashDialHint = New-Object System.Windows.Forms.Label
    $script:dashDialHint.Location = New-Object System.Drawing.Point(16, 92)
    $script:dashDialHint.Size = New-Object System.Drawing.Size(($cardW - 32), 40)
    $script:dashDialHint.Anchor = 'Top,Left,Right'
    $script:dashDialHint.Font = UiFont 9; $script:dashDialHint.ForeColor = $script:uiMuted
    $dial.Controls.Add($script:dashDialHint)

    $script:dashDialNote = New-Object System.Windows.Forms.Label
    # Sag rakt ut vad knappen gor. Den kopplar inte upp nagot samtal sjalv, och en
    # knapp som heter Ring men lamnar over ar bara arlig om den sager det.
    $script:dashDialNote.Text = (SvText 'Numret l~emnas ~over till samtalsappen - sj~elva uppringningen g~or du d~er. Ljudet g~ar som vanligt via kabeln.')
    $script:dashDialNote.Location = New-Object System.Drawing.Point(16, 136)
    $script:dashDialNote.Size = New-Object System.Drawing.Size(($cardW - 32), 22)
    $script:dashDialNote.Anchor = 'Top,Left,Right'
    $script:dashDialNote.Font = UiFont 8.5; $script:dashDialNote.ForeColor = $script:uiAccent2
    $dial.Controls.Add($script:dashDialNote)

    # --- AI-assistenten --------------------------------------------------------
    $ai = New-UiCard $tab $pad 208 $cardW 150 (SvText 'AI-assistent i samtalet')
    $ai.Anchor = 'Top,Left,Right'

    $script:dashPhoneDot = New-Object System.Windows.Forms.Panel
    $script:dashPhoneDot.Location = New-Object System.Drawing.Point(18, 48)
    $script:dashPhoneDot.Size = New-Object System.Drawing.Size(14, 14)
    $script:dashPhoneDot.BackColor = $script:uiMuted
    $script:dashPhoneDot.add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $b = New-Object System.Drawing.SolidBrush $s.BackColor
        $e.Graphics.FillEllipse($b, 0, 0, 13, 13); $b.Dispose()
    })
    $ai.Controls.Add($script:dashPhoneDot)

    $script:dashPhoneStatus = New-Object System.Windows.Forms.Label
    $script:dashPhoneStatus.Location = New-Object System.Drawing.Point(42, 44)
    $script:dashPhoneStatus.AutoSize = $true
    $script:dashPhoneStatus.Font = UiFont 11; $script:dashPhoneStatus.ForeColor = $script:uiInk
    $ai.Controls.Add($script:dashPhoneStatus)

    $script:dashPhoneHint = New-Object System.Windows.Forms.Label
    $script:dashPhoneHint.Location = New-Object System.Drawing.Point(44, 70)
    $script:dashPhoneHint.Size = New-Object System.Drawing.Size(($cardW - 60), 22)
    $script:dashPhoneHint.Anchor = 'Top,Left,Right'
    $script:dashPhoneHint.Font = UiFont 9; $script:dashPhoneHint.ForeColor = $script:uiMuted
    $ai.Controls.Add($script:dashPhoneHint)

    $script:dashPhoneBtn = New-Object System.Windows.Forms.Button
    $script:dashPhoneBtn.Location = New-Object System.Drawing.Point(16, 104)
    $script:dashPhoneBtn.Size = New-Object System.Drawing.Size(150, 32)
    $script:dashPhoneBtn.Font = UiFont 9.5; $script:dashPhoneBtn.FlatStyle = 'Flat'
    $script:dashPhoneBtn.BackColor = $script:uiCard
    $script:dashPhoneBtn.FlatAppearance.BorderColor = $script:uiLine
    $script:dashPhoneBtn.add_Click({
        if ($script:taBridge) { Stop-Telefonassistent } else { [void](Start-Telefonassistent $script:taRoll 400) }
        Update-PhoneTab
    })
    $ai.Controls.Add($script:dashPhoneBtn)

    $btnTon = New-Object System.Windows.Forms.Button
    $btnTon.Text = (SvText 'Testa kabeln')
    $btnTon.Location = New-Object System.Drawing.Point(174, 104)
    $btnTon.Size = New-Object System.Drawing.Size(130, 32)
    $btnTon.Font = UiFont 9.5; $btnTon.FlatStyle = 'Flat'
    $btnTon.BackColor = $script:uiCard
    $btnTon.FlatAppearance.BorderColor = $script:uiLine
    $btnTon.add_Click({ try { $script:taBridge.Testton() } catch {} })
    $ai.Controls.Add($btnTon)

    Update-DialPreview
    Update-PhoneTab
}

# Live preview of what the Ring button will actually hand over. Catching a
# half-typed number here beats discovering it in the call app.
function Update-DialPreview {
    if (-not $script:dashDialHint) { return }
    $raw = $script:dashDialBox.Text
    $app = $null
    if ($script:dashCallApps -and $script:dashDialApp.SelectedIndex -ge 0) {
        $app = $script:dashCallApps[$script:dashDialApp.SelectedIndex]
    }
    if (-not $raw.Trim()) {
        $script:dashDialHint.Text = (SvText 'Skriv ett nummer - 070-123 45 67 eller +46701234567. Enter ringer.')
        $script:dashDialHint.ForeColor = $script:uiMuted
        $script:dashDialBtn.Enabled = $false
        return
    }
    $e164 = Format-PhoneNumber $raw
    if ($e164) {
        $script:dashDialHint.Text = (SvText ("Ringer {0} via {1}" -f $e164, $(if ($app) { $app.Namn } else { '?' })))
        $script:dashDialHint.ForeColor = $script:uiOk
        $script:dashDialBtn.Enabled = $true
    } else {
        $script:dashDialHint.Text = (SvText 'Inget giltigt nummer ~en.')
        $script:dashDialHint.ForeColor = $script:uiWarn
        $script:dashDialBtn.Enabled = $false
    }
}

function Invoke-Dial {
    if (-not $script:dashDialBox) { return }
    $app = $null
    if ($script:dashCallApps -and $script:dashDialApp.SelectedIndex -ge 0) {
        $app = $script:dashCallApps[$script:dashDialApp.SelectedIndex]
    }
    $nr = Start-PhoneHandover $script:dashDialBox.Text $app
    if ($nr) {
        $script:dashDialHint.Text = (SvText ("{0} ~overl~emnat till {1} - tryck Ring d~er." -f $nr, $(if ($app) { $app.Namn } else { '?' })))
        $script:dashDialHint.ForeColor = $script:uiInk
    }
}

function Update-PhoneTab {
    if (-not $script:dashPhoneStatus) { return }
    if ($script:taBridge) {
        $script:dashPhoneDot.BackColor = $script:uiAccent
        $script:dashPhoneStatus.Text = (SvText 'Aktiv - AI:n svarar i samtalet')
        $turer = try { [int]$script:taBridge.TurerKorda } catch { 0 }
        $script:dashPhoneHint.Text = (SvText ("Roll: {0}.  {1} turer k~orda." -f $script:taRoll, $turer))
        $script:dashPhoneBtn.Text = (SvText 'Stoppa assistenten')
    } else {
        $script:dashPhoneDot.BackColor = $script:uiOk
        $script:dashPhoneStatus.Text = 'Av'
        $ut = try { (Get-TaValdUtgang).Namn } catch { $null }
        $script:dashPhoneHint.Text = $(if ($ut) { (SvText ("Utg~ang: {0}" -f $ut)) } else { (SvText 'Ingen ljudutg~ang vald.') })
        $script:dashPhoneBtn.Text = (SvText 'Starta assistenten')
    }
    $script:dashPhoneDot.Invalidate()
}

# Re-transcribe a saved meeting's archived chunk audio in the chosen language.
# Turns the manual recovery script into a feature; hardened against the broken
# header of whichever chunk was recording when a meeting ended abruptly.
function Rebuild-Transcript($audioDir, $lang, $outFile, $statusLabel) {
    $wavs = @(Get-ChildItem $audioDir -Filter 'chunk_*.wav' -ErrorAction SilentlyContinue)
    $items = @()
    foreach ($w in $wavs) {
        if ($w.Name -match 'chunk_(\d+)_(sys|mic)\.wav') {
            $items += [pscustomobject]@{ idx = [int]$Matches[1]; kind = $Matches[2]; wav = $w.FullName;
                label = $(if ($Matches[2] -eq 'mic') { $labelYou } else { $labelOthers }) }
        }
    }
    $items = @($items | Sort-Object idx, kind)   # sys before mic within a chunk
    if ($items.Count -eq 0) { throw 'Inget chunk-ljud i mappen' }
    $lines = @("Mote (aterskapat $(Get-Date -Format 'yyyy-MM-dd HH:mm'), sprak: $lang)", ('=' * 60), '')
    $tmp = Join-Path $env:TEMP 'rebuild_clean.wav'
    $done = 0
    foreach ($c in $items) {
        $done++
        if ($statusLabel) { $statusLabel.Text = "Transkriberar $done / $($items.Count)..."; [System.Windows.Forms.Application]::DoEvents() }
        if ((Get-Item $c.wav).Length -lt 16000) { continue }
        Remove-Item $tmp -ErrorAction SilentlyContinue
        try { [AudioPrep]::Clean($c.wav, $tmp) }
        catch {
            try {  # salvage the abruptly-ended chunk: rewrap raw bytes past the header
                $b = [System.IO.File]::ReadAllBytes($c.wav)
                $w = New-Object NAudio.Wave.WaveFileWriter($tmp, (New-Object NAudio.Wave.WaveFormat(16000,16,1)))
                $w.Write($b, 44, $b.Length - 44); $w.Dispose()
            } catch { continue }
        }
        if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt 16000) { continue }
        try {
            if ($script:backend -eq 'groq') {
                $key = Get-GroqKey; if (-not $key) { throw 'Ingen Groq-nyckel' }
                $text = ([Cloud]::Transcribe($key, $tmp, $groqModel, $lang)).Trim()
            } else {
                $seg = Transcribe-File -model $script:model -path $tmp -language $lang
                $text = ((($seg | ForEach-Object { $_.Text }) -join ' ').Trim()) -replace '\s+', ' '
            }
        } catch { continue }
        if ($text -and $text -notmatch '^[\s\.\-\!\?]*$') {
            $ts = '{0:00}:{1:00}' -f [math]::Floor($c.idx * 30 / 60), (($c.idx * 30) % 60)
            $lines += "[00:$ts] $($c.label): $text"
        }
    }
    [System.IO.File]::WriteAllText($outFile, ($lines -join "`r`n"), [System.Text.UTF8Encoding]::new($true))
}

function Build-HistoryTab($tab) {
    $w = [math]::Max(720, $tab.ClientSize.Width)
    $h = [math]::Max(540, $tab.ClientSize.Height)
    $barTop = $h - 12 - 40
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(12, 12)
    $lv.Size = New-Object System.Drawing.Size(($w - 24), ($barTop - 24))
    $lv.Anchor = 'Top,Left,Right,Bottom'
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.MultiSelect = $false
    $lv.Font = UiFont 9.5; $lv.BorderStyle = 'FixedSingle'; $lv.BackColor = $script:uiCard
    $lv.ForeColor = $script:uiInk; $lv.GridLines = $false; $lv.HeaderStyle = 'Nonclickable'
    [void]$lv.Columns.Add((SvText 'M~ote'), 320); [void]$lv.Columns.Add('Datum', 160); [void]$lv.Columns.Add('Ljud sparat', 200)
    $tab.Controls.Add($lv)
    $script:dashHistList = $lv

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.Location = New-Object System.Drawing.Point(12, $barTop); $bar.Size = New-Object System.Drawing.Size(($w - 24), 40)
    $bar.Anchor = 'Left,Right,Bottom'
    $tab.Controls.Add($bar)
    function HistBtn($text, $w, $handler) {
        $b = New-Object System.Windows.Forms.Button; $b.Text = (SvText $text); $b.Width = $w; $b.Height = 32
        $b.Font = UiFont 9.5; $b.FlatStyle = 'Flat'; $b.BackColor = $script:uiCard
        $b.FlatAppearance.BorderColor = $script:uiLine
        $b.add_Click($handler); [void]$bar.Controls.Add($b); return $b
    }
    [void](HistBtn 'Uppdatera' 95 { Refresh-HistoryList })
    [void](HistBtn '~Oppna transkript' 140 {
        $it = @($script:dashHistList.SelectedItems)[0]
        if ($it -and $it.Tag.txt -and (Test-Path $it.Tag.txt)) { Invoke-Item $it.Tag.txt }
    })
    [void](HistBtn '~Oppna ljudmapp' 130 {
        $it = @($script:dashHistList.SelectedItems)[0]
        if ($it -and $it.Tag.audio -and (Test-Path $it.Tag.audio)) { Invoke-Item $it.Tag.audio }
        else { [void][System.Windows.Forms.MessageBox]::Show((SvText 'Inget sparat ljud f~or det h~er m~otet.'), 'Diktatorn') }
    })
    [void](HistBtn '~Aterskapa transkript...' 180 {
        $it = @($script:dashHistList.SelectedItems)[0]
        if (-not $it -or -not $it.Tag.audio -or -not (Test-Path $it.Tag.audio)) {
            [void][System.Windows.Forms.MessageBox]::Show((SvText 'Det h~er m~otet har inget sparat ljud att ~aterskapa fr~an. Sl~a p~a "Spara m~otesljud" f~or framtida m~oten.'), 'Diktatorn'); return
        }
        $lang = Show-MeetLangPrompt
        if (-not $lang) { return }
        $out = Join-Path $outDir ([System.IO.Path]::GetFileNameWithoutExtension($it.Tag.audio) + '_aterskapad.txt')
        $script:dashForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Rebuild-Transcript $it.Tag.audio $lang $out $script:dashHistStatus
            $script:dashHistStatus.Text = 'Klart.'
            Refresh-HistoryList
            Invoke-Item $out
        } catch {
            Write-Log "Aterskapa: $($_.Exception.Message)"
            [void][System.Windows.Forms.MessageBox]::Show((SvText "Kunde inte ~aterskapa: $($_.Exception.Message)"), 'Diktatorn')
            $script:dashHistStatus.Text = 'Misslyckades.'
        } finally { $script:dashForm.Cursor = [System.Windows.Forms.Cursors]::Default }
    })
    $script:dashHistStatus = New-Object System.Windows.Forms.Label
    $script:dashHistStatus.AutoSize = $true; $script:dashHistStatus.Margin = '12,9,0,0'
    $script:dashHistStatus.Font = UiFont 9; $script:dashHistStatus.ForeColor = $script:uiMuted
    [void]$bar.Controls.Add($script:dashHistStatus)
}

function Refresh-HistoryList {
    if (-not $script:dashHistList) { return }
    $script:dashHistList.Items.Clear()
    $txts = @(Get-ChildItem (Join-Path $outDir 'Mote_*.txt') -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($t in $txts) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($t.Name) -replace '_aterskapad$', ''
        $audioDir = Join-Path $audioArchive $base
        $hasAudio = Test-Path $audioDir
        $li = New-Object System.Windows.Forms.ListViewItem($t.Name)
        [void]$li.SubItems.Add($t.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
        [void]$li.SubItems.Add($(if ($hasAudio) { "Ja ($(@(Get-ChildItem $audioDir -Filter *.wav -ErrorAction SilentlyContinue).Count) filer)" } else { '-' }))
        $li.Tag = @{ txt = $t.FullName; audio = $(if ($hasAudio) { $audioDir } else { $null }) }
        [void]$script:dashHistList.Items.Add($li)
    }
}
function Build-TrendTab($tab) {
    $w = [math]::Max(720, $tab.ClientSize.Width)
    $h = [math]::Max(540, $tab.ClientSize.Height)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = New-Object System.Drawing.Point(12, 12); $lv.Size = New-Object System.Drawing.Size(($w - 24), 250)
    $lv.Anchor = 'Top,Left,Right'; $lv.View = 'Details'; $lv.FullRowSelect = $true
    $lv.Font = UiFont 9.5; $lv.BorderStyle = 'FixedSingle'; $lv.BackColor = $script:uiCard
    $lv.ForeColor = $script:uiInk; $lv.GridLines = $false; $lv.HeaderStyle = 'Nonclickable'
    [void]$lv.Columns.Add('Datum', 140); [void]$lv.Columns.Add((SvText 'L~engd (min)'), 95)
    [void]$lv.Columns.Add('Talandel %', 95); [void]$lv.Columns.Add('Utfyllnad/min', 110)
    [void]$lv.Columns.Add((SvText 'Fr~agor'), 75); [void]$lv.Columns.Add((SvText 'L~engsta monolog'), 130)
    $tab.Controls.Add($lv); $script:dashTrendList = $lv

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = (SvText 'Talandel per m~ote - r~ott ~er ~over 70%, krokodilgr~ensen')
    $lbl.Location = New-Object System.Drawing.Point(12, 272)
    $lbl.AutoSize = $true; $lbl.Font = UiFont 9; $lbl.ForeColor = $script:uiMuted
    $tab.Controls.Add($lbl)

    $chart = New-Object System.Windows.Forms.Panel
    $chart.Location = New-Object System.Drawing.Point(12, 294); $chart.Size = New-Object System.Drawing.Size(($w - 24), ($h - 294 - 12))
    $chart.Anchor = 'Top,Left,Right,Bottom'; $chart.BackColor = $script:uiCard; $chart.BorderStyle = 'FixedSingle'
    $chart.add_Paint({
        param($s, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $w = $s.ClientSize.Width; $h = $s.ClientSize.Height; $pad = 8
        $rows = @($script:trendRows)
        if ($rows.Count -eq 0) {
            $fnt = UiFont 10
            $br = New-Object System.Drawing.SolidBrush $script:uiMuted
            $g.DrawString((SvText 'Ingen data ~en - k~or ett m~ote med talanalys p~a.'), $fnt, $br, 14, ($h/2 - 10))
            $fnt.Dispose(); $br.Dispose(); return
        }
        # Room at the bottom for date labels, at the top for the value above each bar.
        $axis = 22; $cap = 16
        $plotH = $h - $pad - $axis - $cap
        $base = $h - $pad - $axis
        $fntS = New-Object System.Drawing.Font('Segoe UI', 7)
        $brMuted = New-Object System.Drawing.SolidBrush $script:uiMuted

        # 70% crocodile reference line
        $y70 = $base - ($plotH * 0.70)
        $penRef = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(206, 210, 216)); $penRef.DashStyle = 'Dash'
        $g.DrawLine($penRef, $pad, $y70, ($w - $pad - 30), $y70)
        $g.DrawString('70%', $fntS, $brMuted, ($w - $pad - 28), ($y70 - 8))
        $penBase = New-Object System.Drawing.Pen $script:uiLine
        $g.DrawLine($penBase, $pad, $base, ($w - $pad), $base)

        # Slim, centred bars - a full-slot block reads as a colour field, not a value.
        $show = @($rows | Select-Object -Last 24)
        $slot = [double]($w - 2 * $pad) / $show.Count
        $bw = [int][math]::Max(6, [math]::Min(46, $slot - 12))
        $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'
        for ($i = 0; $i -lt $show.Count; $i++) {
            $share = [double]$show[$i].share
            $bh = [int]($plotH * ($share / 100.0))
            $cx = $pad + ($i + 0.5) * $slot
            $x = [int]($cx - $bw / 2)
            $col = if ($share -ge 70) { $script:uiWarn } else { $script:uiAccent }
            $br = New-Object System.Drawing.SolidBrush $col
            $g.FillRectangle($br, $x, ($base - $bh), $bw, $bh)
            $br.Dispose()
            $g.DrawString([string][int]$share, $fntS, $brMuted, $cx, ($base - $bh - 13), $fmt)
            # Dates only while they still fit; crowding them is worse than dropping them.
            if ($slot -ge 46) {
                $d = ([string]$show[$i].datum) -replace '^\d{4}-', '' -replace ' .*$', ''
                $g.DrawString($d, $fntS, $brMuted, $cx, ($base + 5), $fmt)
            }
        }
        $fmt.Dispose(); $fntS.Dispose(); $brMuted.Dispose(); $penBase.Dispose(); $penRef.Dispose()
    })
    $tab.Controls.Add($chart); $script:dashTrendChart = $chart
    Refresh-TrendView
}

function Refresh-TrendView {
    if (-not $script:dashTrendList) { return }
    $script:trendRows = @()
    $script:dashTrendList.Items.Clear()
    if (Test-Path $trendCsv) {
        $lines = @(Get-Content $trendCsv -Encoding UTF8 | Select-Object -Skip 1 | Where-Object { $_ -and ($_ -match ';') })
        foreach ($ln in $lines) {
            $c = $ln -split ';'
            if ($c.Count -lt 6) { continue }
            $script:trendRows += [pscustomobject]@{ datum=$c[0]; mins=$c[1]; share=[double]($c[2]); fill=$c[3]; q=$c[4]; monolog=$c[5] }
            $li = New-Object System.Windows.Forms.ListViewItem($c[0])
            foreach ($v in @($c[1], $c[2], $c[3], $c[4], $c[5])) { [void]$li.SubItems.Add([string]$v) }
            if ([double]$c[2] -ge 70) { $li.ForeColor = $script:uiWarn }
            [void]$script:dashTrendList.Items.Add($li)
        }
    }
    if ($script:dashTrendChart) { $script:dashTrendChart.Invalidate() }
}

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
        $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText 'Mikrofonen kunde inte ~oppnas.'), 'Warning')
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
            $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText 'Inget tal h~ordes - ingen anteckning sparad.'), 'Info')
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
        $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText 'Scriptet ~er tomt. Anv~end ## rubriker och - punkter.'), 'Warning')
        return
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = (SvText 'S~eljscript - ') + [System.IO.Path]::GetFileNameWithoutExtension($path)
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
# handler that closes over the function's LOCALS finds them gone by then - the
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
    $f.Text = (SvText 'S~eljscript')
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
    $lang = Get-ActiveMeetLang   # always 'sv' or 'en', never empty
    if ($script:backend -eq 'groq') {
        $key = Get-GroqKey
        if (-not $key) { throw 'Ingen Groq-nyckel' }
        $text = ([Cloud]::Transcribe($key, $clean, $groqModel, $lang)).Trim()
    } else {
        $seg = Get-Transcript $clean $lang
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
        $lang = Get-ActiveMeetLang   # same language as the visible transcript (never empty)
        if ($script:backend -eq 'groq') {
            $key = Get-GroqKey
            if (-not $key) { return $null }
            return ([Cloud]::TranscribeWithPrompt($key, $cleanWav, $groqModel, $lang, $verbatimPrompt)).Trim()
        }
        $seg = Transcribe-File -model $script:model -path $cleanWav -language $lang -prompt $verbatimPrompt
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
                # Transcribed or silent -> safe to drop. But when keep-audio is on, retain
                # every chunk so the end-of-meeting archive is COMPLETE (live mode would
                # otherwise delete chunks as they transcribe, leaving only the last one).
                if (-not $script:meetKeepAudio) { Remove-Item $stream.wav -ErrorAction SilentlyContinue }
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
    # Both the meeting recorder and the phone assistant capture the system audio via
    # loopback. Running both would put the assistant's own voice in the transcript
    # as "Ovriga" and confuse the talk-time stats - refuse instead of interleaving.
    if ($script:taBridge) {
        $tray.ShowBalloonTip(5000, 'Diktatorn', (SvText 'Telefonassistenten ~er aktiv - stoppa den f~orst. B~ada lyssnar p~a systemljudet.'), 'Warning')
        return
    }
    if ($script:dictating) { Cancel-Dictation }   # a slow Ctrl+Shift+M chord can arm PTT dictation; drop it
    # Ask the meeting language up front - a wrong language silently mistranslates
    # the whole meeting, so make it a deliberate per-meeting choice. Cancel = abort.
    $choice = Show-MeetLangPrompt
    if (-not $choice) { return }
    if ($choice -ne $script:meetLang) { Set-MeetLang $choice }   # remember as the new default too
    try {
        $script:meetDir = Join-Path $env:TEMP ('diktatorn_meet_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        New-Item -ItemType Directory -Force $script:meetDir | Out-Null
        $script:meetLines = New-Object 'System.Collections.Generic.List[string]'
        $script:meetProcessed = 0; $script:meetBusy = $false; $script:meetFailed = $false
        $script:meetSecsYou = 0.0; $script:meetSecsOthers = 0.0
        $script:meetWordsYou = 0;  $script:meetWordsOthers = 0
        $script:meetAnalysis = $script:talanalys           # snapshot: mid-meeting toggles apply to the NEXT meeting
        $script:meetModeActive = $script:meetMode          # snapshot: live or deferred for THIS meeting
        $script:meetKeepAudio = $script:keepAudio          # snapshot: a mid-meeting toggle mustn't half-retain
        $script:meetMicChecked = $false; $script:meetSysChecked = $false   # one-shot start-of-meeting audio checks
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
        $miMeeting.Text = (SvText 'Stoppa m~otesinspelning (Ctrl+Shift+M)')
        $miOpenLive.Enabled = $true
        Set-Status 'SPELAR IN MOTE (live)...' $icoMeet
        $tray.ShowBalloonTip(2500, 'Diktatorn', (SvText 'M~otesinspelning startad. Transkriptet v~exer live - se menyn.'), 'Info')
    } catch {
        $script:meeting = $false
        try { $meetTimer.Stop() } catch {}
        try { if ($script:meetRec) { $script:meetRec.Stop() } } catch {}
        Write-Log "Start-Meeting: $($_.Exception.Message)"
        $tray.ShowBalloonTip(4000, 'Diktatorn', (SvText "Kunde inte starta m~otesinspelning: $($_.Exception.Message)"), 'Error')
        Set-Status 'redo' $icoIdle
        Remove-Item $script:meetDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-Meeting {
    if (-not $script:meeting) { return }
    $script:meeting = $false
    $script:meetFinishing = $true   # blocks dictation hotkeys while the post-meeting batch runs
    $meetTimer.Stop()
    $miMeeting.Text = (SvText 'Starta m~otesinspelning (Ctrl+Shift+M)')
    $miOpenLive.Enabled = $false
    Set-Status 'transkriberar mote...' $icoWork
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $script:meetRec.Stop()
        Process-ReadyChunks ($script:meetRec.ChunkIndex + 1)   # remaining chunks incl. the final partial one
        if (($script:meetLines.Count -eq 0) -and -not $script:meetFailed) {
            $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText 'Inget tal f~angades under m~otet.'), 'Warning')
            Remove-Item $script:meetOutFile -ErrorAction SilentlyContinue
            Remove-Item $script:meetDir -Recurse -Force -ErrorAction SilentlyContinue
            return
        }
        Save-MeetingAudio   # opt-in 7-day archive, before the temp dir is cleaned below
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
            $tray.ShowBalloonTip(6000, 'Diktatorn', (SvText 'M~ote delvis transkriberat. Or~ort ljud sparat i temp (se slutet av filen).'), 'Warning')
            # KEEP $meetDir: it holds the chunk audio that failed to transcribe
        } else {
            $tray.ShowBalloonTip(3000, 'Diktatorn', (SvText "M~ote transkriberat: $([System.IO.Path]::GetFileName($script:meetOutFile))"), 'Info')
            Remove-Item $script:meetDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Invoke-Item $script:meetOutFile
    } catch {
        Write-Log "Stop-Meeting: $($_.Exception.Message)"
        # Do NOT delete $meetDir on error - the raw chunk audio is the only copy left.
        $tray.ShowBalloonTip(6000, 'Diktatorn', (SvText "Fel vid m~otesavslut. Ljud sparat i: $($script:meetDir)"), 'Error')
    } finally {
        Clear-OldMeetingAudio   # purge archives past the retention window
        $script:meetFinishing = $false; Set-Status 'redo' $icoIdle
    }
}

# Meeting timer: rotation happens inside the recorder, so this just transcribes finished
# chunks (a few per tick to drain any backlog without freezing the UI) and updates status.
$meetTimer = New-Object System.Windows.Forms.Timer
$meetTimer.Interval = 1000
$meetTimer.add_Tick({
    if (-not $script:meeting) { return }
    # One-shot start-of-meeting audio checks: catch a silent capture in seconds,
    # not after the meeting. Mic peak flags a muted/dead mic (~8 s); system-audio
    # seconds flags loopback capturing the wrong/idle playback device (~35 s, long
    # enough that a real meeting has produced some far-side audio). Cheap; runs
    # before the transcription-busy gate so the timing is reliable.
    $elapsed = ((Get-Date) - $script:meetStart).TotalSeconds
    if (-not $script:meetMicChecked -and $elapsed -ge $micCheckSec) {
        $script:meetMicChecked = $true
        try {
            if (-not $script:meetRec.MicCaptured) {
                Write-Log 'Ljudkontroll: mikrofonen kunde inte oppnas'
                $tray.ShowBalloonTip(9000, 'Diktatorn', (SvText 'Mikrofonen kunde inte ~oppnas - din r~ost spelas inte in. V~elj en annan mikrofon i menyn.'), 'Warning')
            } elseif ($script:meetRec.MicPeak -lt 0.01) {
                Write-Log ("Ljudkontroll: mikrofon tyst (peak {0:N4})" -f $script:meetRec.MicPeak)
                $tray.ShowBalloonTip(9000, 'Diktatorn', (SvText 'Mikrofonen verkar tyst - din r~ost spelas kanske inte in. Kontrollera att r~ett mikrofon ~er vald och inte avst~engd.'), 'Warning')
            }
        } catch {}
    }
    if (-not $script:meetSysChecked -and $elapsed -ge $sysCheckSec) {
        $script:meetSysChecked = $true
        try {
            if ($script:meetRec.SysSeconds -lt 2) {
                Write-Log ("Ljudkontroll: inget datorljud ({0:N1}s pa {1:N0}s)" -f $script:meetRec.SysSeconds, $elapsed)
                $tray.ShowBalloonTip(9000, 'Diktatorn', (SvText 'Inget datorljud har h~orts - de andra deltagarna spelas kanske inte in. Kontrollera att m~otesljudet g~ar via r~ett uppspelningsenhet (t.ex. inte ett headset som inte f~angas).'), 'Warning')
            }
        } catch {}
    }
    if ($script:meetBusy) { return }
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
# (a bare [void]) makes the key silently dead - report it instead.
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
    $tray.ShowBalloonTip(6000, 'Diktatorn', (SvText "Dessa kortkommandon ~er upptagna av en annan app och fungerar inte:`n") + ($hkFailed -join "`n"), 'Warning')
}
# Integrated graphics run Whisper roughly 30x slower than a discrete card
# (measured: 0.3x vs 10.9x realtime on the same clip), which makes local mode
# feel broken rather than slow. Say so, and say what to do about it.
if (-not (Test-DiscreteAdapter $script:adapter)) {
    $better = @($script:adapters | Where-Object { Test-DiscreteAdapter $_ })[0]
    if ($better) {
        $tray.ShowBalloonTip(9000, 'Diktatorn',
            (SvText "Lokal transkribering k~or p~a integrerad grafik ($script:adapter) och blir d~a mycket l~angsam.`n`nDu har $better - v~elj det under Grafikkort i menyn."),
            'Warning')
    } else {
        $tray.ShowBalloonTip(9000, 'Diktatorn',
            (SvText "Inget dedikerat grafikkort hittades - lokal transkribering blir l~angsam p~a $script:adapter.`n`nV~elj Groq moln under Transkribering f~or snabbare resultat."),
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

if ($script:taTillganglig) {
    $miPhone.add_Click({
        if ($script:taBridge) {
            Stop-Telefonassistent
            $miPhone.Text = 'Starta telefonassistent'
            $miPhoneTon.Enabled = $false
        } elseif (Start-Telefonassistent $script:taRoll 400) {
            $miPhone.Text = 'Stoppa telefonassistent'
            $miPhoneTon.Enabled = $true
        }
    })
    # Tonen bevisar kabelvagen utan att blanda in AI:n - hor motparten den ar
    # hela vagen ut klar.
    $miPhoneTon.add_Click({ try { $script:taBridge.Testton() } catch {} })
}

$miQuit.add_Click({
    try { $timer.Stop() } catch {}
    try { if ($script:taBridge) { Stop-Telefonassistent } } catch {}
    try { Stop-TaServer } catch {}
    try { if ($script:meeting) { Stop-Meeting } } catch {}   # finish + save the transcript, don't lose it
    try { if ($script:dictating -or $script:journaling) { $script:micRec.Stop() } } catch {}
    try { if ($script:scriptForm -and -not $script:scriptForm.IsDisposed) { $script:scriptForm.Close() } } catch {}
    try { if ($script:dashTimer) { $script:dashTimer.Stop() } } catch {}
    try { if ($script:dashForm -and -not $script:dashForm.IsDisposed) { $script:dashForm.Dispose() } } catch {}
    $hk.Dispose(); $tray.Visible = $false; $appContext.ExitThread()
})

Clear-OldMeetingAudio   # purge any kept meeting audio past the retention window
$tray.ShowBalloonTip(2500, 'Diktatorn', (SvText 'Redo. H~all Ctrl+Shift f~or att diktera, Ctrl+Shift+M f~or m~ote.'), 'Info')
[System.Windows.Forms.Application]::Run($appContext)
