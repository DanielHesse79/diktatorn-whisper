# Meeting language must resolve to 'sv' or 'en' - NEVER empty. An empty language
# on the local engine means English, which silently TRANSLATES Swedish meetings
# (the 2026-08 mistranslation bug). Legacy 'auto' configs must migrate to sv.
. (Join-Path $PSScriptRoot '_TestLib.ps1')

$meetLangCfg = Join-Path $env:TEMP 'dikt_test_meetlang.txt'
Import-AppFunction 'Diktatorn.ps1' @('Resolve-MeetLang', 'Get-ActiveMeetLang')

foreach ($case in @(
    @{ cfg = $null;    want = 'sv'; label = 'saknad konfigfil -> sv' },
    @{ cfg = 'sv';     want = 'sv'; label = 'sv -> sv' },
    @{ cfg = 'en';     want = 'en'; label = 'en -> en' },
    @{ cfg = 'auto';   want = 'sv'; label = "legacy 'auto' -> sv (far ALDRIG bli tomt)" },
    @{ cfg = 'skrap';  want = 'sv'; label = 'skrapvarde -> sv' },
    @{ cfg = '';       want = 'sv'; label = 'tom fil -> sv' }
)) {
    if ($null -eq $case.cfg) { Remove-Item $meetLangCfg -ErrorAction SilentlyContinue }
    else { Set-Content $meetLangCfg $case.cfg -NoNewline }
    $script:meetLang = Resolve-MeetLang
    $code = Get-ActiveMeetLang
    Check $case.label (($code -eq $case.want) -and ($code -ne '')) "fick '$code'"
}
Remove-Item $meetLangCfg -ErrorAction SilentlyContinue
Complete-Test
