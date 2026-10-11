# hd2-intro-modder

把一段 MP4 打包成《绝地潜兵 2》开场动画替换 mod（一条命令）。

## 环境依赖

| 依赖 | 自动? | 获取 |
|---|---|---|
| RAD Video Tools (radvideo64.exe) | 仅检测 | https://www.radgametools.com/bnkdown.htm |
| Python 3 | 仅检测 | https://www.python.org/downloads/ |
| **《绝地潜兵 2》本体**(提供 `bin\bink2w64.dll`,并用于重建原版告示视频) | **自动定位** | 你已经在玩这个游戏 :) |
| Wwise（仅换音频需要） | 仅检测 | https://www.audiokinetic.com/download/ |
| ffmpeg/ffprobe（仅重压/降级需要） | 仅检测 | https://ffmpeg.org/download.html |

内置（无需安装）：binktest 工具、封装脚本、基底容器 + 原版告示、Wwise Audio Conversion 项目（`wwise-project\`）。

> **为什么需要你的游戏**：把 `.bk2` 里的 BINK 音轨提取成 WAV（`BinkExtractAudio.exe`）、以及最后的全帧解码校验（`binktest.exe`），都要用 Bink 解码器 `bink2w64.dll`。那是 RAD Game Tools 的商业 DLL，**本项目不分发**，而是自动从你的游戏目录取（Steam 注册表 → 库文件夹 → 常见路径，也可用 `-GameDir` 指定），复制到临时目录用完即删。
> 找不到时会明确提示；此时仍可用 `-Wem` 传入现成 wem 跳过音频提取。
>
> **为什么首次运行会「重建告示视频」**：原版开场告示视频属于游戏数据，**本项目不分发**。首次运行时脚本会读取你游戏 `data\bundles.*.nxa` 里的包索引与数据块把它还原出来 —— 用**内置的纯 Python LZ4 解码器**，因此**不需要任何额外依赖、也不需要联网**。结果与游戏原版**逐字节相同**（SHA256 已实测一致）。文件已存在时整段跳过，不重复提取。

## 安装依赖

### RAD Video Tools（必需，免费）

1. 下载安装包：https://www.radgametools.com/bnkdown.htm 。
2. 安装位置二选一，脚本都能自动找到：
   - **默认路径安装**（推荐）：直接点下一步装完即可。脚本会扫描 `C:\Program Files\RADVideo\`（无空格）和 `C:\Program Files\RAD Video Tools\`（老安装器带空格）等常见位置；
   - **装进本项目**：把 `radvideo64.exe`（连同同目录的 dll）放到项目根目录或 `RADVideo\` 子目录，脚本优先扫描这两个位置。
3. 注意：RAD Video Tools 是商业软件，仅限本机使用，**不要**随本项目分发或上传 GitHub。

### Wwise（仅换音频时需要，免费，需注册账号）

> 不想装 Wwise？直接用 `-Wem 音频.wem` 参数提供现成 wem 文件即可完全跳过（见下方「使用」）。

1. 注册免费 Audiokinetic 账号：https://www.audiokinetic.com/ （页面右上角 Sign Up）。
2. 下载并安装 **Wwise Launcher**：https://www.audiokinetic.com/download/ ，登录。
3. Launcher → 「Install」页 → 选择版本 **2025.1.x**（2023.1.7 及以上均可，本工具在 2025.1.2 实测通过）→ 点 Install。
4. 安装路径保持默认 `C:\Audiokinetic`（脚本会递归扫描该目录）。若装在别处，首次运行用 `-Wwise <WwiseConsole.exe 路径>` 参数指定，脚本会记到 `config.json`。
5. 组件**只需勾选 Wwise Authoring**：SDK 和各平台组件都不需要——本工具只用命令行转换工具 `WwiseConsole.exe`，不装 SDK 更省磁盘。
6. 装完检查：`C:\Audiokinetic\Wwise<版本号>\Authoring\x64\Release\bin\WwiseConsole.exe` 存在即成功。

## 使用

### 图形界面（推荐，双击即用）

双击项目根目录的 **`hd2-intro-modder.exe`** —— 选视频、点「开始生成」即可，全过程日志在窗口内实时显示，也可以直接把 MP4 拖进窗口。

> - 它不重新实现流程，而是调用同一份 `build-mod.ps1`，所以两条入口的行为永远一致。
> - 源码在 `gui\Hd2IntroModderGui.cs`；需要重新编译时：`powershell -ExecutionPolicy Bypass -File gui\build-gui.ps1`（用系统自带 .NET Framework 的 csc，**无需安装任何 SDK**）。

### 命令行 / 脚本入口

```powershell
powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video 视频.mp4
```

```powershell
# patch 编号 1，打包 zip
powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video 视频.mp4 -Num 1 -Zip

# 跳过 Wwise：直接提供现成 .wem
powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video 视频.mp4 -Wem 音频.wem
```

> 也可直接右键 `build-mod.ps1` → 「使用 PowerShell 运行」，会自动弹窗选视频。

## 输出

`output\<视频名>\9ba626afa44a3aa3.patch_0` + `.patch_0.stream`

两个文件复制进 `Helldivers 2\data\`。patch 编号必须 0..N 连续无空洞。

## 注意

- 视频用 `bink2c /V6344` 编码（flags=0x40012），非 ASCII 路径已处理。
- 源视频自动适配：<720p 重压为 1280x720（否则游戏内花屏）；超过 **1440p 或 60fps** 的源一律压到上限 **2560x1440 / 60fps**（帧率跟随源——源只有 30fps 就保持 30fps）。这一步有 NVIDIA 显卡时自动用 **NVENC** 加速。
  - 参考：游戏原版开场动画是 `1280x720@30`，原版告示是 `3840x2160@30`，两者都在上述上限内。
  - 为什么要压：`bink2c` 编码耗时随「像素数 × 帧数」增长，且它**只能跑 CPU**（RAD 官方说明其压缩器为多线程 CPU 实现，无 GPU 通路）。4K/120fps 源会让编码时间放大到 30 分钟以上。
- 音频来自视频自带音轨（提取后转 Wwise Vorbis wem），或直接用你的 `-Wem`。
- 内置 Wwise 项目（`wwise-project\intro-convert`）可移植（零绝对路径），装 Wwise 即可用。
- `config.json` 记住非默认位置的 Wwise 路径。

## 故障反馈（报错怎么办）

遇到任何报错或失败，请收集以下信息后反馈（按重要性排序）：

1. **日志文件（最重要）**：每次运行都会生成 `log\build-mod-<日期时间>.log`（自动保留最近 20 份）。把**整个文件内容**贴出来即可。
2. **报错窗口截图**：脚本出错时会暂停等待按键、窗口不闪退，此时直接截图。
3. **视频信息**：文件名（是否含中文/空格）、分辨率（如 852x480 / 1920x1080）、编码格式（如 H.264 / HEVC）。
4. **运行方式**：右键「使用 PowerShell 运行」还是命令行？带了哪些参数（`-Wem` / `-Num` / `-Zip` 等）？
5. **环境信息**：Windows 版本、Python 版本、各依赖（RAD Video Tools / ffmpeg / Wwise）是否已装、装在哪个路径。
6. **项目来源**：从哪获取的本工具、获取日期。

> 反馈前建议先自查：运行窗口里的环境扫描结果是否有 `[MISS]` 项（缺的依赖会列出）。若有，先按「安装依赖」装齐再重跑。

## 许可证

本项目采用 **CC BY-NC 4.0**（署名 — 非商业性使用），作者 **XccQ114**。它是作者自己的 [HD2-Mod 开发套件](https://github.com/XccQ114/hd2-mod-dev-kit) 的衍生工具。**任何再分发（含修改版）都必须保留署名**，不得冒充原创。

⚠️ **`assets\` 里的两个文件是《绝地潜兵 2》的游戏数据**（基底容器 `9ba626afa44a3aa3.patch_0` + 原版告示视频 `83cc35d311ee2648.stream`），版权归 **Arrowhead Game Studios / Sony Interactive Entertainment**，**不适用 CC 许可**，仅供个人在你自己拥有该游戏的机器上使用，不得单独提取或再分发。

完整说明、第三方组件清单与免责声明见 [LICENSE](LICENSE)。

## 文档

- [全流程详解（中文）](docs/HOW-IT-WORKS-cn.md)
- [How it works (English)](docs/HOW-IT-WORKS.md)

---

# hd2-intro-modder

Turn a MP4 into a Helldivers 2 intro-replacement mod (one command).

## Requirements

| Need | Auto? | Get it |
|---|---|---|
| RAD Video Tools (radvideo64.exe) | detect only | https://www.radgametools.com/bnkdown.htm |
| Python 3 | detect only | https://www.python.org/downloads/ |
| **Helldivers 2 itself** (supplies `bin\bink2w64.dll`) | **auto-located** | you already own the game :) |
| Wwise (audio conversion only) | detect only | https://www.audiokinetic.com/download/ |
| ffmpeg/ffprobe (rescale / downscale only) | detect only | https://ffmpeg.org/download.html |

Built-in (no install): binktest tools, packager scripts, base container + notice video, and a Wwise Audio Conversion project (`wwise-project\`).

> **Why your game is needed**: pulling the BINK audio track out of the `.bk2` (`BinkExtractAudio.exe`) and the final full-frame decode check (`binktest.exe`) both need the Bink decoder `bink2w64.dll`. That is a commercial RAD Game Tools DLL, so **this project does not ship it** - the script locates the copy your game already installed (Steam registry → library folders → common paths, or `-GameDir`) and stages it in a temp folder that is deleted when the run ends.
> If it cannot be found you get a clear message, and you can still pass a ready-made wem with `-Wem` to skip audio extraction.

## Install dependencies

### RAD Video Tools (required, free)

1. Download the installer: https://www.radgametools.com/bnkdown.htm
2. Either location works - the script finds both:
   - **Default install** (recommended): just click through the installer. The script scans `C:\Program Files\RADVideo\` (no space) and `C:\Program Files\RAD Video Tools\` (old installer, with space) among others.
   - **Inside this project**: copy `radvideo64.exe` (with its DLLs) to the project root or into the `RADVideo\` subfolder - the script checks these locations first.
3. Note: RAD Video Tools is commercial software - keep it local, **do not** redistribute it with this project or upload it to GitHub.

### Wwise (only needed to convert audio, free, requires account)

> Don't want Wwise? Pass a ready-made wem with `-Wem audio.wem` to skip it entirely (see "Use" below).

1. Create a free Audiokinetic account: https://www.audiokinetic.com/ (Sign Up, top right).
2. Download and install **Wwise Launcher**: https://www.audiokinetic.com/download/ , then sign in.
3. In the Launcher open the **Install** tab, pick version **2025.1.x** (2023.1.7 or newer works; tested with 2025.1.2), click Install.
4. Keep the default install path `C:\Audiokinetic` (the script scans this folder recursively). If you install elsewhere, point the script at it once with `-Wwise <path to WwiseConsole.exe>`; the path is remembered in `config.json`.
5. Components: **only Wwise Authoring is needed** - no SDK or platform packages. This tool only uses the CLI converter `WwiseConsole.exe`, so skipping the SDK saves disk space.
6. Verify after install: `C:\Audiokinetic\Wwise<version>\Authoring\x64\Release\bin\WwiseConsole.exe` should exist.

## Use

### GUI (recommended - just double-click)

Double-click **`hd2-intro-modder.exe`** in the project root: pick a video, hit "Start", and the whole run streams into the window live. You can also drag an MP4 straight onto the window.

> - The GUI does not reimplement the pipeline - it drives the same `build-mod.ps1`, so both entry points always behave identically.
> - Source: `gui\Hd2IntroModderGui.cs`. Rebuild with `powershell -ExecutionPolicy Bypass -File gui\build-gui.ps1` (uses the csc bundled with the .NET Framework - **no SDK required**).

### Command line / script entry

```powershell
powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video video.mp4
```

```powershell
# patch number 1, zip the result
powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video video.mp4 -Num 1 -Zip

# skip Wwise: provide a ready-made .wem
powershell -ExecutionPolicy Bypass -File build-mod.ps1 -Video video.mp4 -Wem audio.wem
```

> Or right-click `build-mod.ps1` → "Run with PowerShell" to pick a file in a dialog.

## Output

`output\<name>\9ba626afa44a3aa3.patch_0` + `.patch_0.stream`

Copy both into `Helldivers 2\data\`. Patch numbers must be 0..N with no gaps.

## Notes

- Video is encoded with `bink2c /V6344` (flags=0x40012). Non-ASCII paths are handled.
- Source video is auto-adjusted: <720p is upscaled to 1280x720 (otherwise it corrupts in-game); anything above **1440p or 60fps** is capped to **2560x1440 / 60fps** (frame rate follows the source - a 30fps source stays 30fps). This pass uses **NVENC** automatically when an NVIDIA GPU is present.
  - For reference: the vanilla intro is `1280x720@30` and the vanilla notice is `3840x2160@30` - both sit inside those caps.
  - Why the cap: `bink2c` encode time scales with pixels x frames, and it is **CPU-only** (RAD documents the compressor as massively multi-threaded with no GPU path). A 4K/120fps source pushes encoding past 30 minutes.
- Audio comes from the video's own track (extracted, then Wwise Vorbis wem), or your `-Wem`.
- The bundled Wwise project (`wwise-project\intro-convert`) is portable (zero absolute paths) - works on any machine with Wwise installed.
- `config.json` remembers Wwise paths found in non-default locations.

## Troubleshooting / reporting bugs

If anything fails, please collect and report the following (most important first):

1. **The log file (most important)**: every run writes `log\build-mod-<timestamp>.log` (last 20 kept). Paste the **whole file**.
2. **Screenshot of the error window**: on errors the script pauses and keeps the window open - screenshot it.
3. **Video info**: file name (contains non-ASCII chars / spaces?), resolution (e.g. 852x480 / 1920x1080), codec (e.g. H.264 / HEVC).
4. **How you ran it**: right-click "Run with PowerShell" or command line? Which parameters (`-Wem` / `-Num` / `-Zip` ...)?
5. **Environment**: Windows version, Python version, whether RAD Video Tools / ffmpeg / Wwise are installed, and where.
6. **Source**: where you got this tool and when.

> Before reporting: check the environment scan in the run window for `[MISS]` lines - missing dependencies are listed there. Install them per "Install dependencies" and rerun.

## License

Licensed under **CC BY-NC 4.0** (Attribution-NonCommercial) by **XccQ114**. It is a derivative of the author's own [HD2-Mod Dev Kit](https://github.com/XccQ114/hd2-mod-dev-kit) - **any redistribution (including modified versions) must preserve the attribution.**

⚠️ The two files in `assets\` are derived from *Helldivers 2* game data (base container `9ba626afa44a3aa3.patch_0` + vanilla notice video `83cc35d311ee2648.stream`) and remain the property of **Arrowhead Game Studios / Sony Interactive Entertainment**. They are **not** covered by the CC license and are for personal use on a machine where you own the game only.

See [LICENSE](LICENSE) for the full text, the third-party component list and the disclaimer.

## Docs

- [How it works (English)](docs/HOW-IT-WORKS.md)
- [全流程详解（中文）](docs/HOW-IT-WORKS-cn.md)
