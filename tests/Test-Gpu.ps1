# Switching graphics card. Getting this wrong is expensive rather than merely
# annoying: local transcription measured 0.3x realtime on the integrated Radeon
# against 10.9x on the discrete RTX beside it, so the discrete-card preference and
# the integrated-card warning both have to keep working.
#
# Set-Gpu is the only implementation. The tray menu used to carry a line-for-line
# copy of it, which is exactly how two code paths drift - the last check here
# guards against the duplicate coming back.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# The real SvText, not a stub - the balloon text is the thing being asserted, and
# a pass-through stub would have let a raw '~a' token through unnoticed.
Import-AppUi
Import-AppFunction 'Diktatorn.ps1' @('Set-Gpu', 'Test-DiscreteAdapter', 'Resolve-Adapter')

$discrete   = 'NVIDIA GeForce RTX 5070 Ti'
$integrated = 'AMD Radeon(TM) Graphics'

# --- Discrete vs integrated --------------------------------------------------
$diskreta = @($discrete, 'AMD Radeon RX 7900 XTX', 'Intel(R) Arc A770', 'NVIDIA Quadro P2000')
$fel = @($diskreta | Where-Object { -not (Test-DiscreteAdapter $_) })
Check 'diskreta kort kanns igen' ($fel.Count -eq 0) "missade: $($fel -join ', ')"
$integrerade = @($integrated, 'Intel(R) UHD Graphics', 'Intel(R) Iris(R) Xe Graphics')
$fel2 = @($integrerade | Where-Object { Test-DiscreteAdapter $_ })
Check 'integrerade kort flaggas inte som diskreta' ($fel2.Count -eq 0) "trodde diskret: $($fel2 -join ', ')"

# --- Resolve-Adapter: prefer discrete, let the config override ----------------
$gpuCfg = Join-Path $env:TEMP 'dikt_test_gpu.txt'
Remove-Item $gpuCfg -ErrorAction SilentlyContinue
# Integrated listed FIRST - the enumeration order that caused the 34x slowdown.
$script:adapters = @($integrated, $discrete)
Check 'utan config valjs det diskreta' ((Resolve-Adapter) -eq $discrete) "fick $(Resolve-Adapter)"
[System.IO.File]::WriteAllText($gpuCfg, $integrated)
Check 'sparat val vinner over automatiken' ((Resolve-Adapter) -eq $integrated) "fick $(Resolve-Adapter)"
[System.IO.File]::WriteAllText($gpuCfg, 'Kort som inte finns langre')
Check 'borttaget kort faller tillbaka pa diskret' ((Resolve-Adapter) -eq $discrete) "fick $(Resolve-Adapter)"
Remove-Item $gpuCfg -ErrorAction SilentlyContinue

# --- Set-Gpu -----------------------------------------------------------------
$script:reloads = @(); $script:ballonger = @(); $script:statusar = @(); $script:loggar = @()
function Reload-Model($m) { $script:reloads += $m }
function Set-Status($t, $i) { $script:statusar += $t }
function Write-Log($m) { $script:loggar += $m }
$icoWork = $null; $icoIdle = $null
$script:modelFile = 'ggml-medium.bin'
$tray = [pscustomobject]@{}
$tray | Add-Member -MemberType ScriptMethod -Name ShowBalloonTip -Value {
    param($ms, $rubrik, $text, $ikon)
    $script:ballonger += [pscustomobject]@{ text = $text; ikon = [string]$ikon }
}
# Menu items the switch has to keep in sync - a stand-in for the tray dropdown.
$script:gpuMenuItems = @()
foreach ($a in @($integrated, $discrete)) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $a
    $mi.Tag = $a; $mi.Checked = ($a -eq $integrated)
    $script:gpuMenuItems += $mi
}
$script:adapter = $integrated

Set-Gpu $discrete
Check 'valet skrivs till config'    ((Test-Path $gpuCfg) -and ((Get-Content $gpuCfg -Raw).Trim() -eq $discrete))
Check 'aktivt kort uppdateras'      ($script:adapter -eq $discrete)
Check 'modellen laddas om'          ($script:reloads.Count -eq 1 -and $script:reloads[0] -eq 'ggml-medium.bin')
Check 'menyns bock foljer med'      ((@($script:gpuMenuItems | Where-Object { $_.Checked }).Count -eq 1) -and
                                     (@($script:gpuMenuItems | Where-Object { $_.Checked })[0].Tag -eq $discrete))
Check 'status atergar till redo'    ($script:statusar[-1] -eq 'redo')
Check 'diskret kort ger info'       ($script:ballonger[-1].ikon -eq 'Info') "fick $($script:ballonger[-1].ikon)"

Set-Gpu $integrated
Check 'integrerat kort varnar'      ($script:ballonger[-1].ikon -eq 'Warning') "fick $($script:ballonger[-1].ikon)"
Check 'varningen sager varfor'      ($script:ballonger[-1].text -like (SvText '*l~angsam*')) "'$($script:ballonger[-1].text)'"
Check 'inga oversatta tecken lacker' ($script:ballonger[-1].text -notmatch '~[aeoAEO]') "'$($script:ballonger[-1].text)'"

# A failing reload must not leave the tray stuck on "byter grafikkort..."
$fore = $script:statusar.Count
function Reload-Model($m) { throw 'DirectX-adaptern svarar inte' }
Set-Gpu $discrete
Check 'krasch i omladdning fangas'  ($script:ballonger[-1].ikon -eq 'Error') "fick $($script:ballonger[-1].ikon)"
Check 'krasch loggas'               ($script:loggar[-1] -like '*GPU-byte misslyckades*') "'$($script:loggar[-1])'"
Check 'status slapps aven vid fel'  ($script:statusar[-1] -eq 'redo')

$fore2 = $script:statusar.Count
Set-Gpu ''
Check 'tomt val gor ingenting'      ($script:statusar.Count -eq $fore2)

# --- No second implementation ------------------------------------------------
# The tray menu's click handler must delegate, not re-implement. Writing the
# config file straight from the handler is the tell.
$src = Get-Content (Join-Path $script:RepoRoot 'Diktatorn.ps1') -Raw
$gpuBlock = [regex]::Match($src, "(?s)ToolStripMenuItem 'Grafikkort.*?\[void\]\`$menu\.Items\.Add\(\`$miGpu\)")
Check 'tray-menyns gpu-block hittas' $gpuBlock.Success
Check 'tray-menyn anropar Set-Gpu'   ($gpuBlock.Value -like '*Set-Gpu*')
Check 'tray-menyn skriver inte configen sjalv' ($gpuBlock.Value -notlike '*WriteAllText($gpuCfg*')

Remove-Item $gpuCfg -ErrorAction SilentlyContinue
Complete-Test
