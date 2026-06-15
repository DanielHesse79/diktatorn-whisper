# Generates Diktatorn.ico (+ a Diktatorn.png preview): a cartoon "generalissimo" —
# military peaked cap, sunglasses, and a grand moustache. Clearly fictional, on-theme.
param([string]$Root = $PSScriptRoot)
Add-Type -AssemblyName System.Drawing

function New-Brush([int]$r, [int]$g, [int]$b) {
    New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($r, $g, $b))
}

function Draw-Icon([int]$S) {
    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    function Oval($brush, $x, $y, $w, $h) { $g.FillEllipse($brush, [single]($x*$S), [single]($y*$S), [single]($w*$S), [single]($h*$S)) }
    function Box($brush, $x, $y, $w, $h) { $g.FillRectangle($brush, [single]($x*$S), [single]($y*$S), [single]($w*$S), [single]($h*$S)) }

    $gold  = New-Brush 212 175 55
    $green = New-Brush 60 79 46
    $dark  = New-Brush 33 41 28
    $black = New-Brush 20 20 22
    $skin  = New-Brush 226 178 130
    $shadow= New-Brush 198 150 104

    # Badge background
    Oval $gold  0.02 0.02 0.96 0.96
    Oval $green 0.06 0.06 0.88 0.88

    # Face
    Oval $skin 0.28 0.36 0.44 0.50
    Oval $shadow 0.40 0.78 0.20 0.08   # chin/jaw hint

    # Cap: crown, band, visor, star
    Oval $dark  0.20 0.12 0.60 0.26
    Box  $dark  0.22 0.30 0.56 0.085
    Oval $black 0.24 0.37 0.52 0.10    # visor
    # gold star on the band
    $cx = 0.5*$S; $cy = 0.345*$S; $ro = 0.062*$S; $ri = 0.026*$S
    $pts = New-Object 'System.Drawing.PointF[]' 10
    for ($i = 0; $i -lt 10; $i++) {
        $ang = (-90 + $i*36) * [Math]::PI / 180
        $rad = if ($i % 2 -eq 0) { $ro } else { $ri }
        $pts[$i] = New-Object System.Drawing.PointF([single]($cx + $rad*[Math]::Cos($ang)), [single]($cy + $rad*[Math]::Sin($ang)))
    }
    $g.FillPolygon($gold, $pts)

    # Sunglasses
    Oval $black 0.31 0.50 0.16 0.12
    Oval $black 0.53 0.50 0.16 0.12
    Box  $black 0.46 0.535 0.08 0.025

    # Grand moustache (two sweeping ellipses)
    Oval $black 0.30 0.66 0.22 0.11
    Oval $black 0.48 0.66 0.22 0.11
    Oval $skin  0.46 0.70 0.08 0.05    # notch in the middle

    $g.Dispose()
    return $bmp
}

# Multi-size .ico (PNG-compressed entries; Windows Vista+)
function Save-Ico([int[]]$sizes, [string]$path) {
    $pngs = @()
    foreach ($s in $sizes) {
        $bmp = Draw-Icon $s
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngs += , ($ms.ToArray()); $ms.Dispose(); $bmp.Dispose()
    }
    $fs = [System.IO.File]::Create($path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]; $len = $pngs[$i].Length
        $dim = if ($s -ge 256) { 0 } else { $s }
        $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
        $offset += $len
    }
    foreach ($p in $pngs) { $bw.Write($p) }
    $bw.Flush(); $fs.Close()
}

Save-Ico @(256, 48, 32, 16) (Join-Path $Root 'Diktatorn.ico')
$prev = Draw-Icon 256
$prev.Save((Join-Path $Root 'Diktatorn.png'), [System.Drawing.Imaging.ImageFormat]::Png); $prev.Dispose()
Write-Host "Skapade Diktatorn.ico + Diktatorn.png"
