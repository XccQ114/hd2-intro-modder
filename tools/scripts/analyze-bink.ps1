# SPDX-License-Identifier: CC-BY-NC-4.0
# analyze-bink.ps1 - parse BINK2 (KB2*) video headers into a comparison row
# Usage: powershell -File analyze-bink.ps1 -Paths <file1> <file2> ...
param([Parameter(Mandatory=$true)][string[]]$Paths)

function Analyze-Bink([string]$Path) {
    $name = [System.IO.Path]::GetFileName($Path)
    # -LiteralPath matters here: brackets in a file name are wildcards to Test-Path, so a
    # perfectly good "[OP]video.bk2" used to be reported as MISSING (and the caller then
    # refused to read the flags of a file that was fine all along).
    if (-not (Test-Path -LiteralPath $Path)) { return $name + "`tMISSING" }
    # Only the first 0x50 bytes are ever inspected - never pull a multi-hundred-MB .bk2
    # into memory just to read its header.
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt 0x50) { return $name + "`tTOO-SMALL" }
    $b = New-Object byte[] 0x50
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { [void]$fs.Read($b, 0, 0x50) } finally { $fs.Dispose() }
    $u32 = { param($o) [BitConverter]::ToUInt32($b, $o) }
    $magic = [System.Text.Encoding]::ASCII.GetString($b, 0, 4)
    $f04 = & $u32 0x04; $f08 = & $u32 0x08; $f0C = & $u32 0x0C; $f10 = & $u32 0x10
    $f14 = & $u32 0x14; $f18 = & $u32 0x18; $f1C = & $u32 0x1C; $f20 = & $u32 0x20
    $f24 = & $u32 0x24; $f28 = & $u32 0x28; $f2C = & $u32 0x2C; $f30 = & $u32 0x30
    $f34 = & $u32 0x34; $f38 = & $u32 0x38; $f3C = & $u32 0x3C
    $f40 = if ($len -ge 0x48) { & $u32 0x40 } else { 0 }
    $f44 = if ($len -ge 0x4C) { & $u32 0x44 } else { 0 }
    $rate = $f34 -band 0xFFFF
    $fmtHi = ($f34 -shr 16) -band 0xFFFF
    $audioDesc = switch ($fmtHi) {
        0x7000 { "16bit-stereo" }; 0x6000 { "16bit-mono" }; 0x5000 { "8bit-mono" }
        0x4000 { "8bit-stereo" }; default { ("fmt-" + $fmtHi.ToString("X4")) }
    }
    $fps = $f1C
    $durSec = if ($fps -gt 0) { [math]::Round($f10 / $fps, 2) } else { 0 }
    return ("{0}`t{1}`tlen={2}`tavg={3}`tmax={4}`tfr={5}`t{6}x{7}`t{8}fps`t{9}s`ttr={10}`tfl=0x{11:X8}`t+28={12}`t2C=0x{13:X8}`t+30={14}`taud=0x{15:X8}({16}@{17}Hz)`t+38={18}`t+3C={19}`t+40={20}`t+44={21}" -f `
        $name, $magic, $f04, $f08, $f0C, $f10, $f14, $f18, $fps, $durSec, $f20, `
        $f24, $f28, $f2C, $f30, $f34, $audioDesc, $rate, $f38, $f3C, $f40, $f44)
}

Write-Output "name`tmagic`t+04len`tavg`tmax`tfr`tres`tfps`tdur`ttr`tflags`t+28`t0x2C`t+30`taud(type@rate)`t+38`t+3C`t+40`t+44"
foreach ($p in $Paths) { Write-Output (Analyze-Bink $p) }
