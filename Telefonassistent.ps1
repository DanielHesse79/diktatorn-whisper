# --- Telefonassistent: AI som pratar i dina samtal ---
#
# Fungerar med VILKEN samtalsapp som helst - Telefonlank, WhatsApp, Teams, Zoom,
# Discord. Bryggan ser inte vilket program som ringer; den fangar det datorn
# spelar upp och talar in i en virtuell kabel.
#
# Ljudvagen (verifierad 2026-07-23):
#
#   Motparten -> samtalsappen -> hogtalarna -> WASAPI-loopback -> hit
#   harifran  -> WasapiOut    -> CABLE Input -> CABLE Output -> appens mik -> motparten
#
# Loopback behovs for att samtalsappar sallan exponerar samtalet som en
# ljudenhet (Telefonlank gor det aldrig). Kabeln behovs for att inget API kan
# mata en annan apps mikrofoningang. Bada ar nodvandiga, ingen av dem valbar.
#
# UTGANG: alltid CABLE Input.
# INGANG till samtalsappen: CABLE Output - men VAR den stalls in skiljer sig:
#   WhatsApp / Teams / Zoom / Discord - i appens egna ljudinstallningar.
#     Basta valet: systemets standardmikrofon kan forbli din riktiga.
#   Telefonlank - har inget eget val, tar systemets standardmikrofon.
#     Da maste bade standard- OCH kommunikationsrollen sattas till CABLE Output,
#     vilket tystar dig i alla andra program sa lange det galler.
#     Starta om Telefonlank efter andring - den valjer mikrofon vid start.
#
# Hjarnan ar Telefonsvararen-serverns /api/tur (persona, gpt-audio, fyllnadsljud,
# sammanfattning). Den har filen ar bara oron och rosten.

$script:taServer    = 'http://localhost:3000'
$script:taOutCfg    = Join-Path $PSScriptRoot 'diktatorn-telefon-utgang.txt'
$script:taRootCfg   = Join-Path $PSScriptRoot 'diktatorn-telefon-server.txt'
$script:taAppCfg    = Join-Path $PSScriptRoot 'diktatorn-telefon-app.txt'
$script:taBridge    = $null
$script:taNode      = $null
$script:taRoll      = 'svarare'

# Var ligger Telefonsvararen (hjarnan)? Sparad sokvag forst, sedan de vanliga
# platserna. Ingen hardkodad anvandarmapp - repot ska funka for alla.
function Get-TaRoot {
    if (Test-Path $script:taRootCfg) {
        $s = (Get-Content $script:taRootCfg -Raw -ErrorAction SilentlyContinue).Trim()
        if ($s -and (Test-Path (Join-Path $s 'server.js'))) { return $s }
    }
    $kandidater = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'Telefonsvararen'),
        (Join-Path $env:USERPROFILE 'Documents\GitHub\Telefonsvararen'),
        (Join-Path $PSScriptRoot 'Telefonsvararen')
    )
    foreach ($k in $kandidater) { if (Test-Path (Join-Path $k 'server.js')) { return $k } }
    $null
}

function Set-TaRoot([string]$sokvag) {
    try { [System.IO.File]::WriteAllText($script:taRootCfg, $sokvag) } catch { }
}

# --- Native: loopback-lyssning + taldetektering + uppspelning till vald utgang ---
$csPhone = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using NAudio.CoreAudioApi;

// Halller hela samtalsloopen i C#: fanga -> tyst? -> skicka -> spela svaret.
// Allt utanfor UI-traden, sa Diktatorns tray aldrig fryser mitt i ett samtal.
public class PhoneBridge {
    const int UT_HZ = 24000;    // gpt-audio levererar pcm16 24 kHz mono
    const int IN_HZ = 16000;    // det vi skickar upp; racker gott for tal

    WasapiLoopbackCapture cap;
    WasapiOut player;
    BufferedWaveProvider playBuf;
    MemoryStream tur = new MemoryStream();
    readonly object turLock = new object();
    HttpClient http = new HttpClient();

    volatile bool running, upptagen;
    double talatMs, tystMs;
    float brusgolv = 0.004f, troskel = 0.012f;
    int tystnadMs = 400, minstaTalMs = 250;
    int kalibrerarKvar = 25;    // ~25 buffertar = en halv sekund
    float golvSumma = 0; int golvAntal = 0;

    string url, samtalsId, roll;
    volatile string sisteTranskript = "", sisteSvar = "", sisteFel = "";
    volatile int turerKorda = 0;

    public string SamtalsId { get { return samtalsId; } }
    public string SisteTranskript { get { return sisteTranskript; } }
    public string SisteSvar { get { return sisteSvar; } }
    public string SisteFel { get { return sisteFel; } }
    public int TurerKorda { get { return turerKorda; } }
    public bool Upptagen { get { return upptagen; } }
    public bool Kalibrerar { get { return kalibrerarKvar > 0; } }
    public float Niva { get; private set; }

    public static string[] Utenheter() {
        var lista = new List<string>();
        var e = new MMDeviceEnumerator();
        foreach (var d in e.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            lista.Add(d.FriendlyName + "\t" + d.ID);
        return lista.ToArray();
    }

    public void Start(string utEnhetId, string serverUrl, string rollen, int tystnad) {
        url = serverUrl; roll = rollen; tystnadMs = tystnad;
        samtalsId = Guid.NewGuid().ToString();
        sisteFel = ""; sisteSvar = ""; sisteTranskript = ""; turerKorda = 0;
        kalibrerarKvar = 25; golvSumma = 0; golvAntal = 0;
        talatMs = 0; tystMs = 0;
        http.Timeout = TimeSpan.FromSeconds(60);

        var enumerator = new MMDeviceEnumerator();
        MMDevice ut = null;
        foreach (var d in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            if (d.ID == utEnhetId) { ut = d; break; }
        if (ut == null) throw new Exception("Hittar inte utgangen. Valj enhet i menyn igen.");

        // Uppspelning: gpt-audios 24 kHz mono resamplas till enhetens mixformat.
        playBuf = new BufferedWaveProvider(new WaveFormat(UT_HZ, 16, 1));
        playBuf.BufferDuration = TimeSpan.FromSeconds(30);
        playBuf.DiscardOnBufferOverflow = true;
        int mixHz = ut.AudioClient.MixFormat.SampleRate;
        int mixKanaler = ut.AudioClient.MixFormat.Channels;
        ISampleProvider sp = new WdlResamplingSampleProvider(playBuf.ToSampleProvider(), mixHz);
        if (mixKanaler >= 2) sp = new MonoToStereoSampleProvider(sp);
        player = new WasapiOut(ut, AudioClientShareMode.Shared, false, 120);
        player.Init(sp);
        player.Play();

        // Lyssning: loopback pa standardutgangen = det Telefonlank spelar upp.
        var prev = SynchronizationContext.Current;
        SynchronizationContext.SetSynchronizationContext(null);
        cap = new WasapiLoopbackCapture();
        SynchronizationContext.SetSynchronizationContext(prev);
        cap.DataAvailable += Inkommande;
        running = true;
        cap.StartRecording();
    }

    void Inkommande(object s, WaveInEventArgs e) {
        if (!running || e.BytesRecorded == 0) return;
        var f = cap.WaveFormat;
        int kanaler = f.Channels;

        // Loopback ar normalt 32-bitars float. Ta ner till mono float.
        int ramar;
        float[] mono;
        if (f.Encoding == WaveFormatEncoding.IeeeFloat && f.BitsPerSample == 32) {
            ramar = e.BytesRecorded / 4 / kanaler;
            mono = new float[ramar];
            for (int i = 0; i < ramar; i++) {
                float sum = 0;
                for (int c = 0; c < kanaler; c++) sum += BitConverter.ToSingle(e.Buffer, (i * kanaler + c) * 4);
                mono[i] = sum / kanaler;
            }
        } else if (f.BitsPerSample == 16) {
            ramar = e.BytesRecorded / 2 / kanaler;
            mono = new float[ramar];
            for (int i = 0; i < ramar; i++) {
                float sum = 0;
                for (int c = 0; c < kanaler; c++) sum += BitConverter.ToInt16(e.Buffer, (i * kanaler + c) * 2) / 32768f;
                mono[i] = sum / kanaler;
            }
        } else return;

        double ms = ramar * 1000.0 / f.SampleRate;
        float rms = 0;
        for (int i = 0; i < ramar; i++) rms += mono[i] * mono[i];
        rms = (float)Math.Sqrt(rms / Math.Max(1, ramar));
        Niva = rms;

        // Brusgolvet skiljer sig mellan tyst rum och kontor med flakt - mat det.
        if (kalibrerarKvar > 0) {
            golvSumma += rms; golvAntal++; kalibrerarKvar--;
            if (kalibrerarKvar == 0) {
                brusgolv = golvSumma / Math.Max(1, golvAntal);
                troskel = Math.Max(brusgolv * 3f, 0.012f);
            }
            return;
        }

        // Lyssna inte medan vi sjalva talar eller vantar pa svar.
        if (upptagen || playBuf.BufferedBytes > 0) { talatMs = 0; tystMs = 0; lock (turLock) { tur.SetLength(0); } return; }

        // Ner till 16 kHz mono pcm16 med medelvarde over fonstret (enkel antialias).
        int steg = Math.Max(1, f.SampleRate / IN_HZ);
        lock (turLock) {
            for (int i = 0; i + steg <= ramar; i += steg) {
                float sum = 0;
                for (int k = 0; k < steg; k++) sum += mono[i + k];
                int v = (int)(sum / steg * 32767f);
                if (v > 32767) v = 32767; if (v < -32768) v = -32768;
                tur.WriteByte((byte)(v & 0xFF));
                tur.WriteByte((byte)((v >> 8) & 0xFF));
            }
        }

        if (rms > troskel) { talatMs += ms; tystMs = 0; }
        else if (talatMs > minstaTalMs) {
            tystMs += ms;
            if (tystMs >= tystnadMs) {
                byte[] pcm;
                lock (turLock) { pcm = tur.ToArray(); tur.SetLength(0); }
                talatMs = 0; tystMs = 0;
                if (pcm.Length > IN_HZ / 2) {   // under en kvarts sekund ar en harkling
                    upptagen = true;
                    ThreadPool.QueueUserWorkItem(delegate { SkickaTur(pcm); });
                }
            }
        }
    }

    static byte[] Wav(byte[] pcm, int hz) {
        var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + pcm.Length);
        w.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16);
        w.Write((short)1); w.Write((short)1); w.Write(hz); w.Write(hz * 2);
        w.Write((short)2); w.Write((short)16);
        w.Write(Encoding.ASCII.GetBytes("data")); w.Write(pcm.Length);
        w.Write(pcm); w.Flush();
        return ms.ToArray();
    }

    // Hjarnan bor i Telefonsvararen-servern: persona, gpt-audio, fyllnadsljud.
    void SkickaTur(byte[] pcm) {
        try {
            string kropp = "{\"id\":\"" + samtalsId + "\",\"format\":\"wav\",\"roll\":\"" + roll +
                           "\",\"ljud\":\"" + Convert.ToBase64String(Wav(pcm, IN_HZ)) + "\"}";
            var req = new HttpRequestMessage(HttpMethod.Post, url + "/api/tur");
            req.Content = new StringContent(kropp, Encoding.UTF8, "application/json");
            var svar = http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead).Result;
            if (!svar.IsSuccessStatusCode) { sisteFel = "Servern svarade " + (int)svar.StatusCode; return; }

            using (var strom = svar.Content.ReadAsStreamAsync().Result)
            using (var las = new StreamReader(strom, Encoding.UTF8)) {
                string rad;
                while ((rad = las.ReadLine()) != null) {
                    if (!rad.StartsWith("data: ")) continue;
                    string j = rad.Substring(6);
                    string typ = Falt(j, "typ");
                    if (typ == "fel") { sisteFel = Falt(j, "fel"); }
                    else if (typ == "transkript") { sisteTranskript = Falt(j, "text"); }
                    else if (typ == "ljud") {
                        var b = Convert.FromBase64String(Falt(j, "data"));
                        if (Falt(j, "kodning") == "pcm16") playBuf.AddSamples(b, 0, b.Length);
                    }
                    else if (typ == "klar") { sisteSvar = Falt(j, "svar"); turerKorda++; }
                }
            }
        } catch (Exception ex) {
            sisteFel = ex.GetBaseException().Message;
        } finally {
            upptagen = false;
        }
    }

    // Minimal falt-utplock ur serverns SSE-JSON. Formatet ar vart eget och kant,
    // sa en full parser vore overkill - men strangar maste av-escapas.
    static string Falt(string json, string namn) {
        string nyckel = "\"" + namn + "\":\"";
        int i = json.IndexOf(nyckel);
        if (i < 0) return "";
        i += nyckel.Length;
        var sb = new StringBuilder();
        while (i < json.Length) {
            char c = json[i];
            if (c == '\\' && i + 1 < json.Length) {
                char n = json[++i];
                if (n == 'n') sb.Append('\n');
                else if (n == 't') sb.Append('\t');
                else if (n == 'u' && i + 4 < json.Length) {
                    sb.Append((char)Convert.ToInt32(json.Substring(i + 1, 4), 16)); i += 4;
                } else sb.Append(n);
            } else if (c == '"') break;
            else sb.Append(c);
            i++;
        }
        return sb.ToString();
    }

    // Testton till vald utgang - bevisar kabelvagen utan att blanda in AI:n.
    public void Testton() {
        var pcm = new byte[UT_HZ * 2 * 3];
        for (int i = 0; i < UT_HZ * 3; i++) {
            double hz = ((i / (UT_HZ / 2)) % 2 == 0) ? 660 : 880;
            short v = (short)(Math.Sin(2 * Math.PI * hz * i / UT_HZ) * 8000);
            pcm[i * 2] = (byte)(v & 0xFF);
            pcm[i * 2 + 1] = (byte)((v >> 8) & 0xFF);
        }
        if (playBuf != null) playBuf.AddSamples(pcm, 0, pcm.Length);
    }

    public void Stop() {
        running = false;
        try { if (cap != null) { cap.StopRecording(); cap.Dispose(); } } catch { }
        try { if (player != null) { player.Stop(); player.Dispose(); } } catch { }
        cap = null; player = null; playBuf = null;
    }
}
'@

Add-Type -TypeDefinition $csPhone -ReferencedAssemblies $naudioDll, 'System.Net.Http', 'System.Core' -ErrorAction Stop

# --- Utgangsval (kom ihag mellan omstarter) -------------------------------------

function Get-TaUtenheter {
    $ut = @()
    foreach ($rad in [PhoneBridge]::Utenheter()) {
        $d = $rad -split "`t"
        $ut += [pscustomobject]@{ Namn = $d[0]; Id = $d[1] }
    }
    $ut
}

function Get-TaValdUtgang {
    $enheter = Get-TaUtenheter
    if (-not $enheter) { return $null }
    if (Test-Path $script:taOutCfg) {
        $sparat = (Get-Content $script:taOutCfg -Raw -ErrorAction SilentlyContinue).Trim()
        $traff = $enheter | Where-Object { $_.Namn -eq $sparat } | Select-Object -First 1
        if ($traff) { return $traff }
    }
    # Kabeln ar ratt svar i nio fall av tio - foresla den.
    $kabel = $enheter | Where-Object { $_.Namn -match 'CABLE Input' } | Select-Object -First 1
    if ($kabel) { return $kabel }
    $enheter | Select-Object -First 1
}

function Set-TaUtgang([string]$namn) {
    try { [System.IO.File]::WriteAllText($script:taOutCfg, $namn) } catch { }
}

# --- Ringa fran UI:t ------------------------------------------------------------
#
# Detta ringer INTE sjalvt. Bryggan ar app-agnostisk med flit, och ingen av
# samtalsapparna exponerar ett API for att koppla upp ett samtal. Det som gar att
# gora ar att lamna over numret till appen som redan ager telefonin, sa att man
# slipper leta fram fonstret och knappa in det igen. Ljudvagen ar oforandrad:
# loopback in, CABLE Input ut. Ett riktigt "ring harifran" kraver en SIP-trunk.
#
# Numret normaliseras till E.164 innan overlamning: Telefonlank tolkar 0701-23 45 67
# som ett svenskt nummer, men Teams och WhatsApp vill ha +46701234567.

function Format-PhoneNumber([string]$raw, [string]$landsnummer = '+46') {
    if (-not $raw) { return $null }
    $s = ($raw -replace '[\s\-\(\)\.\/]', '').Trim()
    if (-not $s) { return $null }
    if ($s -match '^00\d') { $s = '+' + $s.Substring(2) }     # 0046... -> +46...
    if ($s -match '^0\d')  { $s = $landsnummer + $s.Substring(1) }  # 070... -> +4670...
    if ($s -notmatch '^\+') { $s = $landsnummer + $s }
    # E.164 tillater 1-15 siffror efter plus. Kortare an 7 ar aldrig ett riktigt
    # nummer har och ar oftast en halvskriven inmatning - vagra hellre an ring fel.
    if ($s -notmatch '^\+\d{7,15}$') { return $null }
    return $s
}

# Vilka appar finns att lamna over till? Ordningen ar rekommendationsordning.
# 'system' ligger sist: pa den har maskinen pekar tel: pa lync.exe (Skype for
# Business) utan att nagon valt det, sa det ar ett samre forstaval an det ser ut.
function Get-CallApps {
    $appar = @()
    if (Get-AppxPackage -Name 'Microsoft.YourPhone' -ErrorAction SilentlyContinue) {
        $appar += [pscustomobject]@{ Id = 'phonelink'; Namn = (SvText 'Telefonl~enk'); Uri = 'ms-phone:?PhoneNumber={0}' }
    }
    if (Get-AppxPackage -Name '*WhatsAppDesktop*' -ErrorAction SilentlyContinue) {
        $appar += [pscustomobject]@{ Id = 'whatsapp'; Namn = 'WhatsApp'; Uri = 'whatsapp://send?phone={0}' }
    }
    if (Get-AppxPackage -Name 'MSTeams' -ErrorAction SilentlyContinue) {
        $appar += [pscustomobject]@{ Id = 'teams'; Namn = 'Teams'; Uri = 'msteams:/l/call/0/0?users=4:{0}' }
    }
    $appar += [pscustomobject]@{ Id = 'system'; Namn = (SvText 'Systemets tel:-hanterare'); Uri = 'tel:{0}' }
    $appar
}

function Get-CallApp {
    $appar = @(Get-CallApps)
    if (Test-Path $script:taAppCfg) {
        $sparat = (Get-Content $script:taAppCfg -Raw -ErrorAction SilentlyContinue).Trim()
        $traff = $appar | Where-Object { $_.Id -eq $sparat } | Select-Object -First 1
        if ($traff) { return $traff }
    }
    $appar | Select-Object -First 1
}

function Set-CallApp([string]$id) {
    try { [System.IO.File]::WriteAllText($script:taAppCfg, $id) } catch { }
}

# Bygger URI:n utan att oppna nagot - sa att testerna kan verifiera overlamningen
# utan att ett samtal blir av.
function Get-CallUri([string]$nummer, $app) {
    $e164 = Format-PhoneNumber $nummer
    if (-not $e164) { return $null }
    if (-not $app) { $app = Get-CallApp }
    if (-not $app) { return $null }
    # WhatsApp vill ha siffror utan plus i sin egen URI.
    $arg = if ($app.Id -eq 'whatsapp') { $e164.TrimStart('+') } else { $e164 }
    return ($app.Uri -f $arg)
}

# Lamnar over numret. Returnerar det normaliserade numret vid lyckad overlamning,
# annars $null. Sjalva uppringningen gor du i appen - se kommentaren ovan.
function Start-PhoneHandover([string]$nummer, $app) {
    $uri = Get-CallUri $nummer $app
    if (-not $uri) { return $null }
    try { Start-Process $uri -ErrorAction Stop }
    catch {
        $tray.ShowBalloonTip(5000, 'Telefonassistent',
            (SvText "Kunde inte ~oppna samtalsappen: $($_.Exception.Message)"), 'Error')
        return $null
    }
    return (Format-PhoneNumber $nummer)
}

# --- Servern (hjarnan) ----------------------------------------------------------

function Test-TaServer {
    try {
        $r = Invoke-WebRequest -Uri "$script:taServer/roll" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        return $r.StatusCode -eq 200
    } catch { return $false }
}

function Start-TaServer {
    if (Test-TaServer) { return $true }
    $rot = Get-TaRoot
    if (-not $rot) { return $false }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'node'
    $psi.Arguments = 'server.js'
    $psi.WorkingDirectory = $rot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try { $script:taNode = [System.Diagnostics.Process]::Start($psi) } catch { return $false }
    for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Milliseconds 400; if (Test-TaServer) { return $true } }
    return $false
}

function Stop-TaServer {
    if ($script:taNode -and -not $script:taNode.HasExited) {
        try { $script:taNode.Kill() } catch { }
    }
    $script:taNode = $null
}

# --- Start / stopp --------------------------------------------------------------

function Start-Telefonassistent([string]$roll = 'svarare', [int]$tystnad = 400) {
    if ($script:taBridge) { return $true }
    # Mirror of Start-Meeting's guard: meeting recording and the bridge both tap
    # the system loopback, so they must never run at the same time.
    if ($script:meeting -or $script:meetFinishing) {
        $tray.ShowBalloonTip(5000, 'Telefonassistent', (SvText 'Ett m~ote spelas in - stoppa det f~orst (Ctrl+Shift+M).'), 'Warning')
        return $false
    }

    $ut = Get-TaValdUtgang
    if (-not $ut) {
        $tray.ShowBalloonTip(4000, 'Telefonassistent', (SvText 'Hittar ingen ljudutg~ang.'), 'Error'); return $false
    }
    if ($ut.Namn -notmatch 'CABLE') {
        $tray.ShowBalloonTip(5000, 'Telefonassistent',
            (SvText "Utg~angen ~er '$($ut.Namn)'. D~a h~ors AI:n i h~ogtalarna i st~ellet f~or i samtalet. V~elj CABLE Input i menyn."), 'Warning')
    }
    if (-not (Start-TaServer)) {
        $var = Get-TaRoot
        $txt = if ($var) { (SvText "F~ar inte ig~ang servern i $var. ~Ar node installerat?") }
               else { (SvText 'Hittar inte Telefonsvararen. V~elj mappen via menyn (Telefonassistent: serverkatalog).') }
        $tray.ShowBalloonTip(6000, 'Telefonassistent', $txt, 'Error'); return $false
    }

    try {
        $b = New-Object PhoneBridge
        $b.Start($ut.Id, $script:taServer, $roll, $tystnad)
        $script:taBridge = $b
        $script:taRoll = $roll
    } catch {
        $tray.ShowBalloonTip(5000, 'Telefonassistent', (SvText "Kunde inte starta ljudet: $($_.Exception.Message)"), 'Error')
        return $false
    }

    $tray.Icon = $icoMeet
    $tray.Text = 'Diktatorn - telefonassistent aktiv'
    $tray.ShowBalloonTip(3500, 'Telefonassistent',
        (SvText "Lyssnar p~a systemljudet, talar till $($ut.Namn). Kalibrerar bakgrundsljud en halv sekund."), 'Info')
    $true
}

function Stop-Telefonassistent {
    if (-not $script:taBridge) { return }
    $turer = $script:taBridge.TurerKorda
    $samtalsId = $script:taBridge.SamtalsId    # maste hamtas fore Stop()
    try { $script:taBridge.Stop() } catch { }
    $script:taBridge = $null

    # Sammanfattningen ar poangen med samtalet - hamta den innan servern stangs.
    # Id:t maste vara samma som bryggan anvande, annars finns inget samtal att
    # sammanfatta.
    $sammanfattning = ''
    if ($turer -gt 0) {
        try {
            $svar = Invoke-RestMethod -Uri "$script:taServer/api/avsluta" -Method Post -TimeoutSec 30 `
                        -ContentType 'application/json' -Body (@{ id = $samtalsId } | ConvertTo-Json)
            $sammanfattning = $svar.sammanfattning
        } catch { }
    }

    $tray.Icon = $icoIdle
    $tray.Text = 'Diktatorn - redo'
    if ($sammanfattning) {
        $tray.ShowBalloonTip(9000, 'Samtalet sammanfattat', $sammanfattning, 'Info')
    } else {
        $tray.ShowBalloonTip(3000, 'Telefonassistent', "Avslutad. $turer turer.", 'Info')
    }
}
