# Builds Diktatorn.ico (+ PNG previews) from the master artwork Diktatorn-source.png:
# auto-crops the white margin, rounds the corners to transparent, and writes a
# multi-size icon. Re-run whenever Diktatorn-source.png changes.
param([string]$Root = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = Join-Path $Root 'Diktatorn-source.png'
if (-not (Test-Path $src)) { Write-Host "Saknar $src"; exit 1 }
$orig = [System.Drawing.Bitmap]::FromFile($src)

# --- Find the icon's bounding box on a downscaled copy (fast, via LockBits) ---
$tw = 512; $th = [int]($orig.Height * $tw / $orig.Width)
$thumb = New-Object System.Drawing.Bitmap($tw, $th)
$tg = [System.Drawing.Graphics]::FromImage($thumb); $tg.InterpolationMode = 'HighQualityBicubic'
$tg.DrawImage($orig, 0, 0, $tw, $th); $tg.Dispose()
$rect = New-Object System.Drawing.Rectangle 0, 0, $tw, $th
$data = $thumb.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride; $buf = New-Object byte[] ($stride * $th)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $buf.Length)
$thumb.UnlockBits($data); $thumb.Dispose()
$minX = $tw; $minY = $th; $maxX = 0; $maxY = 0
for ($y = 0; $y -lt $th; $y++) {
    $row = $y * $stride
    for ($x = 0; $x -lt $tw; $x++) {
        $i = $row + $x * 4
        $mn = [Math]::Min($buf[$i], [Math]::Min($buf[$i + 1], $buf[$i + 2]))   # B,G,R: dark = content
        if ($mn -lt 200) {
            if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
        }
    }
}
$sc = $orig.Width / $tw
$bx = [int]($minX * $sc); $by = [int]($minY * $sc)
$bw = [int](($maxX - $minX + 1) * $sc); $bh = [int](($maxY - $minY + 1) * $sc)

# --- Centered square crop, clamped to the image ---
$side = [Math]::Max($bw, $bh)
$sx = [int]([Math]::Max(0, ($bx + $bw / 2) - $side / 2)); $sy = [int]([Math]::Max(0, ($by + $bh / 2) - $side / 2))
if ($sx + $side -gt $orig.Width) { $side = $orig.Width - $sx }
if ($sy + $side -gt $orig.Height) { $side = $orig.Height - $sy }
$crop = New-Object System.Drawing.Bitmap($side, $side)
$cg = [System.Drawing.Graphics]::FromImage($crop)
$cg.DrawImage($orig, (New-Object System.Drawing.Rectangle 0, 0, $side, $side), (New-Object System.Drawing.Rectangle $sx, $sy, $side, $side), [System.Drawing.GraphicsUnit]::Pixel)
$cg.Dispose(); $orig.Dispose()

function Render([int]$s) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'
    $g.Clear([System.Drawing.Color]::Transparent)
    $r = [single](0.17 * $s); $d = 2 * $r
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($s - $d, 0, $d, $d, 270, 90)
    $path.AddArc($s - $d, $s - $d, $d, $d, 0, 90); $path.AddArc(0, $s - $d, $d, $d, 90, 90); $path.CloseFigure()
    $g.SetClip($path)
    $g.DrawImage($crop, 0, 0, $s, $s)   # clip rounds the corners -> transparent
    $g.Dispose(); $path.Dispose()
    return $bmp
}

# --- Multi-size .ico (PNG-compressed entries; Windows Vista+) ---
$sizes = @(256, 48, 32, 16); $pngs = @()
foreach ($s in $sizes) {
    $bmp = Render $s
    $ms = New-Object System.IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngs += , ($ms.ToArray()); $ms.Dispose(); $bmp.Dispose()
}
$icoPath = Join-Path $Root 'Diktatorn.ico'
$fs = [System.IO.File]::Create($icoPath); $bw2 = New-Object System.IO.BinaryWriter($fs)
$bw2.Write([uint16]0); $bw2.Write([uint16]1); $bw2.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length; $dim = if ($s -ge 256) { 0 } else { $s }
    $bw2.Write([byte]$dim); $bw2.Write([byte]$dim); $bw2.Write([byte]0); $bw2.Write([byte]0)
    $bw2.Write([uint16]1); $bw2.Write([uint16]32); $bw2.Write([uint32]$len); $bw2.Write([uint32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $bw2.Write($p) }
$bw2.Flush(); $fs.Close()

# --- PNG previews (256 tracked-preview; 512/1024 for social/README) ---
foreach ($s in 256, 512, 1024) {
    $bmp = Render $s
    $name = if ($s -eq 256) { 'Diktatorn.png' } else { "Diktatorn-$s.png" }
    $bmp.Save((Join-Path $Root $name), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
$crop.Dispose()
Write-Host "Skapade Diktatorn.ico + Diktatorn.png (256/512/1024) fran Diktatorn-source.png"
