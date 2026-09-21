# Inspelningsbrickan far ALDRIG ta fokus. Dikterad text skickas med SendInput till
# det fonster som har fokus - ett fonster som aktiveras nar det visas skulle fanga
# dikteringen i sig sjalvt i stallet for att lata den ga till Word. Invarianten
# syns inte i koden (den bor i tva ex-style-bitar och en overriden property), sa
# utan det har testet forsvinner den tyst vid forsta refaktorering.
#
# Testar ocksa att en sparad position utanfor skarmen faller tillbaka: annars
# ritas brickan i det osynliga och gar inte att dra tillbaka.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppUi
Import-AppFunction 'Diktatorn.ps1' @('New-RoundedPath', 'Get-OverlayPos', 'Update-RecOverlayText')

# RecOverlayForm bor i ett Add-Type-block, inte i en funktion, sa Import-AppFunction
# nar den inte. Hamta blocket som text och kompilera exakt samma kallkod som appen.
$src = Get-Content (Join-Path $script:RepoRoot 'Diktatorn.ps1') -Raw
$m = [regex]::Match($src, '(?s)Add-Type -ReferencedAssemblies System\.Windows\.Forms -TypeDefinition @"(.+?)"@')
if (-not $m.Success) { Skip-Test 'hittar inte RecOverlayForm-blocket i Diktatorn.ps1' }
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition $m.Groups[1].Value

# --- Fokusinvarianten ---
$f = New-Object RecOverlayForm
$bf = [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance

$swa = [RecOverlayForm].GetProperty('ShowWithoutActivation', $bf).GetValue($f)
Check 'ShowWithoutActivation = true (Show aktiverar inte fonstret)' ([bool]$swa)

$cp = [RecOverlayForm].GetProperty('CreateParams', $bf).GetValue($f)
Check 'WS_EX_NOACTIVATE satt (stjal inte fokus fran dikteringsmalet)' (($cp.ExStyle -band 0x08000000) -ne 0)
Check 'WS_EX_TOOLWINDOW satt (ligger inte i Alt-Tab)'                 (($cp.ExStyle -band 0x00000080) -ne 0)
$f.Dispose()

# --- Sparad position ---
# Funktionerna importeras till global scope, sa deras $overlayCfg maste sattas dar.
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$hornX = $wa.Right - 200
$hornY = $wa.Bottom - 64
$global:overlayCfg = Join-Path $env:TEMP 'dikt_test_overlay.txt'

[System.IO.File]::WriteAllText($global:overlayCfg, '-9000,-9000')
$p = Get-OverlayPos
Check 'position utanfor alla skarmar -> fallback till hornet' (($p.X -eq $hornX) -and ($p.Y -eq $hornY)) "$($p.X),$($p.Y)"

[System.IO.File]::WriteAllText($global:overlayCfg, "$($wa.Left + 50),$($wa.Top + 50)")
$p2 = Get-OverlayPos
Check 'sparad position pa skarmen behalls' (($p2.X -eq ($wa.Left + 50)) -and ($p2.Y -eq ($wa.Top + 50))) "$($p2.X),$($p2.Y)"

[System.IO.File]::WriteAllText($global:overlayCfg, 'trasigt')
$p3 = Get-OverlayPos
Check 'trasig configfil -> hornet, inget undantag' (($p3.X -eq $hornX) -and ($p3.Y -eq $hornY)) "$($p3.X),$($p3.Y)"

Remove-Item $global:overlayCfg -ErrorAction SilentlyContinue
$p4 = Get-OverlayPos
Check 'ingen sparad fil -> hornet' (($p4.X -eq $hornX) -and ($p4.Y -eq $hornY)) "$($p4.X),$($p4.Y)"

# --- Etikett och tidsformat ---
# Sekunden kan ticka mellan sattning och avlasning, darav \d pa sista siffran.
$global:recMode  = 'mote'
$global:recStart = (Get-Date).AddSeconds(-125)
Update-RecOverlayText
Check 'mote: svensk etikett + m:ss' ($global:recText -match ('^' + [regex]::Escape((SvText 'M~OTE')) + '\s+2:0\d$')) $global:recText

$global:recMode  = 'journal'
$global:recStart = (Get-Date).AddSeconds(-7)
Update-RecOverlayText
Check 'journal: nollpaddade sekunder' ($global:recText -match '^JOURNAL\s+0:0\d$') $global:recText

$global:recMode  = 'diktering'
$global:recStart = (Get-Date).AddSeconds(-3600)
Update-RecOverlayText
Check 'diktering: minuter rullar over 59' ($global:recText -match '^DIKTERAR\s+(59|60):\d\d$') $global:recText

# --- Formen ---
$path = New-RoundedPath 186 38 9
Check 'rundad path byggs' ($path.PointCount -gt 0)
$b = $path.GetBounds()
Check 'path tacker brickans yta' (([int]$b.Width -ge 180) -and ([int]$b.Height -ge 32)) "$([int]$b.Width)x$([int]$b.Height)"
$path.Dispose()

Complete-Test
