# build-gui.ps1 - compile the hd2-intro-modder GUI into a single EXE.
#
# No SDK, no NuGet, no internet: it uses the C# compiler that ships with the
# .NET Framework that every Windows 10/11 machine already has.
#
# Usage:  powershell -ExecutionPolicy Bypass -File gui\build-gui.ps1
# Output: <project root>\hd2-intro-modder.exe

$ErrorActionPreference = 'Stop'

$guiDir = $PSScriptRoot
$root   = Split-Path -Parent $guiDir
$src    = Join-Path $guiDir 'Hd2IntroModderGui.cs'
$out    = Join-Path $root  'hd2-intro-modder.exe'

Write-Host "=== building hd2-intro-modder GUI ===" -ForegroundColor Cyan
Write-Host "  source: $src"
Write-Host "  output: $out"

if (-not (Test-Path -LiteralPath $src)) {
    Write-Host "[ERROR] source not found: $src" -ForegroundColor Red
    exit 1
}

# ---- locate csc.exe (the one bundled with .NET Framework 4.x) ----
$csc = $null
foreach ($p in @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
)) {
    if (Test-Path -LiteralPath $p) { $csc = $p; break }
}
if (-not $csc) {
    Write-Host "[ERROR] csc.exe not found. .NET Framework 4.x is required (it ships with Windows)." -ForegroundColor Red
    exit 1
}
Write-Host "  compiler: $csc"

# /codepage:65001 keeps the Chinese UI strings intact even if the source file
# loses its BOM somewhere along the way (csc would otherwise assume the ANSI code page).
$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    '/codepage:65001',
    ('/out:' + $out),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    $src
)

& $csc $cscArgs
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Host "[FAIL] compile failed (csc exit $code)" -ForegroundColor Red
    exit $code
}
if (-not (Test-Path -LiteralPath $out)) {
    Write-Host "[FAIL] csc reported success but produced no EXE" -ForegroundColor Red
    exit 1
}

$exe = Get-Item -LiteralPath $out
Write-Host ("[OK] built {0}  ({1:N0} bytes)" -f $exe.Name, $exe.Length) -ForegroundColor Green
Write-Host "     double-click it, or run: $out"
exit 0
