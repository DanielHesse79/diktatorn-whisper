# Diktatorn 🎙️👔

A lightweight, **Wispr Flow–style dictation and meeting-transcription tool for Windows**, built on top of
[Const-me/Whisper](https://github.com/Const-me/Whisper) (high-performance GPU Whisper inference).

Press a hotkey, speak, and your words are typed straight into whatever app has focus — or capture a whole
meeting's system audio and get a transcript. Runs quietly in the system tray. No Python, no Visual Studio,
no .NET SDK required — just Windows PowerShell and the in-box .NET Framework.

> Named *Diktatorn* — Swedish for "the dictator" — because it rules your words with an iron hand. 😄

> 📖 **End users:** see the [Användarmanual (Swedish)](Anvandarmanual.md) for a step-by-step guide,
> including how to get a free Groq cloud API key.

## Features

- **Dictation → typed at the cursor**, in any app:
  - **Hold `Ctrl+Shift`** (push-to-talk): speak, release, text is typed.
  - **`Ctrl+Shift+D`** (toggle): press to start, press again to stop.
- **Meeting language** (tray): **Swedish** (default) or **English** — an explicit choice, deliberately
  no auto-detect. The local engine (WhisperPS) can't detect language, only *force* one, and forcing the
  wrong one **translates** rather than transcribes: Swedish speech comes out as fluent English, English
  as fluent Swedish. It looks like a working transcript in the wrong language, which is easy to miss.
  Empty-language auto-detect shipped once and turned four consecutive real Swedish meetings into English.
- **Start-of-meeting audio check**: a few seconds in, the recorder's live mic peak and captured
  system-audio seconds are checked, warning if a stream is silent — a muted/wrong mic, or WASAPI
  loopback capturing the wrong/idle playback device (e.g. meeting audio routed to a headset that isn't
  the default device). Catches a silent capture in seconds instead of as an empty transcript afterward.
- **Keep meeting audio** (tray, opt-in): normally the raw audio is deleted once a meeting is
  transcribed. Turn this on and each meeting's audio is archived to `Documents\Transcriptions\Motesljud\`
  for **7 days** (then auto-purged) — a safety net to re-transcribe if something went wrong (e.g. wrong
  language). In live mode chunks are retained rather than deleted-on-transcribe so the archive is complete.
- **Language prompt on start**: pressing `Ctrl+Shift+M` asks **Swedish or English** before recording, so
  the per-meeting language is a deliberate choice (Enter accepts the last-used default).
- **Meeting transcription** (`Ctrl+Shift+M`): records **system audio** (remote participants, WASAPI
  loopback) and **your mic** as separate streams, transcribed **continuously during the meeting** in 30 s
  chunks with **speaker labels** (`Du:` = you, `Övriga:` = the others — the label is simply which stream
  the audio came from, no ML diarization needed). The transcript file grows live (tray → *Visa transkript*),
  and **talk-time stats** (minutes + % per side) are appended on stop.
- **Private speech analysis** (optional, analyzes ONLY your own lines, never the other side):
  filler-word counting ("typ", "liksom", "eh"...), questions asked, longest monologue, a per-meeting
  trend CSV, a live **crocodile warning** when you've talked >70% of the last 10 minutes (big mouth,
  small ears), and an optional **AI coach report** appended to the transcript. The coach **remembers** —
  past reports are archived locally and fed back, so it follows up on its own exercises ("questions up
  from 1 to 3"). The coach engine is pluggable: **Groq** (free, default), **Ollama** (fully local), or
  **OpenRouter** (any model you like) — all via the same OpenAI-protocol call. The visible transcript
  stays clean; the analysis runs on a verbatim pass under the hood.
- **Voice journal** (`Ctrl+Shift+N`): speak a note and it's appended — with a timestamp heading — to
  `Documents\Journal\YYYY-MM-DD.md` instead of being typed at the cursor. Near-silent takes are
  rejected (measured RMS gate) so a mis-press never writes a Whisper-hallucinated entry into your journal.
- **Sales script screen**: a small always-on-top checklist built from a markdown file in
  `Documents\SalesScripts`. Headings become sections, bullets become checkboxes. During a **live**
  meeting the items **check themselves off** as you cover them — the coach engine matches each new
  transcript chunk against the remaining items — and the footer shows progress plus your live talk share.
- **Script manager**: list, edit, duplicate and delete scripts in-app, or **generate one with AI** from a
  one-line brief ("first call with an IT manager at a mid-size manufacturer, selling automated reporting")
  and **improve** an existing one on request. Uses the same pluggable engine as the coach, so picking
  Ollama keeps your deal descriptions on the machine. Scripts stay plain `.md` files — editable anywhere.
- **Phone assistant** (optional): an AI that **talks in your phone calls** — answers when you can't, or
  calls someone on your behalf. Hears the other party via **WASAPI loopback** (what Phone Link plays to
  your speakers) and speaks into the call through a **virtual audio cable** that Phone Link reads as its
  microphone. Requires [VB-CABLE](https://vb-audio.com/Cable/) and the companion
  [Telefonsvararen](https://github.com/DanielHesse79) server, which holds the persona and does the
  speech-to-speech. See [Phone assistant](#phone-assistant-optional) below.
- **Local or cloud** transcription, switchable in the tray:
  - **Local** — runs on your GPU via Const-me Whisper. Private, offline.
  - **Groq cloud** — `whisper-large-v3-turbo`, sub-second and great multilingual quality. Ideal for
    laptops / weak GPUs. (Free tier: 2,000 requests/day.)
- **Tray menu**: pick microphone, pick model (base/small/medium = speed vs accuracy), pick backend, and
  pick the **GPU** when the machine has more than one. This matters more than it sounds: DirectX often
  enumerates the integrated GPU first, and blindly taking it measured **0.3x realtime on an integrated
  Radeon versus 10.9x on the discrete RTX beside it** — a 34x difference on identical audio. Diktatorn
  now prefers a discrete card automatically.
- **Types Unicode** via `SendInput`, so åäö and friends come out right.
- Auto-detects your GPU; remembers your choices between restarts.

## Requirements

- 64-bit Windows 10/11 with a Direct3D 11 GPU (CPU with AVX1 + F16C).
- Windows PowerShell 5.1 (built in) — the dependencies are .NET Framework assemblies.
- ~0.5–1.5 GB free disk for a Whisper model.

## Install

**Easiest — the installer:** run **`Diktatorn-Setup.exe`** (built from `Diktatorn.iss` with Inno Setup;
published under Releases). It's a per-user install (no admin), creates Start-Menu/desktop shortcuts and an
uninstaller, and downloads the dependencies automatically.

**Or via PowerShell directly:**
```powershell
# From the repo folder:
powershell -ExecutionPolicy Bypass -File .\Install-Diktatorn.ps1
# Options: -Model base|small|medium  (default: small)   -Autostart   -NoShortcuts
```

**Build the installer yourself:**
```powershell
& "${env:LOCALAPPDATA}\Programs\Inno Setup 6\ISCC.exe" Diktatorn.iss   # -> dist\Diktatorn-Setup.exe
```

The installer also **benchmarks your GPU** (a real timed transcription, not name-guessing) and
auto-configures the meeting mode: fast machines get **live** transcription, slow ones get
**deferred** (record during the meeting, transcribe on stop — the crocodile warning still works,
since it only needs cheap talk-time measurement). See `Diktatorn-rekommendation.txt` after install.
Models picked in the tray menu are downloaded on demand.

The installer downloads everything that can't be redistributed here:
- `Whisper.dll` + `WhisperDesktop.exe` (from the Const-me/Whisper 1.12 release)
- the `WhisperPS` PowerShell module
- `NAudio.dll` (from NuGet) for microphone + loopback capture
- the chosen Whisper model (from Hugging Face)

…then creates Desktop + Start-Menu shortcuts. Double-click **Diktatorn** to run.

## Usage

| Action | How |
|---|---|
| Dictate (push-to-talk) | Hold **Ctrl+Shift**, speak, release |
| Dictate (toggle) | **Ctrl+Shift+D** to start/stop |
| Journal note | **Ctrl+Shift+N** to start/stop |
| Record a meeting | **Ctrl+Shift+M** (or tray menu) to start/stop |
| Open sales script | Tray → *Sälj-script* |
| Pick mic / model / backend | Right-click the tray icon |
| Quit | Right-click → Avsluta |

Tray icon colours: 🟢 ready · 🔴 recording (dictation) · 🔵 recording (meeting) · 🟡 transcribing.

## Using Groq cloud (optional)

1. Get a free API key at [console.groq.com](https://console.groq.com) → API Keys (`gsk_...`).
2. Right-click tray → **Ange Groq API-nyckel...** → paste it.
3. Right-click tray → **Transkribering** → **Groq moln**.

The key is stored locally in `diktatorn-groq.txt` (git-ignored) or read from `$env:GROQ_API_KEY`.
Meetings can be sensitive — keep the **Local** backend for private calls.

## Phone assistant (optional)

An AI that speaks in your actual phone calls, over **Windows Phone Link**. It hears the other party and
answers out loud, in Swedish, roughly a second after they stop talking.

### What you need

1. **[VB-CABLE](https://vb-audio.com/Cable/)** — the free single cable is enough. It is the *only* way to
   feed audio into Phone Link's microphone; no API exists for that.
2. **[Telefonsvararen](https://github.com/DanielHesse79)** — the companion server that holds the persona
   and does the speech-to-speech (Node 20+, an OpenRouter key in its own `.env`). Diktatorn starts and
   stops it automatically. **No API key lives in this repo.**
3. **Phone Link**, paired and able to place calls.

### Works with any calling app

The bridge never sees which program is calling — it captures what the machine plays and speaks into a
cable. **Phone Link, WhatsApp, Teams, Zoom and Discord all work.** What differs is only *where* you point
that app's microphone at `CABLE Output`:

| App | Where the mic is chosen | Affects other programs? |
|---|---|---|
| **WhatsApp** | Settings → Voice and video → Microphone | No |
| **Teams / Zoom / Discord** | their own audio settings | No |
| **Phone Link** | no setting of its own — takes the system default | **Yes**, see below |

Prefer an app with its own picker: the system default microphone can stay your real one, and nothing else
on the machine is disturbed.

### Windows audio settings

Output must always be **your speakers** — that's where the call is played, and that stream is what the
assistant listens to.

Input depends on the app. If it has its own picker, leave the system default alone and select
`CABLE Output` inside the app. Done.

**Only for Phone Link**, which has no picker:

| Setting | Value |
|---|---|
| Input, default **and** communications | `CABLE Output` |

Both roles must point at the cable — Phone Link reads the *plain* default, not the communications one,
and will otherwise put your room microphone into the call. The communications role is set in
`mmsys.cpl`; the plain one in Settings → System → Sound.

The cost is that you go silent in every other program while this is set, since they use the same default.

**Restart Phone Link after changing defaults** — it picks its microphone at startup and otherwise keeps
using the old one.

Do **not** tick "Listen to this device" on `CABLE Output`: the AI's voice would land in your speakers,
the loopback would capture it, and it would start answering itself.

### Using it

Tray → **Starta telefonassistent**. Then:

- **Testa kabeln (ton till motparten)** — plays a tone into the call. If the other party hears it, the
  whole outbound path works. Proves the plumbing without spending an AI turn.
- **Telefonassistent: utgang** — must be `CABLE Input`. Picking speakers means the AI talks to your room
  instead of into the call; the app warns you.
- **Telefonassistent: roll** — *Svarare* answers incoming calls (greets first), *Uppringare* calls out
  (waits for the other party, then introduces itself as an AI on your behalf).
- **Telefonassistent: serverkatalog...** — only needed if Telefonsvararen isn't beside this folder.

Stopping the assistant fetches a summary of the call and shows it as a balloon.

### Why loopback and a cable, and not something cleaner

Phone Link never exposes call audio as an audio device. Windows lists the paired phone's
`Hands-Free HF Audio` endpoints as `ACTIVE` in the registry and `OK` in `Get-PnpDevice`, but no
application can open them — verified with `ffmpeg -list_devices true -f dshow -i dummy`, which sees only
the real microphones **even during an active call with Phone Link connected**. Those registry values are
persisted state, not live availability. The audio is real and audible in the speakers, so the only way in
is to capture what is played; the only way back out is a virtual device Phone Link mistakes for a
microphone. Hence loopback plus VB-CABLE.

## How it works

- A message-only window registers the global hotkeys (`RegisterHotKey`); push-to-talk is detected by
  polling `GetAsyncKeyState` in a WinForms timer.
- The phone assistant (`Telefonassistent.ps1`) runs its own C# `PhoneBridge`: `WasapiLoopbackCapture` in,
  RMS voice-activity detection with a measured noise floor, `WasapiOut` to a chosen device out. The whole
  turn loop lives on background threads, so the tray never freezes mid-call.
- Mic capture uses NAudio `WaveInEvent` at **16 kHz/16-bit/mono** (exactly what Whisper expects);
  meeting audio uses `WasapiLoopbackCapture`.
- Transcription goes to the local Const-me model (`WhisperPS`) or to Groq's OpenAI-compatible
  `/audio/transcriptions` endpoint.
- Recognised text is injected with `SendInput` (`KEYEVENTF_UNICODE`).

All the native interop is compiled at runtime with `Add-Type` (the in-box .NET Framework C# compiler), so
there's nothing to build.

## Notes / gotchas (learned the hard way)

- NAudio capture callbacks must be handled in compiled C#, not PowerShell scriptblocks (the latter crash
  the process when invoked from the capture thread).
- The capture object must be created with **no `SynchronizationContext`**, otherwise `RecordingStopped`
  deadlocks against the UI thread (caused a constant 5 s delay + truncated audio).
- Don't transcribe pure digital silence — it crashes the native library. Warm up on a real speech clip.
- A Plexgear (and many) USB headsets enumerate as **"USB PnP Sound Device"**.

## Credits & license

- Built on [Const-me/Whisper](https://github.com/Const-me/Whisper) — please respect its license; this repo
  does **not** redistribute its binaries (they're downloaded at install time).
- Audio I/O via [NAudio](https://github.com/naudio/NAudio).
- Models from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp).

This project's own code (`Diktatorn.ps1`, `Diktatorn.vbs`, `Install-Diktatorn.ps1`) is released under the
MIT License — see [LICENSE](LICENSE).
