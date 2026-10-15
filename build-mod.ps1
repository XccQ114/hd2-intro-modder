# build-mod.ps1 - HD2 intro replacement mod generator (v1.2.0)
# Usage:
#   powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video video.mp4
#   powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video video.mp4 -Num 1 -Zip
#   powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video video.mp4 -Wem audio.wem
# Options:
#   -Video  source MP4 (required)
#   -Num    patch number, default 0 (must be 0..N with no gaps if other mods installed)
#   -Wem    ready-made .wem audio (skip Wwise)
#   -Out    output dir (default: output\<video-name>\)
#   -Zip    zip the result
#   -Wwise  path to WwiseConsole.exe (or its folder)
#   -Wproj  path to a Wwise Audio Conversion project (.wproj)
#   -GameDir path to the Helldivers 2 install (its bink2w64.dll is needed for audio
#            extraction and the decode check; auto-detected from Steam/registry otherwise)

param(
    [Parameter(Position=0)][string]$Video,
    [int]$Num = 0,
    [string]$Wem = "",
    [string]$Out = "",
    [switch]$Zip,
    [string]$Wwise = "",
    [string]$Wproj = "",
    [string]$GameDir = ""
)

function Stop-Script([int]$code = 0) {
    # drop the staged bink tools + commercial DLL so nothing is left in %TEMP%
    try {
        $wd = Join-Path $env:TEMP 'hd2_bink_work'
        if (Test-Path -LiteralPath $wd) { Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    Write-Host ""
    Read-Host "Press Enter to close this window"
    exit $code
}

if (-not $Video) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "MP4 files (*.mp4)|*.mp4|All files (*.*)|*.*"
        $ofd.Title = "Select the MP4 to turn into an HD2 intro mod"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $Video = $ofd.FileName
        } else {
            Write-Host "No file selected. Exiting." -ForegroundColor Red
            Stop-Script 1
        }
    } catch {
        Write-Host "Usage: build-mod.ps1 <video.mp4> [-Num 0] [-Wem audio.wem] [-Zip]" -ForegroundColor Cyan
        Write-Host "  or run without arguments to pick a file." -ForegroundColor Cyan
        Stop-Script 1
    }
}

$ErrorActionPreference = 'Stop'

# ---- logging + global error trap (never close silently; always write a log) ----
# each run writes a timestamped log into log\; keep the latest 20, delete older ones
$LogDir = Join-Path $PSScriptRoot 'log'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = Join-Path $LogDir ("build-mod-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + ".log")
$oldLogs = @(Get-ChildItem -LiteralPath $LogDir -Filter 'build-mod-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -Skip 19)
foreach ($l in $oldLogs) { Remove-Item -LiteralPath $l.FullName -Force -ErrorAction SilentlyContinue }
try { Start-Transcript -Path $LogFile -Force | Out-Null } catch { }
trap {
    Write-Host ""
    Write-Host ("[ERROR] Unexpected error: " + $_.Exception.Message) -ForegroundColor Red
    Write-Host ($_.ScriptStackTrace) -ForegroundColor DarkGray
    try {
        $wd = Join-Path $env:TEMP 'hd2_bink_work'
        if (Test-Path -LiteralPath $wd) { Remove-Item -LiteralPath $wd -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { }
    try { Stop-Transcript | Out-Null } catch { }
    Read-Host "Press Enter to close this window"
    exit 1
}

# ---- paths ----
$Root    = $PSScriptRoot
$Tools   = Join-Path $Root 'tools'
$Bink    = Join-Path $Tools 'binktest'
$Scripts = Join-Path $Tools 'scripts'      # PowerShell helper scripts
$PySrc   = Join-Path $Root 'src'           # Python modules (also the coverage-gate target)
$Assets  = Join-Path $Root 'assets'
$OutRoot = Join-Path $Root 'output'
$CfgFile = Join-Path $Root 'config.json'

$EncodePs1   = Join-Path $Tools 'encode.ps1'
$AnalyzePs1  = Join-Path $Scripts 'analyze-bink.ps1'
$MakePatchPy = Join-Path $PySrc 'make-final-patch2.py'
$BinkExtract = Join-Path $Bink 'BinkExtractAudio.exe'
$BinkTest    = Join-Path $Bink 'binktest.exe'
$V1   = Join-Path $Assets '83cc35d311ee2648.stream'
$Base = Join-Path $Assets '9ba626afa44a3aa3.patch_0'

# ---- dependency cache (same policy as tools\deps.ps1) ----
# Downloaded dependencies live here. Keep them inside the project, unless the project
# itself sits on the system drive and another fixed drive is available - then that other
# drive is used so the system drive stays clean.
$DepsRoot = Join-Path $Root 'deps'
try {
    $projQual = Split-Path -Qualifier $Root -ErrorAction SilentlyContinue
    if ($projQual -and ($projQual -eq $env:SystemDrive)) {
        $otherDrives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
            Where-Object { $_.DeviceID -and ($_.DeviceID -ne $env:SystemDrive) } |
            Sort-Object -Property FreeSpace -Descending)
        if ($otherDrives.Count -gt 0) { $DepsRoot = Join-Path ($otherDrives[0].DeviceID + '\') 'hd2-intro-modder-deps' }
    }
} catch { }

# A build that cannot produce a usable mod is quarantined into output\failed\ instead of
# being handed to the user. Oldest quarantined builds are pruned beyond this count.
$MaxFailedKept = 10

# Dependency scan verbosity: the full checklist is printed on the first run and whenever
# something is missing. Once a run got past the dependency gate, this stamp makes later
# runs print a one-line summary instead - the checks themselves still run (they are cheap),
# they just stop being noise. Any blocked run drops the stamp, so the next run is verbose
# again. Delete the file to force a full listing.
$DepsStamp = Join-Path $DepsRoot '.deps-ok'
$verboseDeps = -not (Test-Path -LiteralPath $DepsStamp)

function W([string]$msg, [string]$color = 'White') { Write-Host $msg -ForegroundColor $color }

# Quarantine a half-built output folder so the user can never pick up an unusable mod.
# At most $MaxFailedKept quarantined builds are kept; the oldest ones are removed first.
function Move-FailedOutput {
    param([string]$Dir, [string]$Reason)
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $failedRoot = Join-Path $OutRoot 'failed'
    New-Item -ItemType Directory -Path $failedRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $failedRoot ((Split-Path $Dir -Leaf) + '-' + $stamp)
    try { Set-Content -LiteralPath (Join-Path $Dir 'FAILED.txt') -Value $Reason -Encoding utf8 } catch { }
    Move-Item -LiteralPath $Dir -Destination $dest -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $dest) { W ("  [QUARANTINE] unusable output moved to: " + $dest) "Red" }
    $all = @(Get-ChildItem -LiteralPath $failedRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($all.Count -gt $MaxFailedKept) {
        foreach ($d in ($all | Select-Object -Skip $MaxFailedKept)) {
            Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
            W ("  [cleanup] removed old failed build: " + $d.Name) "DarkGray"
        }
    }
}

# ---- config ----
# Keep $cfg a hashtable rather than the raw PSCustomObject from ConvertFrom-Json:
# a key that is absent from an older config.json must still be assignable, otherwise
# saving a newly detected path throws "property cannot be found on this object".
$cfg = @{ wwise = ""; wproj = ""; gameDir = "" }
if (Test-Path -LiteralPath $CfgFile) {
    try {
        $loaded = Get-Content -LiteralPath $CfgFile -Raw | ConvertFrom-Json
        foreach ($k in @('wwise', 'wproj', 'gameDir')) {
            $prop = $loaded.PSObject.Properties[$k]
            if ($prop -and $prop.Value) { $cfg[$k] = [string]$prop.Value }
        }
    } catch { }
}
function Save-Cfg {
    $o = [ordered]@{ wwise = [string]$cfg.wwise; wproj = [string]$cfg.wproj; gameDir = [string]$cfg.gameDir }
    $o | ConvertTo-Json | Set-Content -LiteralPath $CfgFile -Encoding utf8
}

# ---- finders ----
function Find-Radvideo64 {
    $cmd = Get-Command radvideo64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
        (Join-Path $Root 'radvideo64.exe'),
        (Join-Path $Root 'RADVideo\radvideo64.exe'),
        (Join-Path $Tools 'radvideo64.exe'),
        'C:\Program Files\RAD Video Tools\radvideo64.exe',
        'C:\Program Files (x86)\RAD Video Tools\radvideo64.exe',
        'C:\Program Files\RADVideo\radvideo64.exe',
        'C:\Program Files (x86)\RADVideo\radvideo64.exe'
    )) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Find-Python {
    # 1. via PATH (python / py launcher)
    foreach ($c in @('python','py')) {
        if (Get-Command $c -ErrorAction SilentlyContinue) {
            try {
                $v = (& $c --version 2>&1 | Select-Object -First 1)
                if ($LASTEXITCODE -eq 0 -and $v) { return $c }
            } catch { }
        }
    }
    # 2. via common install locations (absolute paths, no PATH needed)
    $candidates = @(
        (Join-Path $DepsRoot 'python\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Python\bin\python.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\*\python.exe'),
        'C:\Python*\python.exe',
        'C:\Program Files\Python*\python.exe',
        'C:\Program Files (x86)\Python*\python.exe'
    )
    foreach ($p in $candidates) {
        $exe = Get-Item -Path $p -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) {
            try {
                $v = (& $exe.FullName --version 2>&1 | Select-Object -First 1)
                if ($LASTEXITCODE -eq 0 -and $v) { return $exe.FullName }
            } catch { }
        }
    }
    return $null
}

function Find-WwiseConsole {
    $hits = @()
    if ($Wwise) {
        if ((Test-Path -LiteralPath $Wwise -PathType Leaf) -and ((Split-Path $Wwise -Leaf) -eq 'WwiseConsole.exe')) { return $Wwise }
        $hits += Get-ChildItem -LiteralPath $Wwise -Recurse -Filter WwiseConsole.exe -ErrorAction SilentlyContinue
    }
    if ($cfg.wwise -and (Test-Path -LiteralPath $cfg.wwise)) { return ([string]$cfg.wwise) }
    foreach ($d in @((Join-Path $Root 'Wwise'), 'C:\Audiokinetic', 'C:\Program Files\Audiokinetic')) {
        if (Test-Path -LiteralPath $d) {
            $hits += Get-ChildItem -LiteralPath $d -Recurse -Filter WwiseConsole.exe -ErrorAction SilentlyContinue
        }
    }
    if ($hits) { return $hits[0].FullName }
    return $null
}

function Get-WwiseMajor {
    # The installed Wwise major decides which bundled project is usable: a newer Wwise
    # upgrades an older project in place and irreversibly (see Copy-WwiseProject), while an
    # older Wwise refuses to open a project a newer one already upgraded.
    if (-not $ww) { return 0 }
    try {
        $m = [regex]::Match([string](Get-Item -LiteralPath $ww).VersionInfo.FileVersion, '^(\d{4})')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    } catch { }
    return 0
}

function Get-WprojMajor {
    # Reads WwiseVersion="v2026.1.3" out of the project header; 0 when it cannot be read.
    param([string]$Path)
    try {
        $head = (Get-Content -LiteralPath $Path -TotalCount 3 -ErrorAction Stop) -join ' '
        $m = [regex]::Match($head, 'WwiseVersion="v(\d{4})')
        if ($m.Success) { return [int]$m.Groups[1].Value }
    } catch { }
    return 0
}

function Find-Wproj {
    if ($Wproj -and (Test-Path -LiteralPath $Wproj)) { return $Wproj }
    $major = Get-WwiseMajor
    # A remembered path is reused only when it is not newer than the Wwise in use - pointing
    # 2025.x at a project a newer Wwise already upgraded just fails to load.
    if ($cfg.wproj -and (Test-Path -LiteralPath $cfg.wproj)) {
        $cfgMajor = Get-WprojMajor -Path $cfg.wproj
        if (($major -le 0) -or ($cfgMajor -le 0) -or ($cfgMajor -le $major)) { return ([string]$cfg.wproj) }
    }
    # Two projects ship with the package; prefer the one matching the installed major.
    $bundled = @()
    if ($major -ge 2026) { $bundled += (Join-Path $Root 'wwise-project\intro-convert-2026\intro-convert.wproj') }
    $bundled += (Join-Path $Root 'wwise-project\intro-convert\intro-convert.wproj')
    foreach ($b in $bundled) { if (Test-Path -LiteralPath $b) { return $b } }
    $hits = Get-ChildItem -LiteralPath $Root -Recurse -Filter *.wproj -ErrorAction SilentlyContinue
    if ($hits) { return $hits[0].FullName }
    return $null
}

function Copy-WwiseProject {
    # A .wproj is only the entry point: its work units live in the same folder and migrate
    # rewrites all of them, so the whole folder has to be copied. Returns the copied .wproj.
    param([string]$Project, [string]$WorkRoot)
    $srcDir = Split-Path -Parent $Project
    $dstDir = Join-Path $WorkRoot ('project-' + (Split-Path $srcDir -Leaf))
    if (Test-Path -LiteralPath $dstDir) { Remove-Item -LiteralPath $dstDir -Recurse -Force -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath $srcDir -Destination $dstDir -Recurse -Force
    return (Join-Path $dstDir (Split-Path $Project -Leaf))
}

function Find-Ffmpeg {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $DepsRoot 'ffmpeg\bin\ffmpeg.exe'),
            'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
            'C:\ffmpeg\bin\ffmpeg.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Find-Ffprobe {
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $DepsRoot 'ffmpeg\bin\ffprobe.exe'),
            'C:\Program Files\ffmpeg\bin\ffprobe.exe',
            'C:\ffmpeg\bin\ffprobe.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

# ---- Helldivers 2 install (only needed for the optional decode check) ----
function Get-SteamLibraryRoots {
    $roots = @()
    $steam = $null
    foreach ($k in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            foreach ($v in @($p.SteamPath, $p.InstallPath)) {
                if ($v) { $steam = ($v -replace '/', '\'); break }
            }
        } catch { }
        if ($steam) { break }
    }
    if (-not $steam) { return $roots }
    $roots += $steam
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $hits = Select-String -LiteralPath $vdf -Pattern '"path"\s+"(.+?)"' -AllMatches -ErrorAction SilentlyContinue
        foreach ($h in $hits) {
            foreach ($m in $h.Matches) { $roots += ($m.Groups[1].Value -replace '\\\\', '\') }
        }
    }
    return ($roots | Select-Object -Unique)
}

function Find-Hd2GameDir {
    # 1) explicit -GameDir, then the path remembered from a previous run.
    #    Accept either the game root or its bin\ folder.
    foreach ($c in @($GameDir, [string]$cfg.gameDir)) {
        if (-not $c) { continue }
        foreach ($d in @($c, (Split-Path $c -Parent))) {
            if ($d -and (Test-Path -LiteralPath (Join-Path $d 'bin\bink2w64.dll'))) { return $d }
        }
    }
    # 2) Steam registry + every library folder it points at
    foreach ($lib in (Get-SteamLibraryRoots)) {
        $d = Join-Path $lib 'steamapps\common\Helldivers 2'
        if (Test-Path -LiteralPath (Join-Path $d 'bin\bink2w64.dll')) { return $d }
    }
    # 3) the mod manager's config, when it happens to sit in AppData
    $mmCfg = Join-Path $env:LOCALAPPDATA 'Helldivers2ModManager\settings.json'
    if (Test-Path -LiteralPath $mmCfg) {
        try {
            $j = Get-Content -LiteralPath $mmCfg -Raw | ConvertFrom-Json
            if ($j.GameDirectory -and (Test-Path -LiteralPath (Join-Path ([string]$j.GameDirectory) 'bin\bink2w64.dll'))) {
                return [string]$j.GameDirectory
            }
        } catch { }
    }
    # 4) common install paths on every fixed drive
    try {
        $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { $_.DeviceID })
    } catch { $drives = @() }
    foreach ($drv in $drives) {
        foreach ($rel in @('SteamLibrary', 'Steam', 'Program Files (x86)\Steam', 'Program Files\Steam', 'steam', 'Games\Steam')) {
            $d = Join-Path $drv (Join-Path $rel 'steamapps\common\Helldivers 2')
            if (Test-Path -LiteralPath (Join-Path $d 'bin\bink2w64.dll')) { return $d }
        }
    }
    return $null
}

function Find-BinkDll {
    # a) a copy the user dropped next to binktest.exe (manual override, always wins)
    $local = Join-Path $Bink 'bink2w64.dll'
    if (Test-Path -LiteralPath $local) { return $local }
    # b) the copy every Helldivers 2 installation already ships
    $g = Find-Hd2GameDir
    if ($g) {
        $dll = Join-Path $g 'bin\bink2w64.dll'
        if (Test-Path -LiteralPath $dll) { return $dll }
    }
    return $null
}

# ================= scan =================
W "=== HD2 intro mod generator ===" "Cyan"

if (-not (Test-Path -LiteralPath $Video)) { W "[FATAL] input not found: $Video" "Red"; Stop-Script 1 }

$rv     = Find-Radvideo64
$py     = Find-Python
$ww     = Find-WwiseConsole
$wproj  = Find-Wproj
$gameDirFound = Find-Hd2GameDir
$ffmpegExe  = Find-Ffmpeg
$ffprobeExe = Find-Ffprobe

# ---- vanilla notice video: bundled when present, otherwise rebuilt from the player's game ----
# The notice is Helldivers 2 game data, so it is deliberately NOT redistributed with this
# package (which keeps the published download free of game assets). When
# assets\83cc35d311ee2648.stream is absent we rebuild it from the player's own
# bundles.*.nxa - byte-for-byte identical to what the game ships (verified by SHA256).
$NoticePackage = '83cc35d311ee2648'
if (-not (Test-Path -LiteralPath $V1)) {
    W "[0] vanilla notice video (not bundled - rebuilding from your game)" "Yellow"
    $ExtractPy = Join-Path $Tools 'extract-vanilla.py'
    if (-not $gameDirFound) {
        W "  [MISS] Helldivers 2 install not found - pass -GameDir <path>" "Red"
    } elseif (-not $py) {
        W "  [MISS] python is required to rebuild the notice video" "Red"
    } elseif (-not (Test-Path -LiteralPath $ExtractPy)) {
        W "  [MISS] missing helper: $ExtractPy" "Red"
    } else {
        & $py $ExtractPy (Join-Path $gameDirFound 'data') $NoticePackage $Assets
        # the helper also writes the package container and a .gpu_resources sibling;
        # this project only needs the .stream, so drop the leftovers.
        foreach ($junk in @((Join-Path $Assets $NoticePackage), (Join-Path $Assets ($NoticePackage + '.gpu_resources')))) {
            if (Test-Path -LiteralPath $junk) { Remove-Item -LiteralPath $junk -Force -ErrorAction SilentlyContinue }
        }
        if (Test-Path -LiteralPath $V1) {
            W ("  [OK]   rebuilt from bundles (" + (Get-Item -LiteralPath $V1).Length + " bytes)") "Green"
        } else {
            W "  [MISS] rebuild failed - see the message above." "Red"
            W "         You can also place the file manually at: $V1" "Red"
        }
    }
}

# built-in assets
$builtin = @(
    @{ n = 'base container';  p = $Base },
    @{ n = 'notice video';    p = $V1 },
    @{ n = 'binktest.exe';    p = $BinkTest },
    @{ n = 'BinkExtractAudio';p = $BinkExtract },
    @{ n = 'make-final-patch2.py'; p = $MakePatchPy },
    @{ n = 'encode.ps1';      p = $EncodePs1 }
)
$builtinOk = $true
if ($verboseDeps) { W "[1] built-in tools" "Yellow" }
foreach ($b in $builtin) {
    if (Test-Path -LiteralPath $b.p) { if ($verboseDeps) { W ("  [OK]   " + $b.n) "Green" } }
    else { W ("  [MISS] " + $b.n + "  <- " + $b.p) "Red"; $builtinOk = $false }
}

if ($verboseDeps) { W "[2] radvideo64 (video encoder)" "Yellow" }
if ($rv) { if ($verboseDeps) { W "  [OK]   $rv" "Green" } }
else { W "  [MISS] Install RAD Video Tools (free) from https://www.radgametools.com/bnkdown.htm" "Red"
       W "         or drop radvideo64.exe into: $Root" "Red" }

if ($verboseDeps) { W "[3] python (packager)" "Yellow" }
if ($py) { if ($verboseDeps) { W "  [OK]   $py" "Green" } }
else { W "  [MISS] Install Python 3 from https://www.python.org/downloads/ (tick 'Add to PATH')" "Red" }

if ($verboseDeps) { W "[4] ffmpeg + ffprobe (resolution guards)" "Yellow" }
if ($ffmpegExe -and $ffprobeExe) { if ($verboseDeps) { W "  [OK]   $ffmpegExe" "Green" } }
else {
    W "  [MISS] ffmpeg/ffprobe not found." "Red"
    W "         Without ffprobe the source resolution cannot be inspected, so the script" "Red"
    W "         cannot tell whether a source needs rescaling - and a source below 720p" "Red"
    W "         produces a mod that shows corrupted video in game. Both are required." "Red"
    W "         Easiest: open the GUI and use its dependency panel." "DarkGray"
    W "         Or run: powershell -ExecutionPolicy Bypass -File tools\deps.ps1 -Download -Which ffmpeg" "DarkGray"
}

if ($verboseDeps) { W "[5] audio" "Yellow" }
if ($Wem) {
    if (Test-Path -LiteralPath $Wem) { if ($verboseDeps) { W "  [OK]   ready-made wem: $Wem" "Green" } }
    else { W "  [FATAL] -Wem file not found: $Wem" "Red"; Stop-Script 1 }
} elseif ($ww -and $wproj) {
    if ($verboseDeps) { W "  [OK]   WwiseConsole: $ww" "Green" }
    if ($verboseDeps) { W "  [OK]   wproj: $wproj" "Green" }
} else {
    if (-not $ww)  { W "  [MISS] WwiseConsole.exe (Wwise, free, needs Audiokinetic account; recommended 2025.1.2 or newer)" "Red"
                     W "         download: https://www.audiokinetic.com/download/  (install, then rerun)" "Red" }
    if (-not $wproj) { W "  [MISS] Wwise Audio Conversion project (.wproj) - create in Wwise Authoring (Audio Conversion template), or pass -Wproj" "Red" }
    W "         OR pass a ready-made .wem via -Wem to skip Wwise entirely." "Yellow"
}

# bink2w64.dll is needed by BOTH bundled bink tools: BinkExtractAudio reads the BINK
# audio track out of the encoded .bk2, and binktest decodes frames. It is a commercial
# RAD Game Tools / Epic Games Tools DLL, so it is deliberately NOT shipped with this
# package. We take the copy the game itself installed and stage both tools plus that DLL
# in a temp work dir - neither the package folder nor the game folder gets touched.
if ($verboseDeps) { W "[6] bink2w64.dll (audio extraction + decode check)" "Yellow" }
$binkDll = Find-BinkDll
$BinkWorkExe  = $BinkExtract
$BinkWorkTest = $BinkTest
$BinkWorkDir  = Join-Path $env:TEMP 'hd2_bink_work'
if ($binkDll) {
    if (Test-Path -LiteralPath $BinkWorkDir) { Remove-Item -LiteralPath $BinkWorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $BinkWorkDir -Force | Out-Null
    Copy-Item -LiteralPath $BinkExtract -Destination $BinkWorkDir -Force
    Copy-Item -LiteralPath $BinkTest    -Destination $BinkWorkDir -Force
    Copy-Item -LiteralPath $binkDll     -Destination $BinkWorkDir -Force
    $BinkWorkExe  = Join-Path $BinkWorkDir 'BinkExtractAudio.exe'
    $BinkWorkTest = Join-Path $BinkWorkDir 'binktest.exe'
    if ($verboseDeps) { W "  [OK]   $binkDll" "Green" }
} else {
    W "  [MISS] bink2w64.dll not found - audio cannot be extracted from the video." "Red"
    W "         Every Helldivers 2 install has it at <game>\bin\bink2w64.dll" "DarkGray"
    W "         Pass -GameDir <path>, or drop a copy into: $Bink" "DarkGray"
    W "         (Or supply a ready-made wem with -Wem to skip audio extraction entirely.)" "DarkGray"
}

# ---- hard blockers ----
$fatal = @()
if (-not $builtinOk) { $fatal += 'built-in assets missing (incomplete package)' }
if (-not $rv)        { $fatal += 'radvideo64.exe missing' }
if (-not $py)        { $fatal += 'python missing' }
if (-not $Wem -and (-not $ww -or -not $wproj)) { $fatal += 'audio not available (no -Wem, no Wwise+wproj)' }
if (-not $ffmpegExe -or -not $ffprobeExe) { $fatal += 'ffmpeg/ffprobe missing (needed so that any resolution still yields a usable mod)' }
if ($fatal.Count -gt 0) {
    Remove-Item -LiteralPath $DepsStamp -Force -ErrorAction SilentlyContinue
    W "" "Red"
    W "Blocked - fix the following, then rerun:" "Red"
    foreach ($f in $fatal) { W "  - $f" "Red" }
    W "" "Yellow"
    W "Missing pieces can be fetched from the GUI dependency panel, or with:" "Yellow"
    W "  powershell -ExecutionPolicy Bypass -File tools\deps.ps1 -Download -Which ffmpeg,python" "DarkGray"
    Stop-Script 1
}

# The stamp only means "this machine has everything the pipeline needs": it is written
# once the dependency gate is passed, and dropped again by any blocked run so that the
# next attempt prints the full checklist.
New-Item -ItemType Directory -Path $DepsRoot -Force | Out-Null
try { Set-Content -LiteralPath $DepsStamp -Value ((Get-Date).ToString('s')) -Encoding ascii -ErrorAction SilentlyContinue } catch { }
if (-not $verboseDeps) { W "[deps] all dependencies present (cached; delete deps\.deps-ok to list everything)" "DarkGray" }

# ---- remember Wwise path (and the game dir, so the next run skips the search) ----
if ($ww -and -not $cfg.wwise) { $cfg.wwise = $ww }
if ($wproj -and -not $cfg.wproj) { $cfg.wproj = $wproj }
if ($gameDirFound -and -not $cfg.gameDir) { $cfg.gameDir = $gameDirFound }
Save-Cfg

# ================= output dir =================
if (-not $Out) {
    $dirName = [System.IO.Path]::GetFileNameWithoutExtension($Video)
    $dirName = $dirName -replace '[^\x20-\x7E]', ''
    if ([string]::IsNullOrWhiteSpace($dirName)) { $dirName = 'mod' }
    $Out = Join-Path $OutRoot $dirName
    if (Test-Path -LiteralPath $Out) {
        $i = 2
        while (Test-Path -LiteralPath (Join-Path $OutRoot "$dirName-$i")) { $i++ }
        $Out = Join-Path $OutRoot "$dirName-$i"
    }
}
New-Item -ItemType Directory -Path $Out -Force | Out-Null
W "" "Cyan"
W "Output: $Out" "Cyan"

$Bk2 = Join-Path $Out 'video.bk2'
$ReEnc = Join-Path $Out 'reencoded-720p.mp4'
$ReEnc2k = Join-Path $Out 'reencoded-2k60.mp4'

# ---- resolution/fps guards: <720p upscale to 1280x720 (kit pitfall #15: corrupts in-game);
#      4K >60fps downscale to 2560x1440@60 (bink encode of 4K120 takes ~1h+, 2K60 is ~4x faster) ----
if ($ffmpegExe -and $ffprobeExe) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    # ---- pick the encoder for the rescale pass: NVENC when the machine really has it ----
    # radvideo64 reads h264_nvenc output fine (verified) and NVENC is ~2.5x faster than libx264.
    # A real 0.2s probe is used because "-encoders" lists NVENC even on machines where it fails.
    $vEnc = @('-c:v', 'libx264', '-crf', '20')
    $vEncName = 'libx264'
    if ((& $ffmpegExe -hide_banner -encoders 2>$null | Out-String) -match 'h264_nvenc') {
        $nvencProbe = Join-Path $env:TEMP ('hd2_nvenc_probe_' + (Get-Random) + '.mp4')
        & $ffmpegExe -hide_banner -loglevel error -f lavfi -i "color=c=black:s=320x240:r=30" -t 0.2 -c:v h264_nvenc -f mp4 $nvencProbe 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $nvencProbe)) {
            $vEnc = @('-c:v', 'h264_nvenc', '-preset', 'p5', '-cq', '20')
            $vEncName = 'h264_nvenc (GPU)'
        }
        Remove-Item -LiteralPath $nvencProbe -Force -ErrorAction SilentlyContinue
    }

    $probe = & $ffprobeExe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 $Video 2>$null
    $pm = [regex]::Match((($probe | Out-String)), '(\d+)x(\d+)')
    if ($pm.Success) {
        $srcW = [int]$pm.Groups[1].Value
        $srcH = [int]$pm.Groups[2].Value
        $fpsProbe = & $ffprobeExe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 $Video 2>$null
        $fps = 0.0
        $fm = [regex]::Match((($fpsProbe | Out-String)), '(\d+(?:\.\d+)?)/(\d+)')
        if ($fm.Success -and [int]$fm.Groups[2].Value -gt 0) { $fps = [double]$fm.Groups[1].Value / [int]$fm.Groups[2].Value }
        if ($srcH -lt 720) {
            W ("  [WARN] source is {0}x{1} (<720p) - would corrupt in-game. Re-encoding to 1280x720..." -f $srcW, $srcH) "Yellow"
            & $ffmpegExe -y -i $Video -vf "scale=1280:720,setsar=1" -r 30 @vEnc -c:a aac -b:a 192k -ar 48000 $ReEnc 2>$null
            $ffExit = $LASTEXITCODE
            if ($ffExit -eq 0 -and (Test-Path -LiteralPath $ReEnc) -and ((Get-Item -LiteralPath $ReEnc).Length -gt 0)) {
                $Video = $ReEnc
                W "  [OK]   re-encoded to 1280x720" "Green"
            } else {
                W "  [FATAL] ffmpeg rescale failed (exit $ffExit)." "Red"
                W "          A source below 720p cannot be used as-is: the game shows corrupted" "Red"
                W "          video. Refusing to produce an unusable mod." "Red"
                Move-FailedOutput -Dir $Out -Reason "ffmpeg rescale of a below-720p source failed (exit $ffExit)"
                Stop-Script 1
            }
        } elseif ($srcH -gt 1440 -or $fps -gt 60) {
            # Caps: 2560x1440 and 60fps (frame rate follows the source below that).
            # Why: bink2c cost scales with pixels x frames, and it is CPU-only (RAD: "massively
            # multi-threaded", no GPU path). The 2026-08-30 run died after 30 min on a
            # 3840x2160@120 source. For reference the vanilla intro is 1280x720@30 and the
            # vanilla notice is 3840x2160@30, so both sit inside these caps.
            $outFps = 30
            if ($fps -ge 1) { $outFps = [int][Math]::Floor([Math]::Min($fps, 60.0)) }
            $scaleTo = if ($srcH -gt 1440) { 'scale=2560:1440,setsar=1' } else { 'scale=trunc(iw/2)*2:trunc(ih/2)*2,setsar=1' }
            W ("  [WARN] source is {0}x{1} @ {2:N0}fps - above the 1440p/60fps cap. Re-encoding to {3}fps with {4}..." -f $srcW, $srcH, $fps, $outFps, $vEncName) "Yellow"
            & $ffmpegExe -y -i $Video -vf $scaleTo -r $outFps @vEnc -c:a aac -b:a 192k -ar 48000 $ReEnc2k 2>$null
            $ffExit = $LASTEXITCODE
            if ($ffExit -eq 0 -and (Test-Path -LiteralPath $ReEnc2k) -and ((Get-Item -LiteralPath $ReEnc2k).Length -gt 0)) {
                $Video = $ReEnc2k
                W "  [OK]   re-encoded (bink encode time cut dramatically)" "Green"
            } else {
                W "  [WARN] ffmpeg downscale failed (exit $ffExit) - continuing with the original." "Yellow"
                W "         The mod will still be valid, but bink2c is CPU-only: an oversized" "Yellow"
                W "         source can take a very long time (the encoder timeout is 2 hours)." "Yellow"
            }
        }
    }
    $ErrorActionPreference = $prevEAP
} else {
    W "  [INFO] ffmpeg not found - skipping resolution/fps guards (install ffmpeg for auto 720p fix and 4K>60fps downscale)" "DarkGray"
}

# ================= 1. encode =================
W "" "Cyan"
W "[1/4] Encoding video (radvideo64 GUI will pop up; it auto-closes on its own - do not touch it)..." "Yellow"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $EncodePs1 -Video $Video -Output $Bk2
if ($LASTEXITCODE -ne 0) { W "[FATAL] encode failed" "Red"; Stop-Script 1 }
if (-not (Test-Path -LiteralPath $Bk2) -or (Get-Item -LiteralPath $Bk2).Length -eq 0) { W "[FATAL] encode produced no output" "Red"; Stop-Script 1 }

# flags check (must be 0x40012)
$ana = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $AnalyzePs1 -Paths $Bk2 2>$null
$flagsOk = $false
$fm = [regex]::Match((($ana | Out-String)), 'fl=0x([0-9A-Fa-f]+)')
if ($fm.Success) {
    $flags = [Convert]::ToUInt32($fm.Groups[1].Value, 16)
    if ($flags -eq 0x40012) { $flagsOk = $true; W "  [OK]   flags=0x40012 (game-compatible)" "Green" }
    else {
        W "  [FATAL] flags=0x$($flags.ToString('X')) - the game requires 0x40012 and may crash otherwise." "Red"
        W "          Refusing to produce a mod that can crash the game." "Red"
        Move-FailedOutput -Dir $Out -Reason "encoded .bk2 has flags=0x$($flags.ToString('X')) instead of 0x40012"
        Stop-Script 1
    }
} else {
    W "  [FATAL] could not read the .bk2 flags - the mod cannot be verified as game-compatible." "Red"
    Move-FailedOutput -Dir $Out -Reason "could not parse the .bk2 flags"
    Stop-Script 1
}

# ================= 2. audio =================
W "" "Cyan"
W "[2/4] Audio..." "Yellow"
$WemFile = ""
if ($Wem) {
    $WemFile = $Wem
    W "  using provided wem: $WemFile" "Green"
} else {
    $Wav = Join-Path $Out 'audio.wav'
    W "  extracting BINK track -> wav..." "Yellow"
    if (-not $binkDll) {
        Remove-Item -LiteralPath $DepsStamp -Force -ErrorAction SilentlyContinue
        W "  [FATAL] bink2w64.dll is required to read the BINK audio track (see [6] above)." "Red"
        W "         Point the script at your game with -GameDir, or pass -Wem with a ready-made wem." "Red"
        Stop-Script 1
    }
    & $BinkWorkExe $Bk2 $Wav
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $Wav) -or (Get-Item -LiteralPath $Wav).Length -eq 0) {
        W "  [FATAL] audio extract failed (video has no audio track?) - pass -Wem with a ready-made wem" "Red"; Stop-Script 1
    }
    W "  converting wav -> wem (Wwise Vorbis)..." "Yellow"
    $Wsources = Join-Path $Out 'wsources.xml'
    $WemOutDir = Join-Path $Out 'wwise'
    New-Item -ItemType Directory -Path $WemOutDir -Force | Out-Null
    $xml = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<ExternalSourcesList SchemaVersion=`"1`" Root=`"$Out`">`n  <Source Path=`"audio.wav`" Conversion=`"Vorbis Quality High`" Destination=`"audio`"/>`n</ExternalSourcesList>"
    [System.IO.File]::WriteAllText($Wsources, $xml, (New-Object System.Text.UTF8Encoding($false)))
    # migrate upgrades the project format IN PLACE and that upgrade cannot be undone
    # (measured: a project migrated to 2026's schema 139 can no longer be opened by
    # 2025.1.2). Run migrate/convert against a copy inside the output folder so the
    # package's own wwise-project\ is never rewritten.
    $wprojWork = Copy-WwiseProject -Project $wproj -WorkRoot $WemOutDir
    & $ww migrate $wprojWork --quiet
    & $ww convert-external-source $wprojWork --platform Windows --source-file $Wsources --output $WemOutDir
    $WemFile = Join-Path $WemOutDir 'Windows\audio.wem'
    if (-not (Test-Path -LiteralPath $WemFile)) {
        W "  [FATAL] wem conversion failed - check Wwise logs, or pass -Wem with a ready-made wem" "Red"; Stop-Script 1
    }
    W "  [OK]   wem: $WemFile" "Green"
}

# ================= 3. package =================
W "" "Cyan"
W "[3/4] Packaging patch_$Num..." "Yellow"
& $py $MakePatchPy --wem $WemFile --v2 $Bk2 --v1 $V1 --base $Base --out $Out --num $Num
if ($LASTEXITCODE -ne 0) { W "[FATAL] package failed" "Red"; Stop-Script 1 }

# ================= 4. verify (optional full decode) =================
# binktest.exe is our own tool, but it P/Invokes bink2w64.dll, which is commercial and
# therefore not shipped. Both files are copied into a temp dir and run from there, so
# neither the package folder nor the game folder is touched. No DLL = skip, not fail.
W "" "Cyan"
W "[4/4] Verify (full-frame decode)..." "Yellow"
if (-not $binkDll) {
    W "  [SKIP] no bink2w64.dll - the full-frame decode check was NOT performed (see [6] above)." "Yellow"
    W "         The mod was built, but its video could not be verified frame by frame." "Yellow"
} else {
    & $BinkWorkTest $Bk2 3000
    if ($LASTEXITCODE -eq 0) { W "  [OK]   decode passed" "Green" }
    else {
        W "  [FATAL] full-frame decode failed - the produced .bk2 is damaged." "Red"
        W "          Refusing to ship a broken mod." "Red"
        Move-FailedOutput -Dir $Out -Reason "binktest full-frame decode failed (exit $LASTEXITCODE)"
        Stop-Script 1
    }
}

# ---- clean up intermediate files (keep only the final patch + stream) ----
foreach ($tmp in @($Bk2, $ReEnc, $ReEnc2k, (Join-Path $Out 'audio.wav'), (Join-Path $Out 'wsources.xml'))) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $Out 'wwise') -Recurse -Force -ErrorAction SilentlyContinue

# ================= done =================
$patchFile = Join-Path $Out "9ba626afa44a3aa3.patch_$Num"
$streamFile = $patchFile + '.stream'
$zipPath = $Out + '.zip'
if ($Zip) {
    Compress-Archive -Path (Join-Path $Out '*') -DestinationPath $zipPath -Force
}

W "" "Cyan"
W "=== done ===" "Green"
W ("  patch : " + $patchFile) "Green"
W ("  stream: " + $streamFile) "Green"
if ($Zip) { W ("  zip   : " + $zipPath) "Green" }
W ""
W "Install: copy both files into 'Helldivers 2\data\'." "White"
W "  - patch numbers must be 0..N with no gaps, or the mod is ignored." "White"
if (-not $flagsOk) { W "  - WARNING: flags != 0x40012 - game may crash. Re-encode." "Red" }

Stop-Script 0
