# deps.ps1 - dependency detection and opt-in download helper for hd2-intro-modder.
#
# This script never downloads anything on its own. The GUI (or the user) must call it
# with -Download explicitly, which is how "user consent" is enforced.
#
# Modes (pick one):
#   -Check                                   detect every dependency, print JSON
#   -TestSources                             probe every download URL, print JSON
#   -Download -Which ffmpeg,python [-Source "id=url;id=url"]   fetch + extract those deps
#
# Download location policy:
#   project not on the system drive          -> <project>\deps
#   project on the system drive, other fixed drives exist
#                                            -> <other drive>\hd2-intro-modder-deps
#   project on the system drive, no other drive
#                                            -> <project>\deps   (nothing to avoid)
#
# Every dependency carries an ordered mirror list; the first reachable one wins.
# Everything stays inside the deps root; the staged download is deleted afterwards.
#
# NOTE: keep this file pure ASCII. Windows PowerShell 5.1 reads BOM-less script files
# using the system ANSI code page, so non-ASCII text here breaks parsing. All Chinese
# user-facing text lives in the GUI (Hd2IntroModderGui.cs), keyed by the stable ids.

[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$TestSources,
    [switch]$Download,
    [string[]]$Which = @(),
    [string]$Source = "",
    [string]$DepsRoot = "",
    [int]$ProbeTimeoutSec = 25,
    [switch]$Lines
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# deps.ps1 lives in <project>\tools\
$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $ProjectRoot) { $ProjectRoot = $PSScriptRoot }

$PythonVersion = '3.12.10'

# Several vendor sites answer a bare curl with 000/403 while working fine in a browser
# (measured: audiokinetic.com fails without this, answers 202 with it), so every probe
# carries a browser User-Agent.
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'

# ---------------------------------------------------------------- paths

function Get-DepsRoot {
    param([string]$Project, [string]$Override)
    if ($Override) { return $Override }
    $projQual = $null
    try { $projQual = Split-Path -Qualifier $Project -ErrorAction SilentlyContinue } catch { }
    $sysDrive = $env:SystemDrive
    if ($projQual -and ($projQual -ne $sysDrive)) {
        # normal case: keep everything inside the project
        return (Join-Path $Project 'deps')
    }
    # project sits on the system drive -> prefer another fixed drive
    $others = @()
    try {
        $others = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop |
            Where-Object { $_.DeviceID -and ($_.DeviceID -ne $sysDrive) } |
            Sort-Object -Property FreeSpace -Descending)
    } catch { $others = @() }
    if ($others.Count -gt 0) {
        return (Join-Path ($others[0].DeviceID + '\') 'hd2-intro-modder-deps')
    }
    return (Join-Path $Project 'deps')
}

$DepsRoot = Get-DepsRoot -Project $ProjectRoot -Override $DepsRoot

# ---------------------------------------------------------------- finders
# These mirror the finders in build-mod.ps1, extended with the deps folder so that a
# dependency downloaded by this script is picked up by the generator on the next run.

function Find-Radvideo64Path {
    $cmd = Get-Command radvideo64 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $ProjectRoot 'radvideo64.exe'),
            (Join-Path $ProjectRoot 'RADVideo\radvideo64.exe'),
            (Join-Path $ProjectRoot 'tools\radvideo64.exe'),
            'C:\Program Files\RAD Video Tools\radvideo64.exe',
            'C:\Program Files (x86)\RAD Video Tools\radvideo64.exe',
            'C:\Program Files\RADVideo\radvideo64.exe',
            'C:\Program Files (x86)\RADVideo\radvideo64.exe'
        )) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Find-FfmpegPath {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $DepsRoot 'ffmpeg\bin\ffmpeg.exe'),
            'C:\Program Files\ffmpeg\bin\ffmpeg.exe',
            'C:\ffmpeg\bin\ffmpeg.exe'
        )) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Find-FfprobePath {
    $cmd = Get-Command ffprobe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $DepsRoot 'ffmpeg\bin\ffprobe.exe'),
            'C:\Program Files\ffmpeg\bin\ffprobe.exe',
            'C:\ffmpeg\bin\ffprobe.exe'
        )) { if (Test-Path -LiteralPath $p) { return $p } }
    return $null
}

function Find-PythonPath {
    foreach ($c in @('python', 'py')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) {
            try {
                $v = (& $c --version 2>&1 | Select-Object -First 1)
                if ($LASTEXITCODE -eq 0 -and $v) { return $cmd.Source }
            } catch { }
        }
    }
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

function Find-WwiseConsolePath {
    $cmd = Get-Command WwiseConsole -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($d in @((Join-Path $ProjectRoot 'Wwise'), 'C:\Audiokinetic', 'C:\Program Files\Audiokinetic')) {
        if (Test-Path -LiteralPath $d) {
            $hit = Get-ChildItem -LiteralPath $d -Recurse -Filter 'WwiseConsole.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }
    return $null
}

function Find-WprojPath {
    $cfgFile = Join-Path $ProjectRoot 'config.json'
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $j = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
            if ($j.wproj -and (Test-Path -LiteralPath $j.wproj)) { return [string]$j.wproj }
        } catch { }
    }
    $hit = Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Filter '*.wproj' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

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

function Find-Hd2GameDirPath {
    $cfgFile = Join-Path $ProjectRoot 'config.json'
    if (Test-Path -LiteralPath $cfgFile) {
        try {
            $j = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json
            if ($j.gameDir -and (Test-Path -LiteralPath (Join-Path ([string]$j.gameDir) 'bin\bink2w64.dll'))) {
                return [string]$j.gameDir
            }
        } catch { }
    }
    foreach ($lib in (Get-SteamLibraryRoots)) {
        $d = Join-Path $lib 'steamapps\common\Helldivers 2'
        if (Test-Path -LiteralPath (Join-Path $d 'bin\bink2w64.dll')) { return $d }
    }
    $mmCfg = Join-Path $env:LOCALAPPDATA 'Helldivers2ModManager\settings.json'
    if (Test-Path -LiteralPath $mmCfg) {
        try {
            $j = Get-Content -LiteralPath $mmCfg -Raw | ConvertFrom-Json
            if ($j.GameDirectory -and (Test-Path -LiteralPath (Join-Path ([string]$j.GameDirectory) 'bin\bink2w64.dll'))) {
                return [string]$j.GameDirectory
            }
        } catch { }
    }
    $drives = @()
    try { $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object { $_.DeviceID }) } catch { }
    foreach ($drv in $drives) {
        foreach ($rel in @('SteamLibrary', 'Steam', 'Program Files (x86)\Steam', 'Program Files\Steam', 'steam', 'Games\Steam')) {
            $d = Join-Path $drv (Join-Path $rel 'steamapps\common\Helldivers 2')
            if (Test-Path -LiteralPath (Join-Path $d 'bin\bink2w64.dll')) { return $d }
        }
    }
    return $null
}

# ---------------------------------------------------------------- dependency table

function Get-DepSpecs {
    $huaweiPy = "https://mirrors.huaweicloud.com/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
    $orgPy = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
    $npmPy = "https://registry.npmmirror.com/-/binary/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
    $btbnFfmpeg = 'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip'

    return @(
        [PSCustomObject]@{
            id        = 'radvideo64'
            name      = 'RAD Video Tools'
            required  = $true
            auto      = $false
            condition = 'Always required - the video encoder (bink2c)'
            note      = 'Commercial software, free to use. The vendor only ships an interactive installer, so it cannot be fetched automatically - please install it manually.'
            url       = 'https://www.radgametools.com/bnkdown.htm'
            sources   = @()
            detect    = 'radvideo64'
        },
        [PSCustomObject]@{
            id        = 'python'
            name      = 'Python 3'
            required  = $true
            auto      = $true
            condition = 'Always required - packages the patch container'
            note      = 'The embeddable build is enough: the project scripts only use the standard library.'
            url       = $orgPy
            sources   = @($huaweiPy, $orgPy, $npmPy)
            detect    = 'python'
        },
        [PSCustomObject]@{
            id        = 'ffmpeg'
            name      = 'ffmpeg + ffprobe'
            required  = $true
            auto      = $true
            condition = 'Required so that any resolution works - rescales below 720p, downscales above 1440p/60fps'
            note      = 'Without it a low-resolution source produces a mod that shows corrupted video in game, and a high-resolution source takes so long it will not finish.'
            url       = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
            sources   = @(
                'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip',
                $btbnFfmpeg,
                ('https://gh-proxy.com/' + $btbnFfmpeg)
            )
            detect    = 'ffmpeg'
        },
        [PSCustomObject]@{
            id        = 'wwise'
            name      = 'Wwise (WwiseConsole.exe)'
            required  = $true
            auto      = $false
            condition = 'Required by the default flow - converts the audio into the .wem the game reads'
            note      = 'Needs a free Audiokinetic account and the Wwise Launcher, so it cannot be fetched automatically. If you already have a ready-made .wem you can pass -Wem to skip it.'
            url       = 'https://www.audiokinetic.com/download/'
            sources   = @()
            detect    = 'wwise'
        },
        [PSCustomObject]@{
            id        = 'binkdll'
            name      = 'bink2w64.dll (taken from your game)'
            required  = $true
            auto      = $false
            condition = 'Required by the default flow - extracts the BINK audio track; without it the full decode check is skipped'
            note      = 'Commercial DLL, not redistributed. The script reads the copy your Helldivers 2 install already has.'
            url       = ''
            sources   = @()
            detect    = 'binkdll'
        }
    )
}

function Get-DepStatus {
    param($Spec)
    $path = $null
    switch ($Spec.detect) {
        'radvideo64' { $path = Find-Radvideo64Path }
        'python' { $path = Find-PythonPath }
        'ffmpeg' {
            $f = Find-FfmpegPath
            if ($f -and (Find-FfprobePath)) { $path = $f }
        }
        'wwise' { $path = Find-WwiseConsolePath }
        'binkdll' {
            $g = Find-Hd2GameDirPath
            if ($g) {
                $dll = Join-Path $g 'bin\bink2w64.dll'
                if (Test-Path -LiteralPath $dll) { $path = $dll }
            }
        }
    }
    [PSCustomObject]@{
        id        = $Spec.id
        name      = $Spec.name
        required  = $Spec.required
        auto      = $Spec.auto
        condition = $Spec.condition
        note      = $Spec.note
        url       = $Spec.url
        sources   = $Spec.sources
        installed = [bool]$path
        path      = $(if ($path) { $path } else { '' })
    }
}

# ---------------------------------------------------------------- network helpers

function Get-CurlExe {
    $p = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    return 'curl.exe'
}

function Test-UrlReachable {
    param([string]$Url, [int]$TimeoutSec = 25, [switch]$InfoPage)
    $curl = Get-CurlExe
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $code = ''
    $prev = $ErrorActionPreference
    # curl writes diagnostics to stderr; with ErrorActionPreference=Stop PowerShell turns
    # that into a terminating NativeCommandError, so relax it around the call.
    $ErrorActionPreference = 'Continue'
    try {
        $code = (& $curl -sS -L -o NUL -w '%{http_code}' --max-time $TimeoutSec -r 0-0 -A $UserAgent $Url 2>$null | Out-String).Trim()
    } catch { $code = 'error' }
    finally { $ErrorActionPreference = $prev }
    $sw.Stop()
    $ok = ($code -eq '200' -or $code -eq '206')
    # 429 = the mirror is reachable but throttling us right now (measured on the Huawei
    # Cloud python mirror after repeated probes). Another mirror or a later retry works,
    # so this must not read as "unreachable".
    if (-not $ok -and $code -eq '429') { $ok = $true }
    if (-not $ok -and $InfoPage) {
        # An info page only has to open in a browser. Vendors behind a CDN routinely answer
        # scripted probes with 202/403 while the page itself is perfectly usable.
        # 000 is excluded explicitly: it means curl never got a response at all, and "000"
        # would otherwise match the three-digit pattern and be reported as reachable.
        if ($code -match '^\d{3}$' -and $code -ne '000' -and $code -ne '404' -and $code -ne '410') { $ok = $true }
    }
    [PSCustomObject]@{
        url  = $Url
        http = $code
        ms   = [int]$sw.Elapsed.TotalMilliseconds
        ok   = $ok
    }
}

function Invoke-DepFetch {
    param([string]$Url, [string]$Destination)
    $curl = Get-CurlExe
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $code = -1
    try {
        # -sS: no progress meter (it goes to stderr and used to abort the whole script),
        # but still report real errors. Progress is echoed by the caller instead.
        # -A: the same browser UA the probe uses. Without it a mirror could answer the
        # reachability probe (which sends a UA) with 200 and then reject the real download.
        & $curl -L --fail --retry 2 --connect-timeout 20 --max-time 3600 -sS -A $UserAgent -o $Destination $Url 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } catch {
        $code = -1
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { return $false }
    return ((Test-Path -LiteralPath $Destination) -and ((Get-Item -LiteralPath $Destination).Length -gt 0))
}

# ---------------------------------------------------------------- extract + install

function Install-Dep {
    param([string]$Kind, [string]$ZipPath)
    $stage = Join-Path $DepsRoot ('_stage_' + $Kind)
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $ZipPath -DestinationPath $stage -Force -ErrorAction Stop
    } catch {
        Write-Host ('[deps] extract failed: ' + $_.Exception.Message)
        return $null
    }

    if ($Kind -eq 'ffmpeg') {
        $exe = Get-ChildItem -LiteralPath $stage -Recurse -Filter 'ffmpeg.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $exe) { Write-Host '[deps] ffmpeg.exe not found inside the archive'; return $null }
        $binSrc = $exe.Directory.FullName
        $binDst = Join-Path $DepsRoot 'ffmpeg\bin'
        if (Test-Path -LiteralPath $binDst) { Remove-Item -LiteralPath $binDst -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $binDst -Force | Out-Null
        Copy-Item -Path (Join-Path $binSrc '*') -Destination $binDst -Recurse -Force
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        return (Join-Path $binDst 'ffmpeg.exe')
    }

    if ($Kind -eq 'python') {
        $dst = Join-Path $DepsRoot 'python'
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $stage -Destination $dst -Force
        return (Join-Path $dst 'python.exe')
    }

    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    return $null
}

# ---------------------------------------------------------------- modes

function Invoke-Check {
    $specs = Get-DepSpecs
    $statuses = @()
    foreach ($s in $specs) { $statuses += Get-DepStatus -Spec $s }
    [PSCustomObject]@{
        projectRoot   = $ProjectRoot
        depsRoot      = $DepsRoot
        pythonVersion = $PythonVersion
        wproj         = $(if (Find-WprojPath) { Find-WprojPath } else { '' })
        gameDir       = $(if (Find-Hd2GameDirPath) { Find-Hd2GameDirPath } else { '' })
        deps          = $statuses
    } | ConvertTo-Json -Depth 6
}

function Invoke-TestSources {
    $specs = Get-DepSpecs
    $out = @()
    foreach ($s in $specs) {
        $urls = @()
        $kind = 'info'
        if ($s.auto -and $s.sources.Count -gt 0) { $urls = $s.sources; $kind = 'download' }
        elseif ($s.url) { $urls = @($s.url) }
        if ($urls.Count -eq 0) { continue }
        $probes = @()
        foreach ($u in $urls) { $probes += (Test-UrlReachable -Url $u -TimeoutSec $ProbeTimeoutSec -InfoPage:(-not $s.auto)) }
        $out += [PSCustomObject]@{ id = $s.id; name = $s.name; kind = $kind; probes = $probes }
    }
    [PSCustomObject]@{
        depsRoot  = $DepsRoot
        checkedAt = (Get-Date).ToString('s')
        results   = $out
    } | ConvertTo-Json -Depth 6
}

function Invoke-DownloadDeps {
    $specs = Get-DepSpecs
    $overrideMap = @{}
    if ($Source) {
        # Format: "id=url;id=url". Deliberately NOT json: Windows command-line quote
        # handling strips embedded double quotes, so a json payload arrives mangled
        # whenever the GUI (or a shell) passes -Source through.
        foreach ($pair in ($Source -split ';')) {
            $eq = $pair.IndexOf('=')
            if ($eq -gt 0) {
                $k = $pair.Substring(0, $eq).Trim()
                $v = $pair.Substring($eq + 1).Trim()
                if ($k -and $v) { $overrideMap[$k] = $v }
            }
        }
        if ($overrideMap.Count -eq 0) { Write-Host '[deps] -Source had no usable id=url pairs, ignored.' }
    }

    New-Item -ItemType Directory -Path $DepsRoot -Force | Out-Null
    $downloadDir = Join-Path $DepsRoot '_download'
    New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

    $done = @()
    foreach ($id in $Which) {
        $spec = $specs | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $spec) { Write-Host ('[deps] unknown dependency: ' + $id); continue }
        if (-not $spec.auto) {
            Write-Host ('[deps] ' + $spec.name + ' cannot be downloaded automatically, install it manually: ' + $spec.url)
            continue
        }

        $current = Get-DepStatus -Spec $spec
        if ($current.installed -and -not $overrideMap.ContainsKey($id)) {
            Write-Host ('[deps] ' + $spec.name + ' already present, skipped.')
            $done += [PSCustomObject]@{ id = $id; ok = $true; skipped = $true; path = $current.path }
            continue
        }

        $tryList = @()
        if ($overrideMap.ContainsKey($id)) { $tryList += $overrideMap[$id] }
        foreach ($u in $spec.sources) { if ($tryList -notcontains $u) { $tryList += $u } }

        $zip = Join-Path $downloadDir ($id + '.zip')
        $installed = $null
        foreach ($u in $tryList) {
            Write-Host ('[deps] downloading ' + $spec.name + ' from ' + $u)
            if (Invoke-DepFetch -Url $u -Destination $zip) {
                Write-Host ('[deps] fetched ' + [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1) + ' MB, extracting...')
                $installed = Install-Dep -Kind $id -ZipPath $zip
                if ($installed) { break }
                Write-Host '[deps] extracted result unusable, trying next mirror.'
            } else {
                Write-Host '[deps] mirror unreachable or download failed, trying next mirror.'
            }
        }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        $done += [PSCustomObject]@{
            id      = $id
            ok      = [bool]$installed
            skipped = $false
            path    = $(if ($installed) { $installed } else { '' })
        }
    }

    Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ('[[DEPS_RESULT]]' + ([PSCustomObject]@{ depsRoot = $DepsRoot; results = $done } | ConvertTo-Json -Depth 5 -Compress))
}

# ---------------------------------------------------------------- line format
# The GUI parses these instead of JSON: the C# compiler shipped with .NET Framework
# 4.x targets C# 5 and has no JSON reader, and pulling in System.Web.Extensions just
# for this would add a build dependency. Field values never contain '|', '=' or ';'.

function Format-CheckLines {
    $specs = Get-DepSpecs
    Write-Host ('CHECK|projectRoot=' + $ProjectRoot + '|depsRoot=' + $DepsRoot +
        '|pythonVersion=' + $PythonVersion +
        '|wproj=' + $(if (Find-WprojPath) { Find-WprojPath } else { '' }) +
        '|gameDir=' + $(if (Find-Hd2GameDirPath) { Find-Hd2GameDirPath } else { '' }))
    foreach ($s in $specs) {
        $st = Get-DepStatus -Spec $s
        Write-Host ('DEP|id=' + $st.id + '|name=' + $st.name +
            '|installed=' + $(if ($st.installed) { '1' } else { '0' }) +
            '|auto=' + $(if ($st.auto) { '1' } else { '0' }) +
            '|condition=' + $st.condition +
            '|note=' + $st.note +
            '|url=' + $st.url +
            '|path=' + $st.path +
            '|sources=' + ($st.sources -join ';'))
    }
}

function Format-TestLines {
    $specs = Get-DepSpecs
    foreach ($s in $specs) {
        # Downloadable deps expose their mirrors; the others expose the official page the
        # user must visit by hand. Both are worth probing: someone who cannot reach the
        # RAD / Wwise page should find that out here, not after a failed install attempt.
        $urls = @()
        $kind = 'info'
        if ($s.auto -and $s.sources.Count -gt 0) { $urls = $s.sources; $kind = 'download' }
        elseif ($s.url) { $urls = @($s.url) }
        if ($urls.Count -eq 0) { continue }
        foreach ($u in $urls) {
            $r = Test-UrlReachable -Url $u -TimeoutSec $ProbeTimeoutSec -InfoPage:(-not $s.auto)
            Write-Host ('SRC|id=' + $s.id + '|url=' + $r.url + '|http=' + $r.http +
                '|ms=' + $r.ms + '|ok=' + $(if ($r.ok) { '1' } else { '0' }) + '|kind=' + $kind)
        }
    }
}

# ---------------------------------------------------------------- dispatch

if ($Check) { if ($Lines) { Format-CheckLines } else { Invoke-Check }; return }
if ($TestSources) { if ($Lines) { Format-TestLines } else { Invoke-TestSources }; return }
if ($Download) { Invoke-DownloadDeps; return }

Write-Host 'deps.ps1 - hd2-intro-modder dependency helper'
Write-Host '  -Check                                          detect dependencies'
Write-Host '  -TestSources                                    probe download mirrors'
Write-Host '  -Download -Which ffmpeg,python [-Source id=url;id=url]   download + extract'
Write-Host ''
Write-Host 'Add -Lines to -Check / -TestSources for the machine-readable line format.'
