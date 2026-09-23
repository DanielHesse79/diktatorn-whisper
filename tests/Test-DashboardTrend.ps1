# Talanalys tab: the trend CSV must parse into the table (rows over the 70%
# crocodile line marked red), the owner-drawn chart must paint without throwing,
# and a missing CSV must yield an empty view rather than an error. Calls under
# $trendMinMinutes never count: not in the table, the averages or the file.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppUi
Import-AppVariable 'Diktatorn.ps1' 'trendHeader'
Import-AppVariable 'Diktatorn.ps1' 'trendMinMinutes'
Import-AppFunction 'Diktatorn.ps1' @('Build-TrendTab', 'Refresh-TrendView', 'Get-TrendRows', 'Get-TrendPrev', 'Add-TrendRow')
function Write-Log($m) {}

# The 1- and 0-minute rows are short calls logged before the limit existed. At 95% talk
# share they would paint a red bar and drag every average.
$trendCsv = Join-Path $env:TEMP 'dikt_test_trend.csv'
@(
    'datum;minuter;talandel_pct;utfyllnad_per_min;fragor;langsta_monolog_min'
    '2026-08-01 09:00;32;45;2.1;7;1.5'
    '2026-08-01 12:00;1;95;9.0;0;0.5'
    '2026-08-02 10:00;28;58;3.0;4;2.0'
    '2026-08-03 11:00;40;72;4.2;2;3.5'
    '2026-08-03 15:00;0;90;0.0;0;0.0'
    '2026-08-04 14:00;25;38;1.8;9;1.0'
) | Set-Content $trendCsv -Encoding UTF8

$tab = New-Object System.Windows.Forms.TabPage
$tab.Size = New-Object System.Drawing.Size(740, 540)
Build-TrendTab $tab
Refresh-TrendView

Check '4 rader visas, korta samtal utelamnas' ($script:dashTrendList.Items.Count -eq 4) "fick $($script:dashTrendList.Items.Count)"
$red = @($script:dashTrendList.Items | Where-Object { $_.ForeColor.R -gt 150 -and $_.ForeColor.G -lt 120 })
Check 'raden over 70% rodmarkeras' ($red.Count -eq 1) "fick $($red.Count)"
$p = Get-TrendPrev
Check 'snittet raknar bara samtal >= 2 min' ($p.n -eq 4 -and $p.share -eq 53 -and $p.fill -eq 2.8) "n=$($p.n) talandel=$($p.share) utfyllnad=$($p.fill)"

$painted = 0; $paintOk = $true
try {
    $bmp = New-Object System.Drawing.Bitmap($script:dashTrendChart.Width, $script:dashTrendChart.Height)
    $script:dashTrendChart.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height)))
    for ($x = 0; $x -lt $bmp.Width; $x += 5) {
        for ($y = 0; $y -lt $bmp.Height; $y += 5) {
            $px = $bmp.GetPixel($x, $y)
            if ($px.R -lt 250 -or $px.G -lt 250 -or $px.B -lt 250) { $painted++ }
        }
    }
    $bmp.Dispose()
} catch { $paintOk = $false }
Check 'grafen ritas utan fel'   $paintOk
Check 'grafen innehaller staplar' ($painted -gt 20) "$painted pixlar"

# Write side: a 1.9-minute call never reaches the file, a 2.6-minute one does (rounded).
$before = @(Get-Content $trendCsv).Count
Add-TrendRow 1.9 80 5.0 1 0.5
Check '1,9 min skrivs inte' (@(Get-Content $trendCsv).Count -eq $before)
Add-TrendRow 2.6 40 2.0 3 0.5
$last = @(Get-Content $trendCsv)[-1]
Check '2,6 min skrivs som 3 min' ((@(Get-Content $trendCsv).Count -eq ($before + 1)) -and (($last -split ';')[1] -eq '3')) "sista raden: $last"

Remove-Item $trendCsv -ErrorAction SilentlyContinue
Refresh-TrendView
Check 'saknad CSV ger tom vy' ($script:dashTrendList.Items.Count -eq 0)
Add-TrendRow 5 40 2.0 3 0.5
Check 'ny fil far rubrikrad' ((@(Get-Content $trendCsv -Encoding UTF8)[0]) -eq $trendHeader) "fick '$(@(Get-Content $trendCsv -Encoding UTF8)[0])'"
Remove-Item $trendCsv -ErrorAction SilentlyContinue
Complete-Test
