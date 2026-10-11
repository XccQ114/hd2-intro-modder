# SPDX-License-Identifier: CC-BY-NC-4.0
# encode.ps1 - radvideo64 encode wrapper (handles non-ASCII paths + waits for the GUI encoder to finish)
# Usage: powershell -ExecutionPolicy Bypass -File encode.ps1 -Video <source.mp4> [-Output <out.bk2>]
#   radvideo64.exe is a GUI app: '&' returns immediately, so we poll the output file
#   until it exists and its size stops changing, then kill the (still-open) GUI process.
param(
    [Parameter(Mandatory=$true)][string]$Video,
    [string]$Output = ""
)

$ErrorActionPreference = 'Stop'

# ---- locate package root (this file lives in <package>\tools\) ----
$root = Split-Path -Parent $PSScriptRoot

# ---- locate radvideo64.exe ----
$rv = Get-Command radvideo64 -ErrorAction SilentlyContinue
if (-not $rv) {
    foreach ($rp in @(
        (Join-Path $root 'radvideo64.exe'),
        (Join-Path $root 'RADVideo\radvideo64.exe'),
        'C:\Program Files\RAD Video Tools\radvideo64.exe',
        'C:\Program Files (x86)\RAD Video Tools\radvideo64.exe',
        'C:\Program Files\RADVideo\radvideo64.exe',
        'C:\Program Files (x86)\RADVideo\radvideo64.exe'
    )) {
        if (Test-Path -LiteralPath $rp) { $rv = $rp; break }
    }
}
if (-not $rv) {
    Write-Host "[ERROR] radvideo64.exe not found. Install RAD Video Tools, or drop radvideo64.exe into: $root" -ForegroundColor Red
    exit 1
}
$rvPath = if ($rv -is [System.Management.Automation.CommandInfo]) { $rv.Source } else { $rv.ToString() }

# ---- check input ----
if (-not (Test-Path -LiteralPath $Video)) {
    Write-Host ("[ERROR] input not found: " + $Video) -ForegroundColor Red
    exit 1
}
$inputFull = (Resolve-Path -LiteralPath $Video).Path

# ---- output path ----
if (-not $Output) {
    $Output = [System.IO.Path]::ChangeExtension($inputFull, '.bk2')
}
$outputFull = $Output
if (-not [System.IO.Path]::IsPathRooted($outputFull)) {
    $outputFull = Join-Path (Get-Location).Path $outputFull
}

# ---- ASCII check ----
function Test-Ascii([string]$s) {
    foreach ($ch in $s.ToCharArray()) { if ([int]$ch -gt 127) { return $false } }
    return $true
}

# ---- wait for the GUI encoder to finish ----
# radvideo64 (bink2c) writes the output as "<out>.tmp" FIRST, then renames it to the
# final "<out>" when compression completes (observed: 4K/120fps source wrote
# video.bk2.tmp at ~9 MB/min). So:
#   - .tmp exists and grows  -> encoding in progress, keep waiting (never kill yet)
#   - final file exists + ~6s stable -> done
# Timeout raised to 2h: large sources (4K/120fps) legitimately take 60-90 min.
function Wait-Bk2([string]$path, [int]$timeoutSec = 7200) {
    $tmpPath = $path + '.tmp'
    $elapsed = 0
    $lastSize = -1
    $stable = 0
    $lastTmpSize = -1
    $lastReport = -1
    while ($elapsed -lt $timeoutSec) {
        $exists = Test-Path -LiteralPath $path
        $size = if ($exists) { (Get-Item -LiteralPath $path).Length } else { 0 }
        $tmpExists = Test-Path -LiteralPath $tmpPath
        $tmpSize = if ($tmpExists) { (Get-Item -LiteralPath $tmpPath).Length } else { 0 }
        $procAlive = [bool](Get-Process -Name 'radvideo64' -ErrorAction SilentlyContinue)
        if ($exists -and $size -gt 0) {
            if ($size -eq $lastSize) {
                $stable++
                if ($stable -ge 3) { return $true }   # stable ~6s = done
            } else {
                $stable = 0
                $lastSize = $size
            }
        } else {
            $stable = 0
            $lastSize = -1
        }
        # progress hint: .tmp still growing = still encoding (report every 60s so
        # the user knows it is working, not hung)
        if ($tmpExists -and $tmpSize -gt 0 -and ($elapsed - $lastReport -ge 60)) {
            Write-Host ("  ... encoding in progress: temp {0:N1} MB, {1}s elapsed (large sources may take a while)" -f ($tmpSize / 1MB), $elapsed) -ForegroundColor DarkGray
            $lastReport = $elapsed
        }
        if (-not $procAlive -and $elapsed -gt 15) {
            if ($exists -and $size -gt 0) { return $true }
            return $false
        }
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    return (Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -gt 0)
}

$needInputCopy = -not (Test-Ascii $inputFull)
$needOutputCopy = -not (Test-Ascii $outputFull)
$needTranscode = $needInputCopy -or $needOutputCopy

# ---- clean stale .tmp from a previous interrupted run (bink2c writes <out>.tmp first) ----
if (Test-Path -LiteralPath ($outputFull + '.tmp')) {
    Write-Host "[INFO] removing stale temp file from a previous interrupted run: $outputFull.tmp" -ForegroundColor Yellow
    Remove-Item -LiteralPath ($outputFull + '.tmp') -Force
}

# ---- encode ----
$ok = $false
if (-not $needTranscode) {
    Write-Host "[OK] ASCII paths, encoding directly."
    Write-Host ("     in:  " + $inputFull)
    Write-Host ("     out: " + $outputFull)
    Write-Host "  calling radvideo64.exe (GUI window pops up; it compresses on its own)..."
    & $rvPath bink2c $inputFull $outputFull /V6344
    $ok = Wait-Bk2 $outputFull
} else {
    Write-Host "[INFO] non-ASCII path detected, copying to ASCII temp dir first."
    $tmpDir = Join-Path $env:TEMP 'hd2_encode_tmp'
    if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $tmpIn  = Join-Path $tmpDir ("in_"  + $stamp + [System.IO.Path]::GetExtension($inputFull))
    $tmpOut = Join-Path $tmpDir ("out_" + $stamp + '.bk2')
    Copy-Item -LiteralPath $inputFull -Destination $tmpIn -Force
    Write-Host ("     tmp in:  " + $tmpIn)
    Write-Host ("     tmp out: " + $tmpOut)
    Write-Host "  calling radvideo64.exe (GUI window pops up; it compresses on its own)..."
    & $rvPath bink2c $tmpIn $tmpOut /V6344
    $ok = Wait-Bk2 $tmpOut
    if ($ok) {
        $outDir = Split-Path $outputFull -Parent
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        Copy-Item -LiteralPath $tmpOut -Destination $outputFull -Force
        Write-Host ("[OK] encoded, copied back: " + $outputFull)
    } else {
        Write-Host "[ERROR] encode failed (no output file produced)." -ForegroundColor Red
    }
    Remove-Item -LiteralPath $tmpIn -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
}

# ---- close the GUI encoder (it does not exit on its own) ----
Get-Process -Name 'radvideo64' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# ---- result ----
if ($ok -and (Test-Path -LiteralPath $outputFull) -and ((Get-Item -LiteralPath $outputFull).Length -gt 0)) {
    Write-Host "===== encode done =====" -ForegroundColor Green
    Write-Host ("output: " + $outputFull + "  (" + (Get-Item -LiteralPath $outputFull).Length + " bytes)")
} else {
    Write-Host "[ERROR] encode failed." -ForegroundColor Red
    exit 1
}
