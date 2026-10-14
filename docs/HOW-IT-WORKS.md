# HD2 intro modder — How it works

> How `hd2-intro-modder` turns an MP4 into a Helldivers 2 intro-replacement mod: data flow, main pipeline, dependency detection, packaging, and the rules that must not be broken.

## 1. Overall architecture (data flow)

```
your-video.mp4
   │
   ├─[1] encode   radvideo64.exe bink2c /V6344  ──▶  video.bk2 (flags=0x40012)
   │
   ├─[2] audio    BinkExtractAudio.exe ──▶ audio.wav ──▶ WwiseConsole ──▶ audio.wem
   │
   └─[3] package  make-final-patch2.py ──▶ 9ba626afa44a3aa3.patch_0 + .patch_0.stream
                                            (= installable mod for game data\)
```

One asset is bundled in `assets\`: the base container `9ba626afa44a3aa3.patch_0` (a cleaned 7-entry skeleton).

The vanilla notice video `83cc35d311ee2648.stream` is **not** bundled - it is game data. `build-mod.ps1` rebuilds it from the player's own `data\bundles.*.nxa` on the first run (see §3.0).

## 2. Main pipeline (`build-mod.ps1`, 7 stages)

The script is an **orchestrator** — it never touches binary data itself; it calls the bundled tools in order, checking each stage:

| Stage | Trigger / where | Action |
|---|---|---|
| 0. input | `$Video` empty in the `param` block | pop an `OpenFileDialog`; exit if cancelled |
| 1. locate | `$Root = $PSScriptRoot` | every path is `Join-Path`-relative (location-independent - the folder can be moved anywhere) |
| 2. rebuild + scan | `[0]`, then `[1]`-`[5]` | `[0]` rebuilds the notice video from the player's game when it is absent; then built-in assets / radvideo64 / Python / audio / bink2w64.dll are checked, printing `[OK]` `[MISS]` `[SKIP]` per item |
| 3. block | when `$fatal` is non-empty | list what is missing → `Stop-Script 1` |
| 4. encode | `[1/4]` | run `encode.ps1` to produce `.bk2`, verify flags via `analyze-bink.ps1` |
| 5. audio | `[2/4]` | extract track → wav → wem (or use a `-Wem` file directly) |
| 6. package | `[3/4]` | run `make-final-patch2.py` to build `patch_N` + `.stream` |
| 7. verify | `[4/4]` | full-frame decode via `binktest.exe`, print output, `Stop-Script 0` |

> **This document deliberately quotes no line numbers** - the script is edited often and stale line numbers mislead more than they help. To find code, use the **stage markers** above (they match the `[1/4]`…`[4/4]` the script prints at runtime) or search for the function name.

**Key design**: every exit point goes through `Stop-Script` (defined near the top of the script) - it first deletes `%TEMP%\hd2_bink_work\` (the staged bink tools + commercial DLL), then `Read-Host` pause and `exit`, so the window never flashes away and no temp files are left behind.

## 3. Dependency detection

### 3.0 Vanilla notice video (checked first, not shipped)
`assets\83cc35d311ee2648.stream` (10.6 MB) is **game data and is not redistributed**. When it is missing, `build-mod.ps1` prints `[0] vanilla notice video (not bundled - rebuilding from your game)` and calls `tools\extract-vanilla.py`, which rebuilds it from the player's own `data\bundles.*.nxa`: read the package index inside `bundles.nxa` (a small DSAR archive) → find which `bundles.NN.nxa` holds the package and at what offset → walk the 0x20-byte chunk headers, decompressing each chunk → stitch the pieces back together. The output is byte-for-byte identical to what the game ships.

LZ4 decoding is a **built-in pure-Python implementation** (`_lz4_block_decompress`); when the optional `lz4` C module happens to be installed it is used for speed instead, and both produce identical bytes - so this step needs **no pip and no network**. Measured on the 10.6 MB payload: 0.79 s pure Python, 0.37 s with the C module.

### 3.1 Built-in assets (6 files)
`Test-Path` checks each: `base container`, `notice video`, `binktest.exe`, `BinkExtractAudio.exe`, `make-final-patch2.py`, `encode.ps1`. Missing = incomplete package (blocks).

### 3.2 radvideo64.exe (external, detect-only)
`Find-Radvideo64` searches in order: PATH → package root → `RADVideo\` → `tools\` → `C:\Program Files\RADVideo\` and `C:\Program Files\RAD Video Tools\` (plus x86).
> Note: the real install folder is **`RADVideo` (no space)**; only the older installer used `RAD Video Tools` (with a space) - so both spellings are searched.

### 3.3 Python (external, detect runtime)
`Find-Python`: tries `python`, `py`, verified with `--version`; falls back to common absolute paths (`%LOCALAPPDATA%\Python\bin\python.exe`, `C:\Python*\python.exe`, ...). Packing uses only stdlib - **lz4 is not required**.

### 3.4 WwiseConsole.exe (external, detect-only)
`Find-WwiseConsole` searches in order: `-Wwise` arg → `config.json` → bundled `Wwise\` → `C:\Audiokinetic`, `C:\Program Files\Audiokinetic` (recursive).

### 3.5 wproj project (bundled, detect-and-use)
`Find-Wproj`: `-Wproj` arg → `config.json` → recursive `*.wproj` under the package root. The bundled `wwise-project\intro-convert\intro-convert.wproj` is found automatically.

### 3.6 bink2w64.dll (commercial - **not shipped**, taken from the player's game)
`Find-Hd2GameDir` + `Find-BinkDll` search in order:

1. `-GameDir` argument (accepts the game root or its `bin\` folder)
2. the path remembered in `config.json` from a previous run
3. the Steam registry - `SteamPath` under `HKCU\Software\Valve\Steam`, or `InstallPath` under `HKLM\SOFTWARE\WOW6432Node\Valve\Steam` → that library's `steamapps\common\Helldivers 2`
4. every library listed in `steamapps\libraryfolders.vdf` (this is what catches a game installed on a non-default drive)
5. `GameDirectory` in `%LOCALAPPDATA%\Helldivers2ModManager\settings.json`
6. common paths across every fixed drive (`SteamLibrary`, `Steam`, `Program Files (x86)\Steam`, ...)

On a hit: `binktest.exe`, `BinkExtractAudio.exe` and `bink2w64.dll` are **copied into `%TEMP%\hd2_bink_work\`**, and every bink tool call is directed there - so neither the package folder nor the game folder is written to, and the folder is deleted when the run ends.

> **Why it is needed**: both `BinkExtractAudio.exe` (pulls the BINK audio track out of the `.bk2`) and `binktest.exe` (full-frame decode check) load `bink2w64.dll` by name. It is a commercial RAD Game Tools / Epic Games Tools, LLC DLL, so this project does **not** redistribute it. When it cannot be found you get a clear message, and `-Wem` still lets you supply a ready-made wem to skip audio extraction entirely.

Detected Wwise / wproj / game paths are written back to `config.json` (`Save-Cfg`) to speed up the next run.
> `config.json` is read **defensively**: any missing key falls back to a default. Earlier versions used the raw `ConvertFrom-Json` object as the config, so a file missing one key threw "property cannot be found on this object" while saving a newly detected path - fixed.

## 4. Packaging (3 binary layers)

### Layer 1: video encode (`tools\encode.ps1`)
- Locate radvideo64 → check paths are pure ASCII (radvideo64 uses ANSI; CJK paths hang it).
- Non-ASCII paths are copied to `%TEMP%\hd2_encode_tmp\`, encoded, copied back (transparent).
- The one correct command: `radvideo64.exe bink2c <in.mp4> <out.bk2> /V6344`.
- Output `.bk2` header flags **must be `0x40012`** (`0x40010` crashes the game; header-patching does not help).

### Layer 2: audio (`BinkExtractAudio.exe` + `WwiseConsole.exe`)
```
video.bk2 ──BinkExtractAudio──▶ audio.wav (PCM, pulled frame-by-frame from the BINK track)
audio.wav ──WwiseConsole convert-external-source──▶ audio.wem (Vorbis)
```
- The script writes `wsources.xml` on the fly (`build-mod.ps1:251`) with `Conversion="Vorbis Quality High"`.
- Runs `migrate` then `convert-external-source`; output `Windows\audio.wem`.
- Game audio = the WAV region at the start of the stream (wem), **not** the BINK track — that is why wem must be built first.

### Layer 3: container packaging (`tools\scripts\make-final-patch2.py`, the core)

**Inputs (4 files)**: `--wem` (audio), `--v2` (new video bk2), `--v1` (vanilla notice), `--base` (base container).

**Assertions**: `wem` starts with `RIFF`; `v1`/`v2` start with `KB2n` (BINK2 magic).

**Stream assembly**:
```
stream = wem + pad16 + v1(notice) + pad16 + v2(new video)
```
(`pad16` = 16-byte alignment; offsets must be multiples of 16.)

**9 fields updated in the base container**:

| Offset | Field | Meaning |
|---|---|---|
| `0x0104` | WAV size | audio segment size at stream start |
| `0x0308` | WAV size (copy) | redundant copy |
| `0x0130/0x0180/0x01D0/0x0220/0x0270` | video1 offset ref ×5 | where the notice lives in the stream |
| `0x0294` | video1 size | notice size |
| `0x02C0` | video2 offset | new video position |
| `0x02E4` | video2 size | new video size |

**Output + self-check**: writes `9ba626afa44a3aa3.patch_N` + `.patch_N.stream`, then re-reads and asserts those offsets (RIFF/KB2n magic + field values). Only when all pass does it print `OK all checks passed`.

## 5. Hard rules

1. **Video must be `bink2c /V6344`** (flags=0x40012) — the game's bundled bink2w64.dll only accepts this mode; `0x40010` crashes, and patching the header alone does not help.
2. **Audio is a Wwise Vorbis wem**, not the BINK track — the game plays the wem at the stream start via the Wwise engine.
3. **Patch numbers must be 0..N with no gaps** — a gap makes the game ignore the mod (`--num` defaults to 0).
4. **Any source resolution is accepted** — below 720p is rescaled to 1280x720, and anything above 1440p or 60fps is downscaled to 2560x1440 / 60fps (both passes need ffmpeg). Without ffmpeg the run is blocked instead of shipping a mod that shows corrupted video in game.
5. **CJK/non-ASCII paths** hang radvideo64 → `encode.ps1` forces an ASCII temp-dir hop.
6. **Commercial dependencies are never auto-installed** — radvideo64 and Wwise are detect-and-guide only; ffmpeg and the Python embeddable build can be fetched after the user confirms.
