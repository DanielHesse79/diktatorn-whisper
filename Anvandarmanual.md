# Diktatorn – Användarmanual 🎙️👔

Diktatorn låter dig **prata istället för att skriva**. Tryck en snabbtangent, prata, och texten skrivs in
där markören står – i vilken app som helst. Den kan också **transkribera hela möten**. Allt körs på din
egen dator (privat), med ett snabbt moln-alternativ när du vill.

---

## 1. Kom igång

1. Installera med **`Diktatorn-Setup.exe`**. Genvägarna på skrivbordet och i Start-menyn får **Diktatorns
   egen ikon** (vår lilla diktator). Starta därifrån.
2. När appen kör visas den nere till höger i aktivitetsfältet (systemfältet) som en liten **färgad prick**
   som byter färg efter läge:
   - 🟢 **grön** = redo
   - 🔴 **röd** = spelar in diktering
   - 🔵 **blå** = spelar in möte
   - 🟡 **gul** = transkriberar

> Tips: klicka på pilen `^` i aktivitetsfältet och dra ut Diktatorn-pricken så den alltid syns.

---

## 2. Diktering – prata, få text

Ställ markören där du vill ha texten (e-post, Word, chatt, sökruta – vad som helst) och välj ett sätt:

| Sätt | Hur |
|------|-----|
| **Håll inne (push-to-talk)** | Håll **Ctrl+Shift**, prata, **släpp**. Texten skrivs in direkt. |
| **På/av (toggle)** | Tryck **Ctrl+Shift+D** för att börja, prata, tryck **Ctrl+Shift+D** igen för att stoppa. |

Använd push-to-talk för korta saker, toggle för längre stycken (då slipper du hålla inne).

### Tips för bästa resultat
- **Prata naturligt** – du behöver inte tala långsamt eller robotaktigt.
- **Skiljetecken sköts automatiskt** – Whisper sätter punkt och komma åt dig utifrån hur du pausar.
- **Lite paus efter att du tryckt** innan du börjar prata, så missas inte första ordet.
- **Rätt mikrofon spelar roll** – ett headset ger renare ljud än rumsmikrofon (se punkt 4).
- Blir ett ord fel? Diktera om den biten, eller rätta för hand – snabbare än att tjafsa med tekniken.

---

## 3. Mötestranskribering

Diktatorn spelar in **två spår samtidigt** under ett online-möte (Teams, Zoom, Meet):
- **datorljudet** = det de andra deltagarna säger → märks **Övriga:**
- **din mikrofon** = det du säger → märks **Du:**

Transkriberingen sker **löpande under mötet** i 30-sekundersblock med tidsstämplar.

1. Starta mötet som vanligt.
2. Tryck **Ctrl+Shift+M** (eller högerklicka ikonen → *Starta mötesinspelning*). En liten ruta frågar
   **Svenska eller Engelska** – välj det språk mötet hålls på (Enter väljer det du använde sist).
   Ikonen blir blå.
3. Vill du kika medan mötet pågår: högerklicka ikonen → **Visa transkript (live)** – filen växer i realtid.
4. När mötet är klart: tryck **Ctrl+Shift+M** igen. Filen kompletteras med **talfördelning**
   (hur många minuter och procent du respektive de andra pratade) och öppnas automatiskt
   (sparas i `Dokument\Transcriptions`).

Exempel på resultat:
```
[00:03:30] Övriga: Vi behöver besluta om budgeten innan fredag.
[00:03:30] Du: Jag tar fram ett förslag imorgon.
...
Talfördelning: Du 12,4 min (38%)  |  Övriga 20,1 min (62%)
```

### Ställ in mötesspråket

Tray-menyn → **Mötesspråk**: **Svenska** (standard) eller **Engelska**. Välj det språk mötet hålls på
innan du startar.

> **Varför inget "Auto"?** Whisper kan inte känna igen språk lokalt – den kan bara *tvinga* fram ett.
> Tvingar man fel språk **översätter** den i stället för att transkribera: svenskt tal blir flytande
> engelska, engelskt tal blir flytande svenska. Resultatet ser ut som en fungerande transkription,
> bara på fel språk, vilket är lätt att missa tills man läser texten. Ett felval här kostade fyra
> riktiga möten innan det upptäcktes. Därför är det ett medvetet, uttryckligt val – du vet ändå vilket
> språk mötet är på.

Byter ni språk mitt i mötet blir det block på fel språk oavsett inställning – välj det språk som
dominerar.

### Ljudkontroll vid start

Några sekunder in i mötet mäter Diktatorn ljudet och varnar direkt om något är tyst – innan du hinner
prata i onödan:

- **"Mikrofonen verkar tyst"** – din röst når inte inspelningen. Kontrollera att rätt mikrofon är vald
  (tray → Mikrofon) och att den inte är avstängd.
- **"Inget datorljud har hörts"** – de andra deltagarna spelas inte in. Vanligaste orsaken: mötesljudet
  går till ett headset som inte är datorns standard-uppspelningsenhet, så Diktatorn fångar tystnad.
  Byt uppspelningsenhet i Windows ljudinställningar.

Den här kontrollen finns för att ett tyst möte annars bara märks efteråt, som ett tomt transkript.

### Spara mötesljudet (säkerhetskopia)

Tray-menyn → **Spara mötesljud (7 dagar)**. Normalt raderas ljudet direkt efter transkribering.
Slår du på det här sparas råljudet i `Dokument\Transcriptions\Motesljud\` i sju dagar (rensas sedan
automatiskt). Då finns en väg tillbaka om något blir fel – till exempel om språket var felinställt –
så att mötet kan transkriberas om. Kostar diskutrymme (ungefär 100–200 MB per timmes möte), så det är
avstängt som standard.

> 💡 Med **headset** blir uppdelningen Du/Övriga ren. Kör du mötet på **högtalare** hör din mikrofon
> även de andra, så deras ord kan dyka upp under "Du".

> ⚠️ Informera alltid deltagarna om att mötet spelas in/transkriberas. För känsliga möten: använd
> **Lokal** transkribering (se punkt 5), så lämnar ljudet aldrig din dator.

### Talanalys (valfritt): coacha dig själv, inte de andra
Slå på under **tray-ikonen → Talanalys (privat, bara du)**. Analysen tittar **enbart på dina egna
repliker** – aldrig på motpartens.

| Läge | Vad du får |
|------|-----------|
| **Av** (standard) | Ingen analys alls. |
| **Statistik + krokodilvarning** | Helt lokalt: räknar dina utfyllnadsord ("typ", "liksom", "alltså", "eh"...), frågor du ställer och din längsta monolog. Under mötet får du en diskret **krokodilvarning** om du pratat mer än 70 % de senaste 10 minuterna. Stor mun, små öron – lyssna mer. |
| **Statistik + AI-coach** | Som ovan, plus en kort AI-coachrapport efter mötet (via Groq, kräver API-nyckel). Endast **dina** repliker skickas – motpartens ord lämnar aldrig datorn. |

Resultatet läggs längst ner i mötestranskriptet. Dessutom sparas en trendfil
(`Dokument\Transcriptions\talanalys-trend.csv`) så du ser din utveckling över tid – talandel,
utfyllnadsord per minut, frågor. Transkriptet du läser är alltid städat; analysen tittar på
råversionen av ditt tal under huven.

**AI-coachen har minne.** Rapporterna sparas i `Dokument\Transcriptions\coach-arkiv.md` och
coachen läser sina senaste rapporter inför varje nytt möte – den följer alltså upp övningen den
gav dig ("frågorna upp från 1 till 3, bra") istället för att börja om varje gång.

**Välj coach-motor** under **tray-ikonen → Coach-motor (AI-coach)**:

| Motor | Kostnad | Integritet | Kommentar |
|---|---|---|---|
| **Groq** (standard) | Gratis | Dina repliker → Groq | Samma nyckel som transkriberingen |
| **Ollama** | Gratis | Helt lokalt – inget lämnar datorn | Kräver [Ollama](https://ollama.com) installerat och en nedladdad modell |
| **OpenRouter** | Per användning | Dina repliker → vald leverantör | Valfri modell (Claude, GPT, Gemini...). Nyckel via menyn |

Standardmodell per motor kan bytas genom att skriva ett modellnamn i filen
`diktatorn-coach-model.txt` i programmappen (t.ex. `qwen2.5:14b` för Ollama eller
`anthropic/claude-haiku-4.5` för OpenRouter).

---

## 3b. Journal – prata in dagboken

Tryck **Ctrl+Shift+N**, prata, tryck igen. Texten skrivs **inte** vid markören utan läggs till i
dagens fil: `Dokument\Journal\ÅÅÅÅ-MM-DD.md`, med klockslag som rubrik. Flera anteckningar samma
dag hamnar under varandra i samma fil.

Bra till reflektioner efter ett möte, idéer i bilen, eller dagens lärdomar. Öppna dagens fil via
tray-menyn → **Öppna dagens journal**.

> Hör Diktatorn inget tal (du råkade trycka, eller mikrofonen var avstängd) sparas **ingen**
> anteckning – du får meddelandet *"Inget tal hördes"*. Det är medvetet: en påhittad anteckning
> i din journal vore värre än ingen alls.

---

## 3c. Sälj-script – checklista som bockar av sig själv

Tray-menyn → **Sälj-script** öppnar scripthanteraren: alla dina script i en lista till vänster,
texten redigerbar till höger.

| Knapp | Vad den gör |
|-------|-------------|
| **Spara** | Sparar ändringarna i det öppna scriptet. |
| **Nytt** | Skapar ett tomt script med grundstruktur. |
| **Generera med AI** | Beskriv mötet – *"första möte med IT-chef på industribolag, vi säljer automatiserad rapportering"* – så skriver AI:n ett komplett script åt dig. |
| **Förbättra** | Låter AI:n skärpa det öppna scriptet. Säg vad som saknas, t.ex. *"fler frågor om budget"*. |
| **Kopiera** / **Ta bort** | Duplicera eller radera. |
| **Använd i samtal** | Öppnar checklistan (fönstret som lägger sig överst under samtalet). |

AI-knapparna använder samma motor som talanalysen (Groq/Ollama/OpenRouter). Välj **Ollama** om du
vill att beskrivningarna av dina affärer stannar på datorn.

> Granska alltid ett AI-genererat script innan du använder det skarpt. Det blir en bra grund,
> men det vet inget om just din produkt eller din kund.

Scripten är vanliga `.md`-filer i `Dokument\SalesScripts`, så du kan lika gärna redigera dem i
valfri editor eller dela dem med en kollega. Formatet är vanlig markdown:

```markdown
## Behovsanalys
- Vad är den största utmaningen just nu?
- Hur löser ni det idag?
```

Rubriker (`##`) blir avsnitt, punkter (`-`) blir kryssrutor. Öppna via tray-menyn →
**Sälj-script**. Fönstret lägger sig överst i högra hörnet så du ser det under samtalet.

**Det smarta:** kör du samtidigt en **mötesinspelning i live-läge** bockas punkterna av
automatiskt allt eftersom ni pratar – frågar du om budget bockas "Finns budget avsatt?" av av sig
självt. Längst ner ser du hur många punkter du klarat av och din aktuella talandel. Du kan alltid
bocka manuellt också.

Automatiken använder samma coach-motor som talanalysen (Groq/Ollama/OpenRouter) och är medvetet
försiktig – den bockar bara av det ni faktiskt diskuterat, inte det som råkar nämnas i förbifarten.

---

## 3d. Diktatorn-fönstret (dashboard)

Dubbelklicka på systemfältsikonen (eller högerklicka → **Öppna Diktatorn...**) för att öppna ett fönster
med fem flikar. Tray-ikonen och kortkommandona finns kvar som snabbvägar – fönstret är ett komplement.

- **Möte** – visas live medan ett möte pågår: tid, talandel (du mot övriga), nivåmätare för din mikrofon
  och datorljudet med **OK/TYST?**-markering, krokodilvarning, säljscript-status och det växande
  transkriptet. Här ser du direkt om något är tyst. Pågår inget möte står det så, i stället för tomma
  mätare som ser ut som ett fel.
- **Telefon** – nummerfält med **Ring**-knapp, och start/stopp för AI-assistenten (punkt 9). Skriv numret
  hur du vill – `070-123 45 67`, `+46 70 123 45 67` eller `0046...` – det översätts till `+46701234567`
  innan det lämnas över. Enter ringer. Se punkt 9c för vad knappen faktiskt gör.
- **Inställningar** – allt på ett ställe: mikrofon, modell, transkribering (lokal/moln), grafikkort,
  mötesläge, mötesspråk, coach-motor, talanalys, spara-ljud och API-nycklar.
- **Historik** – alla dina möten. Öppna transkript, öppna ljudmappen, eller **Återskapa transkript** från
  sparat ljud (välj språk) – så kan ett möte transkriberas om, t.ex. om språket blev fel.
- **Talanalys** – trenden över dina möten som tabell och en graf över talandel, där staplar över 70 %
  (krokodilgränsen) blir röda.

---

## 4. Tray-menyn (högerklicka ikonen)

| Val | Vad det gör |
|-----|-------------|
| **Talhastighet** | Visar hur snabbt du pratar (tecken/min + ord/min) och ett snitt för sessionen. |
| **Starta mötesinspelning** | Samma som Ctrl+Shift+M. |
| **Visa transkript (live)** | Öppnar det växande transkriptet medan mötet pågår. |
| **Öppna dagens journal** | Öppnar dagens journalfil (se punkt 3b). |
| **Sälj-script** | Öppnar en checklista som guidar dig genom ett förberett säljsamtal (se punkt 3c). |
| **Mötestranskribering** | **Live** (texten växer under mötet) eller **Efter mötet** (spelar bara in under mötet och transkriberar allt när du trycker stopp – skonsamt för klenare datorer; krokodilvarningen fungerar ändå). Installationen mäter din dators hastighet och väljer rätt läge automatiskt – se `Diktatorn-rekommendation.txt` i programmappen. |
| **Mötesspråk** | **Svenska** (standard) eller **Engelska**. Ställ in vilket språk mötet hålls på – se förklaringen nedan. |
| **Mikrofon** | Välj vilken mikrofon dikteringen lyssnar på. Välj ditt headset, inte t.ex. webbkameran. |
| **Modell** | Snabbhet vs noggrannhet (se punkt 5). |
| **Grafikkort** | Visas bara om datorn har flera. Lokal transkribering körs på valt kort – välj alltid det **dedikerade** (t.ex. NVIDIA GeForce), aldrig det integrerade. Skillnaden är dramatisk: på en testmaskin gav det integrerade kortet 0,3x realtid och det dedikerade 10,9x – 34 gånger snabbare. Diktatorn väljer dedikerat kort automatiskt, men här kan du styra om. |
| **Transkribering** | Växla mellan **Lokal** (din dator, privat) och **Groq moln** (snabbt, se punkt 6). |
| **Ange Groq API-nyckel** | Klistra in din gratis molnnyckel (se punkt 6). |
| **Starta telefonassistent** | AI som pratar i dina telefonsamtal (se punkt 9). Visas bara om tillägget är installerat. |
| **Testa kabeln** | Spelar en ton in i samtalet. Hör motparten den fungerar ljudvägen ut. |
| **Telefonassistent: utgång** | Ska vara `CABLE Input`. Väljer du högtalarna talar AI:n till rummet i stället för in i samtalet. |
| **Telefonassistent: roll** | **Svarare** besvarar inkommande samtal, **Uppringare** ringer ut åt dig. |
| **Telefonassistent: serverkatalog** | Behövs bara om Telefonsvararen ligger på en ovanlig plats. |
| **Avsluta** | Stänger Diktatorn. |

Alla val sparas och gäller även nästa gång du startar.

---

## 5. Välj modell – snabbhet vs noggrannhet

Diktatorn kan köra tre olika "språkmodeller" lokalt:

| Modell | Hastighet | Kvalitet | När |
|--------|-----------|----------|-----|
| **Snabb (base)** | ⚡⚡⚡ | okej | snabba korta anteckningar |
| **Balanserad (small)** | ⚡⚡ | bra | **standard – funkar för det mesta** |
| **Noggrann (medium)** | ⚡ | bäst | klurig svenska, namn, facktermer |

Byt under **Mikrofon-menyn → Modell**. Märker du att svenskan blir lite knackig på en snabb modell – höj ett
steg.

---

## 6. Gratis moln-läge med Groq (snabbare + ofta bättre svenska)

Groq kör transkriberingen i molnet, **mycket snabbt** och med hög kvalitet – perfekt om du sitter på en
svagare dator (t.ex. en laptop utan kraftigt grafikkort). Det är **gratis** för normal användning
(2 000 transkriberingar per dag, inget kreditkort krävs).

### Så skaffar du nyckeln (engångsjobb, ~2 minuter)
1. Gå till **https://console.groq.com** och **logga in** (Google, GitHub eller e-post).
2. Klicka på **API Keys** i menyn.
3. Klicka **Create API Key**, ge den ett namn (t.ex. "Diktatorn") och skapa.
4. **Kopiera nyckeln** direkt – den börjar med `gsk_...` och visas bara en gång.

### Aktivera i Diktatorn
5. Högerklicka tray-ikonen → **Ange Groq API-nyckel** → klistra in nyckeln → OK.
6. Högerklicka tray-ikonen → **Transkribering** → välj **Groq moln**.

Klart! Nu går både diktering och möten via molnet. Vill du tillbaka till privat/lokalt: välj **Lokal** i
samma meny.

> ⚠️ **Integritet:** i moln-läge skickas ljudet till Groq. För **känsliga möten (t.ex. intervjuer eller
> kanditatuppgifter) – använd Lokal** så stannar allt på din dator.

---

## 7. Felsökning

| Problem | Lösning |
|---------|---------|
| Inget händer när jag trycker Ctrl+Shift | Kolla att solros-ikonen finns i systemfältet (annars starta Diktatorn). |
| Texten hamnar i fel app | Klicka i rätt textfält **innan** du dikterar – texten går dit fokus är. |
| Konstig/fel text | Välj rätt mikrofon (punkt 4) eller höj modellen till medium (punkt 5). |
| Det tar lång tid | Prova en snabbare modell, eller slå på Groq moln-läge (punkt 6). |
| Mötet blev tomt | Diktatorn fångar **datorljud** – det måste faktiskt komma ljud ur högtalarna/hörlurarna under mötet. |
| Texten kapas i långa meningar | Bör vara löst i senaste versionen – hör av dig om det återkommer. |

---

## 8. Kortkommandon i sammanfattning

| Tangent | Funktion |
|---------|----------|
| **Håll Ctrl+Shift** | Diktera (push-to-talk) |
| **Ctrl+Shift+D** | Diktera (på/av) |
| **Ctrl+Shift+N** | Journalanteckning (på/av) |
| **Ctrl+Shift+M** | Starta/stoppa mötesinspelning |

Om ett kortkommando redan används av ett annat program varnar Diktatorn med en ballong vid start –
då fungerar just den tangenten inte, och du får stänga det andra programmet eller använda tray-menyn.

---

## 9. Telefonassistent – AI som pratar i dina samtal

En AI som hör motparten och svarar högt i telefonsamtalet, ungefär en sekund efter att hen slutat prata.
Den kan besvara samtal när du inte hinner, eller ringa upp någon åt dig.

Tillägget är valfritt. Saknas något av nedanstående visas det helt enkelt inte i menyn.

### Det här behövs

1. **[VB-CABLE](https://vb-audio.com/Cable/)** – gratisversionen räcker. Det finns inget annat sätt att
   få in ljud i Telefonlänks mikrofon; något API för det existerar inte.
2. **Telefonsvararen** – den separata servern som håller personligheten och sköter tal-till-tal.
   Diktatorn startar och stoppar den automatiskt. **API-nyckeln bor där, aldrig i Diktatorn.**
3. **Telefonlänk**, ihopparad med telefonen.

### Fungerar med vilken samtalsapp som helst

Assistenten ser inte vilket program som ringer. Den fångar det datorn spelar upp och talar in i kabeln –
så **Telefonlänk, WhatsApp, Teams, Zoom och Discord fungerar lika bra**.

Det enda som skiljer är *var* du pekar appens mikrofon till `CABLE Output`:

| App | Var mikrofonen väljs | Påverkar andra program? |
|---|---|---|
| **WhatsApp** | Inställningar → Röst och video → Mikrofon | Nej |
| **Teams / Zoom / Discord** | appens egna ljudinställningar | Nej |
| **Telefonlänk** | har inget eget val – tar systemets standard | **Ja**, se nedan |

**Appar med eget mikrofonval är att föredra.** Då kan systemets standardmikrofon förbli din riktiga, och
allt annat på datorn fungerar som vanligt.

### Ljudinställningar i Windows

Utdata ska alltid vara **dina högtalare** – det är där samtalet spelas upp, och det är den strömmen
assistenten lyssnar på.

Indata beror på appen. Har den eget mikrofonval: låt systemets standard vara din riktiga mikrofon och
välj `CABLE Output` inne i appen. Klart.

**Bara för Telefonlänk**, som saknar eget val:

| Inställning | Värde |
|---|---|
| Indata, standard **och** kommunikation | `CABLE Output` |

Båda rollerna måste peka på kabeln – Telefonlänk hämtar den vanliga standarden, inte
kommunikationsrollen, och tar annars din rumsmikrofon. Kommunikationsrollen sätts i `mmsys.cpl`, den
vanliga under Inställningar → System → Ljud.

Priset är att du blir tyst i alla andra program så länge det gäller, eftersom de också använder
standardmikrofonen. Vill du ringa i WhatsApp under tiden får du välja din riktiga mikrofon inne i
WhatsApp.

**Starta om Telefonlänk efter varje ändring.** Den väljer mikrofon när den startar och sitter annars kvar
på den gamla.

Kryssa **inte** i "Lyssna på den här enheten" på `CABLE Output`. Då hamnar AI:ns röst i högtalarna,
loopbacken fångar upp den, och den börjar svara på sig själv.

### Så använder du den

1. Högerklicka ikonen → **Telefonassistent: utgång** → välj `CABLE Input`
2. Välj **roll**: *Svarare* om den ska besvara samtal, *Uppringare* om den ska ringa ut
3. Ring, och tryck **Starta telefonassistent**

Testa alltid **Testa kabeln** först i ett nytt samtal – tonen visar direkt om ljudvägen ut fungerar,
utan att blanda in AI:n. Hör motparten pipen är resten bara att köra.

När du stoppar assistenten hämtas en sammanfattning av samtalet och visas som en ballong.

Samma start- och stoppknapp finns i **Telefon**-fliken i Diktatorn-fönstret, tillsammans med kabeltestet
och en statusrad som visar vilken utgång assistenten talar till.

### 9c. Ring-knappen – vad den gör och inte gör

**Ring-knappen kopplar inte upp något samtal.** Den normaliserar numret och lämnar över det till din
samtalsapp; själva uppringningen trycker du på där. Ljudvägen är oförändrad – loopback in, `CABLE Input` ut.

Det finns ingen väg runt det. Bryggan är app-agnostisk med flit, och ingen av samtalsapparna erbjuder ett
API för att koppla upp ett samtal åt någon annan. Vinsten är att du slipper leta fram fönstret och knappa
in numret igen.

Välj i **Lämna över till** vilken app som ska ta emot. Listan visar bara appar som faktiskt är installerade:

| Val | Numret hamnar i |
|---|---|
| **Telefonlänk** | Telefonlänks nummerfält – ringer via din mobil |
| **WhatsApp** | WhatsApp-chatten med det numret |
| **Teams** | Teams-samtal till numret |
| **Systemets tel:-hanterare** | Vad Windows nu råkar ha kopplat till `tel:` – kontrollera det innan du litar på valet |

Förhandsraden under fältet visar exakt vilket nummer som lämnas över, till vilken app. Blir den röd är
numret inte färdigskrivet, och **Ring** är avstängd tills det är det.

**Vill du ringa direkt från Diktatorn på riktigt** krävs en SIP-trunk och ett eget nummer hos en operatör.
Då försvinner både VB-CABLE och loopbacken – men det är en annan bygge än det här.

### Om det inte fungerar

| Symtom | Orsak |
|---|---|
| Motparten hör ditt rum | Telefonlänk tog rumsmikrofonen. Sätt `CABLE Output` som **båda** standardrollerna och starta om Telefonlänk. |
| Du hör AI:n i högtalarna | Utgången står på högtalarna. Byt till `CABLE Input`. |
| AI:n svarar på sig själv | "Lyssna på den här enheten" är ikryssad på `CABLE Output`. Kryssa ur. |
| Ingenting händer alls | Servern startade inte. Kontrollera att Node är installerat och att serverkatalogen pekar rätt. |

Lycka till – nu styr du med rösten. 🫡
