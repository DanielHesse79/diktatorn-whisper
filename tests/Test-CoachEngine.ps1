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
$coachDefaults = @{
    groq       = @{ url = 'https://api.groq.com/openai/v1/chat/completions'; model = 'llama-3.3-70b-versatile' }
    ollama     = @{ url = 'http://localhost:11434/v1/chat/completions';      model = 'llama3.1' }
    openrouter = @{ url = 'https://openrouter.ai/api/v1/chat/completions';   model = 'openrouter/auto' }
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Write-Log($m) {}
Import-AppFunction 'Diktatorn.ps1' @('Get-GroqKey', 'Get-CoachKey', 'Invoke-CoachLLM')
$script:coach = 'groq'
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
Complete-Test
