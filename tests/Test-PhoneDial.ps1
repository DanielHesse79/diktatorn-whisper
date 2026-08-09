# Dialling from the UI: number normalisation, which app the number is handed to,
# and that the Ring button is wired and refuses half-typed numbers.
#
# Nothing here places a call. The handover is split into Get-CallUri (builds the
# URI) and Start-PhoneHandover (opens it), precisely so this test can verify the
# whole chain without Start-Process ever running.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppUi
Import-AppFunction 'Telefonassistent.ps1' @('Format-PhoneNumber', 'Get-CallApp', 'Set-CallApp', 'Get-CallUri')
Import-AppFunction 'Diktatorn.ps1' @('Build-PhoneTab', 'Update-DialPreview', 'Invoke-Dial', 'Update-PhoneTab')

$script:taAppCfg = Join-Path $env:TEMP 'dikt_test_telefonapp.txt'
Remove-Item $script:taAppCfg -ErrorAction SilentlyContinue

# --- Number normalisation ----------------------------------------------------
$fall = @(
    @{ in = '070-123 45 67';   ut = '+46701234567' }
    @{ in = '0701234567';      ut = '+46701234567' }
    @{ in = '+46 70 123 45 67'; ut = '+46701234567' }
    @{ in = '0046701234567';   ut = '+46701234567' }
    @{ in = '08-123 456';      ut = '+468123456' }
    @{ in = '(070) 123.45.67'; ut = '+46701234567' }
)
$fel = @()
foreach ($f in $fall) {
    $got = Format-PhoneNumber $f.in
    if ($got -ne $f.ut) { $fel += "'$($f.in)' -> '$got' (ville '$($f.ut)')" }
}
Check 'svenska format blir E.164' ($fel.Count -eq 0) ($fel -join '; ')

$skrap = @('', '   ', '070', '+46', 'abc', '07x1234567', '+4670123456789012345')
$slapptIgenom = @($skrap | Where-Object { Format-PhoneNumber $_ })
Check 'halvskrivet nummer vagras' ($slapptIgenom.Count -eq 0) "slapptes igenom: $($slapptIgenom -join ', ')"

# --- Handover URI per app ----------------------------------------------------
$apps = @(
    [pscustomobject]@{ Id = 'phonelink'; Namn = 'Telefonlank'; Uri = 'ms-phone:?PhoneNumber={0}' }
    [pscustomobject]@{ Id = 'whatsapp';  Namn = 'WhatsApp';    Uri = 'whatsapp://send?phone={0}' }
    [pscustomobject]@{ Id = 'teams';     Namn = 'Teams';       Uri = 'msteams:/l/call/0/0?users=4:{0}' }
    [pscustomobject]@{ Id = 'system';    Namn = 'tel:';        Uri = 'tel:{0}' }
)
Check 'telefonlank far E.164' ((Get-CallUri '070-123 45 67' $apps[0]) -eq 'ms-phone:?PhoneNumber=+46701234567')
Check 'whatsapp far siffror utan plus' ((Get-CallUri '070-123 45 67' $apps[1]) -eq 'whatsapp://send?phone=46701234567')
Check 'teams far E.164' ((Get-CallUri '0701234567' $apps[2]) -eq 'msteams:/l/call/0/0?users=4:+46701234567')
Check 'system far tel:' ((Get-CallUri '0701234567' $apps[3]) -eq 'tel:+46701234567')
Check 'skrap ger ingen uri' ($null -eq (Get-CallUri '070' $apps[0]))

# --- App choice survives a restart -------------------------------------------
function Get-CallApps { $apps }
Set-CallApp 'teams'
Check 'valet sparas och laddas' ((Get-CallApp).Id -eq 'teams') "fick $((Get-CallApp).Id)"

# --- The tab itself ----------------------------------------------------------
$script:taTillganglig = $true
$script:taBridge = $null
$script:taRoll = 'svarare'
function Get-TaValdUtgang { [pscustomobject]@{ Namn = 'CABLE Input (VB-Audio Virtual Cable)' } }
function Start-Telefonassistent($roll, $tyst) { $script:taBridge = [pscustomobject]@{ TurerKorda = 0 }; $true }
function Stop-Telefonassistent { $script:taBridge = $null }

$tab = New-Object System.Windows.Forms.TabPage
$tab.Size = New-Object System.Drawing.Size(836, 581)
Build-PhoneTab $tab
[System.Windows.Forms.Application]::DoEvents()

Check 'nummerfalt och ringknapp byggda' ($script:dashDialBox -and $script:dashDialBtn)
Check 'appvaljaren fylld'               ($script:dashDialApp.Items.Count -eq $apps.Count) "fick $($script:dashDialApp.Items.Count)"
Check 'sparat val forvalt'              ($script:dashDialApp.SelectedIndex -eq 2) "fick index $($script:dashDialApp.SelectedIndex)"
Check 'ring avstangd utan nummer'       (-not $script:dashDialBtn.Enabled)

$script:dashDialBox.Text = '070'
[System.Windows.Forms.Application]::DoEvents()
Check 'ring avstangd vid halvt nummer'  (-not $script:dashDialBtn.Enabled) "'$($script:dashDialHint.Text)'"

$script:dashDialBox.Text = '070-123 45 67'
[System.Windows.Forms.Application]::DoEvents()
Check 'ring pa vid giltigt nummer'      $script:dashDialBtn.Enabled
Check 'forhandsvisning visar E.164'     ($script:dashDialHint.Text -like '*+46701234567*') "'$($script:dashDialHint.Text)'"
Check 'forhandsvisning namner appen'    ($script:dashDialHint.Text -like '*Teams*') "'$($script:dashDialHint.Text)'"

# --- Assistant status --------------------------------------------------------
Update-PhoneTab
Check 'assistenten visas som av'   ($script:dashPhoneStatus.Text -eq 'Av')
Check 'utgangen visas i vila'      ($script:dashPhoneHint.Text -like '*CABLE Input*') "'$($script:dashPhoneHint.Text)'"
Check 'knappen erbjuder start'     ($script:dashPhoneBtn.Text -like '*Starta*') "'$($script:dashPhoneBtn.Text)'"

$script:dashPhoneBtn.PerformClick()
[System.Windows.Forms.Application]::DoEvents()
Check 'knappen startar assistenten' ($null -ne $script:taBridge)
Check 'aktiv status visas'          ($script:dashPhoneStatus.Text -like '*Aktiv*') "'$($script:dashPhoneStatus.Text)'"
Check 'prickan blir accentfargad'   ($script:dashPhoneDot.BackColor -eq $script:uiAccent)
$script:dashPhoneBtn.PerformClick()
[System.Windows.Forms.Application]::DoEvents()
Check 'knappen stoppar assistenten' ($null -eq $script:taBridge)

# --- Degrades when the phone half is missing ---------------------------------
$script:taTillganglig = $false
$tab2 = New-Object System.Windows.Forms.TabPage
$tab2.Size = New-Object System.Drawing.Size(836, 581)
$byggdeAnda = $true
try { Build-PhoneTab $tab2 } catch { $byggdeAnda = $false }
Check 'utan telefondel: kraschar inte' $byggdeAnda
Check 'utan telefondel: forklarar'     ($tab2.Controls.Count -eq 1)

Remove-Item $script:taAppCfg -ErrorAction SilentlyContinue
Complete-Test
