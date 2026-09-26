<#
.SYNOPSIS
    Builds assets\reporaccoon.ico (and reporaccoon-256.png) from assets\reporaccoon.svg.

.DESCRIPTION
    No extra installs: Microsoft Edge (headless) renders the SVG at each icon size
    on a transparent page, System.Drawing crops the sizes out, and the .ico is
    written by hand with PNG-compressed entries (supported since Windows Vista).
    Run again after editing the SVG.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$svg = Join-Path $PSScriptRoot 'reporaccoon.svg'
$ico = Join-Path $PSScriptRoot 'reporaccoon.ico'
$png256 = Join-Path $PSScriptRoot 'reporaccoon-256.png'
$sizes = @(256, 128, 64, 48, 32, 24, 16)

$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
          "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found.' }

# Lay every size out in one row, 8px apart, so one screenshot renders them all natively.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "reporaccoon-icon-$([guid]::NewGuid().ToString('N'))"
[void][System.IO.Directory]::CreateDirectory($tmp)
$x = 0
$slots = @()
$imgs = foreach ($s in $sizes) {
    $slots += [pscustomobject]@{ Size = $s; X = $x }
    "<img src=""$([uri]$svg)"" style=""position:absolute;left:${x}px;top:0;width:${s}px;height:${s}px"">"
    $x += $s + 8
}
$html = Join-Path $tmp 'render.html'
[System.IO.File]::WriteAllText($html, "<!DOCTYPE html><html><body style=""margin:0;background:transparent"">$($imgs -join '')</body></html>")
$shot = Join-Path $tmp 'render.png'

# Edge prints progress to stderr; PowerShell 5.1 would treat that as an error under 'Stop'.
$ErrorActionPreference = 'Continue'
& $edge --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 `
    --default-background-color=00000000 --allow-file-access-from-files `
    --window-size="$x,256" --screenshot="$shot" ([uri]$html).AbsoluteUri 2>$null | Out-Null
$ErrorActionPreference = 'Stop'
for ($i = 0; $i -lt 50 -and -not (Test-Path $shot); $i++) { Start-Sleep -Milliseconds 200 }
if (-not (Test-Path $shot)) { throw 'Edge did not produce a screenshot.' }

$sheet = [System.Drawing.Bitmap]::FromFile($shot)
$pngs = @()
try {
    foreach ($slot in $slots) {
        $bmp = New-Object System.Drawing.Bitmap $slot.Size, $slot.Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.DrawImage($sheet, (New-Object System.Drawing.Rectangle 0, 0, $slot.Size, $slot.Size),
            (New-Object System.Drawing.Rectangle $slot.X, 0, $slot.Size, $slot.Size), [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        if ($slot.Size -eq 256) { $bmp.Save($png256, [System.Drawing.Imaging.ImageFormat]::Png) }
        $bmp.Dispose()
        $pngs += , $ms.ToArray()
    }
} finally {
    $sheet.Dispose()
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

# ICO: 6-byte header, 16-byte directory entry per image, then the PNG data.
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $dim = [byte]$(if ($s -ge 256) { 0 } else { $s })  # 0 means 256
    $w.Write($dim); $w.Write($dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $w.Write($p) }
$w.Flush()
[System.IO.File]::WriteAllBytes($ico, $out.ToArray())
$w.Dispose()

Write-Host "Wrote $ico ($($sizes -join ', ') px) and $png256"
