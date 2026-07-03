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
2. Tryck **Ctrl+Shift+M** (eller högerklicka ikonen → *Starta mötesinspelning*). Ikonen blir blå.
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

---

## 4. Tray-menyn (högerklicka ikonen)

| Val | Vad det gör |
|-----|-------------|
| **Talhastighet** | Visar hur snabbt du pratar (tecken/min + ord/min) och ett snitt för sessionen. |
| **Starta mötesinspelning** | Samma som Ctrl+Shift+M. |
| **Visa transkript (live)** | Öppnar det växande transkriptet medan mötet pågår. |
| **Mikrofon** | Välj vilken mikrofon dikteringen lyssnar på. Välj ditt headset, inte t.ex. webbkameran. |
| **Modell** | Snabbhet vs noggrannhet (se punkt 5). |
| **Transkribering** | Växla mellan **Lokal** (din dator, privat) och **Groq moln** (snabbt, se punkt 6). |
| **Ange Groq API-nyckel** | Klistra in din gratis molnnyckel (se punkt 6). |
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
| **Ctrl+Shift+M** | Starta/stoppa mötesinspelning |

Lycka till – nu styr du med rösten. 🫡
