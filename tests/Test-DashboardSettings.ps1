# Settings tab: every dropdown must call its Set-* function with the right value
# on change - and none of them may fire during build (loading the current value
# must not trigger a redundant Set-*, which could balloon-spam or reload models).
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppFunction 'Diktatorn.ps1' @('Build-SettingsTab')

$script:calls = @{}
function Set-MicDevice($v)  { $script:calls['mic'] = $v }
function Set-Model($v)      { $script:calls['model'] = $v }
function Set-Backend($v)    { $script:calls['backend'] = $v }
function Set-Gpu($v)        { $script:calls['gpu'] = $v }
function Set-MeetMode($v)   { $script:calls['mode'] = $v }
function Set-MeetLang($v)   { $script:calls['lang'] = $v }
function Set-Coach($v)      { $script:calls['coach'] = $v }
function Set-Talanalys($v)  { $script:calls['tal'] = $v }
function Set-KeepAudio($v)  { $script:calls['keep'] = $v }
function Get-GroqKey { 'x' }
function Get-CoachKey($p) { 'x' }

$script:micNames = @('Mikrofon A', 'Mikrofon B'); $script:micDevice = 0
$modelChoices = [ordered]@{ 'Snabb (base)' = 'ggml-base.bin'; 'Balanserad (small)' = 'ggml-small.bin'; 'Noggrann (medium)' = 'ggml-medium.bin' }
$script:modelFile = 'ggml-medium.bin'
$script:backend = 'local'
$script:adapters = @('NVIDIA GeForce RTX 5070 Ti', 'AMD Radeon(TM) Graphics'); $script:adapter = $script:adapters[0]
$script:meetMode = 'live'; $script:meetLang = 'sv'; $script:coach = 'groq'; $script:talanalys = 'coach'
$script:keepAudio = $true; $keepAudioDays = 7
$groqKeyFile = Join-Path $env:TEMP 'x1'; $openrouterKeyFile = Join-Path $env:TEMP 'x2'
$tray = [pscustomobject]@{}
$tray | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value { }

$tab = New-Object System.Windows.Forms.TabPage
Build-SettingsTab $tab
[System.Windows.Forms.Application]::DoEvents()

$script:combos = @()
function Walk($c) { foreach ($x in $c.Controls) { if ($x -is [System.Windows.Forms.ComboBox]) { $script:combos += $x }; Walk $x } }
Walk $tab
Check '8 dropdowns byggda'            ($script:combos.Count -eq 8) "fick $($script:combos.Count)"
Check 'inga Set-* anrop vid laddning' ($script:calls.Count -eq 0) "fick $($script:calls.Count)"

foreach ($cb in $script:combos) { $cb.SelectedIndex = $(if ($cb.SelectedIndex -eq 0) { 1 } else { 0 }) }
[System.Windows.Forms.Application]::DoEvents()
$expected = @('mic', 'model', 'backend', 'gpu', 'mode', 'lang', 'coach', 'tal')
$missing = @($expected | Where-Object { -not $script:calls.ContainsKey($_) })
Check 'alla dropdowns kopplade till ratt Set-*' ($missing.Count -eq 0) "saknar: $($missing -join ', ')"
Check 'gpu far ratt varde'  ($script:calls['gpu']  -eq $script:adapters[1])
Check 'lang far ratt varde' ($script:calls['lang'] -eq 'en')
Complete-Test
