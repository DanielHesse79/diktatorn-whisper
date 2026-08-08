# Talanalys tab: the trend CSV must parse into the table (rows over the 70%
# crocodile line marked red), the owner-drawn chart must paint without throwing,
# and a missing CSV must yield an empty view rather than an error.
. (Join-Path $PSScriptRoot '_TestLib.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Import-AppFunction 'Diktatorn.ps1' @('Build-TrendTab', 'Refresh-TrendView')

$trendCsv = Join-Path $env:TEMP 'dikt_test_trend.csv'
@(
    'datum;minuter;talandel_pct;utfyllnad_per_min;fragor;langsta_monolog_min'
    '2026-08-01 09:00;32;45;2.1;7;1.5'
    '2026-08-02 10:00;28;58;3.0;4;2.0'
    '2026-08-03 11:00;40;72;4.2;2;3.5'
    '2026-08-04 14:00;25;38;1.8;9;1.0'
) | Set-Content $trendCsv -Encoding UTF8

$tab = New-Object System.Windows.Forms.TabPage
$tab.Size = New-Object System.Drawing.Size(740, 540)
Build-TrendTab $tab
Refresh-TrendView

Check '4 rader parsas' ($script:dashTrendList.Items.Count -eq 4) "fick $($script:dashTrendList.Items.Count)"
$red = @($script:dashTrendList.Items | Where-Object { $_.ForeColor.R -gt 150 -and $_.ForeColor.G -lt 120 })
Check 'raden over 70% rodmarkeras' ($red.Count -eq 1) "fick $($red.Count)"

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

Remove-Item $trendCsv -ErrorAction SilentlyContinue
Refresh-TrendView
Check 'saknad CSV ger tom vy' ($script:dashTrendList.Items.Count -eq 0)
Complete-Test
