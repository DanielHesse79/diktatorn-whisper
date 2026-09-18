# Integration test (network): the coach engine must answer through the real
# Groq endpoint, and the sales-script auto-check prompt must tick the right
# items without inventing coverage from small talk.
#
# Skipped unless DIKTATORN_TEST_NETWORK=1 (it spends API quota and needs a key):
#   $env:DIKTATORN_TEST_NETWORK='1'; .\Run-Tests.ps1     (or Run-Tests -Network)
. (Join-Path $PSScriptRoot '_TestLib.ps1')

if ($env:DIKTATORN_TEST_NETWORK -ne '1') { Skip-Test 'natverkstest - kor Run-Tests.ps1 -Network' }

# Config the extracted functions expect, pointed at the repo's real key files.
$root = $script:RepoRoot
$coachModelCfg     = Join-Path $root 'diktatorn-coach-model.txt'
$groqKeyFile       = Join-Path $root 'diktatorn-groq.txt'
$openrouterKeyFile = Join-Path $root 'diktatorn-openrouter.txt'
# Read from the source, never hand-copied: a copy here kept naming the model Groq had
# retired, so this test could only ever have exercised the dead configuration.
Import-AppVariable 'Diktatorn.ps1' 'coachDefaults'
Import-AppVariable 'Diktatorn.ps1' 'coachFallbacks'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Write-Log($m) {}
Import-AppFunction 'Diktatorn.ps1' @('Get-GroqKey', 'Get-CoachKey', 'Get-HttpErrorBody', 'Find-CoachModel', 'Send-CoachLLM', 'Invoke-CoachLLM')
$script:coach = 'groq'; $script:coachModelAuto = $null
if (-not (Get-CoachKey 'groq')) { Skip-Test 'ingen Groq-nyckel pa maskinen' }

# Same system prompt as the meeting timer's script auto-check.
$sys = 'You match sales-call checklist items against a conversation snippet (Swedish or English). Reply ONLY with comma-separated numbers of the items that are clearly covered/addressed in the snippet, or NONE. Be conservative: only mark items genuinely discussed.'
$checklist = @(
    '1. Halsa och tacka for tiden',
    '2. Vad ar den storsta utmaningen just nu?',
    '3. Vem fattar beslutet?',
    '4. Finns budget avsatt?'
) -join "`n"

function Get-Ticks([string]$snippet) {
    $ans = Invoke-CoachLLM $sys ("CHECKLIST:`n$checklist`n`nSNIPPET:`n$snippet")
    if ($ans -match 'NONE') { return @() }
    return @([regex]::Matches($ans, '\d+') | ForEach-Object { [int]$_.Value } | Sort-Object -Unique)
}

$a = Get-Ticks 'Du: Hej och tack for att du tog dig tid idag. Du: Vad ar er storsta utmaning just nu? Ovriga: Manuell rapportering tar for mycket tid.'
Check 'tack + utmaning -> 1,2' ((@(Compare-Object $a @(1, 2)).Count -eq 0)) "fick $($a -join ',')"
$b = Get-Ticks 'Du: Vem ar det som fattar beslutet? Ovriga: Jag och var CFO. Du: Finns det budget avsatt?'
Check 'beslut + budget -> 3,4' ((@(Compare-Object $b @(3, 4)).Count -eq 0)) "fick $($b -join ',')"
$c = Get-Ticks 'Du: Vilket vader idag. Ovriga: Ja helt otroligt. Du: Har du varit pa kontoret lange?'
Check 'smaprat -> inget bockas' ($c.Count -eq 0) "fick $($c -join ',')"

# Groq retires models and answers 404 model_not_found. That silently broke the coach and
# this checklist for weeks in 2026-09; the engine must now switch model by itself.
$ordinarie = $coachDefaults.groq.model
$coachDefaults.groq.model = 'llama-3.3-70b-versatile'; $script:coachModelAuto = $null
$ans = $null; try { $ans = Invoke-CoachLLM 'Svara bara: ok' 'ok?' } catch { $ans = "FEL: $($_.Exception.Message)" }
Check 'pensionerad modell -> byter sjalv och svarar' ($script:coachModelAuto -and $ans -and $ans -notlike 'FEL:*') "via $($script:coachModelAuto)"
# Reasoning models spend max_tokens thinking; without low effort the reply was EMPTY.
$coachDefaults.groq.model = 'openai/gpt-oss-120b'; $script:coachModelAuto = $null
$ans = $null; try { $ans = Invoke-CoachLLM 'Svara pa svenska med en mening.' 'Hur mar du idag?' } catch { }
Check 'resonerande modell ger icke-tomt svar' ([bool]$ans) "$(if ($ans) { $ans.Length } else { 0 }) tecken"
$coachDefaults.groq.model = $ordinarie
Complete-Test
