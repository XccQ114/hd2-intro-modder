# HD2 intro modder — 全流程详解（中文）

> 本文说明 `hd2-intro-modder` 如何把一段 MP4 打包成《绝地潜兵 2》开场动画替换 mod：数据流、主流程、依赖检测、打包封装，以及必须遵守的约束。

## 一、总体架构（数据流）

```
你的视频.mp4
   │
   ├─[1] 视频编码  radvideo64.exe bink2c /V6344  ──▶  video.bk2（flags=0x40012）
   │
   ├─[2] 音频      BinkExtractAudio.exe ──▶ audio.wav ──▶ WwiseConsole ──▶ audio.wem
   │
   └─[3] 封装      make-final-patch2.py ──▶ 9ba626afa44a3aa3.patch_0 + .patch_0.stream
                                              （= 可直接装进游戏 data\ 的 mod）
```

三件固定素材（内置在 `assets\`）：基底容器 `9ba626afa44a3aa3.patch_0`（清洗版）+ 原版告示 `83cc35d311ee2648.stream`。

## 二、主流程（`build-mod.ps1`，7 个阶段）

脚本是**编排器**，自己不碰二进制，只按顺序调用内置工具，每个阶段都有 exit 检查：

| 阶段 | 触发 / 位置 | 动作 |
|---|---|---|
| 0. 取输入 | `param` 段的 `$Video` 为空时 | 弹 `OpenFileDialog` 选 mp4；取消则退出 |
| 1. 定位 | `$Root = $PSScriptRoot` | 所有路径 `Join-Path` 相对定位（**位置无关**，包可以搬到任何地方） |
| 2. 重建+扫描 | 先 `[0]` 再 `[1]`–`[5]` | `[0]` 在告示视频缺失时从玩家游戏里重建；随后检测内置资产 / radvideo64 / Python / 音频 / bink2w64.dll，逐项打印 `[OK]` `[MISS]` `[SKIP]` |
| 3. 硬阻断 | `$fatal` 非空时 | 列出缺失清单 → `Stop-Script 1`（暂停后退出） |
| 4. 编码 | `[1/4]` | 调 `encode.ps1` 出 `.bk2`，再用 `analyze-bink.ps1` 校验 flags |
| 5. 音频 | `[2/4]` | 提音轨 → wav → wem（或直接用 `-Wem` 传入的现成 wem） |
| 6. 封装 | `[3/4]` | 调 `make-final-patch2.py` 拼出 `patch_N` + `.stream` |
| 7. 验证+输出 | `[4/4]` | `binktest.exe` 全帧解码验证，打印产物路径，`Stop-Script 0` 暂停 |

> **本文不写死行号** —— 脚本每改一次行号就会漂移，写行号只会误导后来的人。要定位代码请用上表的**阶段标记**（与脚本运行时打印的 `[1/4]`…`[4/4]` 一一对应），或直接搜函数名。

**关键设计**：每个结束点都走 `Stop-Script`（定义在脚本开头）—— 它先清掉 `%TEMP%\hd2_bink_work\`（暂存的 bink 工具 + 商业 DLL），再 `Read-Host` 暂停、`exit`，保证窗口不闪退、临时文件不残留。

## 三、依赖检测

> **关于原版告示视频（最先执行的一步）**：`assets\83cc35d311ee2648.stream`（10.6 MB）是**游戏数据，不随包分发**。首次运行时 `build-mod.ps1` 会打印 `[0] vanilla notice video (not bundled - rebuilding from your game)`，并调用 `tools\extract-vanilla.py` 从玩家自己的 `data\bundles.*.nxa` 把它重建出来：读 `bundles.nxa`（DSAR 小压缩包）里的包索引 → 定位该包落在哪个 `bundles.NN.nxa`、什么偏移 → 按 0x20 字节 chunk 头逐块读取并解压 → 拼接还原。结果与游戏原版**逐字节相同**。文件已存在时整段跳过，不重复提取。
>
> LZ4 解码是**内置的纯 Python 实现**（`_lz4_block_decompress`）：环境里恰好装了 `lz4` C 模块时会自动改用它加速，两者输出逐字节相同 —— 所以这一步**不需要 pip、不需要联网**。实测：纯 Python 解码 0.79 秒，C 模块 0.37 秒。

### 1. 内置资产（6 个文件，随包自带）
`Test-Path` 逐个检查：`base container`、`notice video`、`binktest.exe`、`BinkExtractAudio.exe`、`make-final-patch2.py`、`encode.ps1`。缺失 = 包不完整（阻断）。

### 2. radvideo64.exe（外部，只检测不自动装）
`Find-Radvideo64` 按序找：PATH → 包根 → `RADVideo\` → `tools\` → `C:\Program Files\RADVideo\` 与 `C:\Program Files\RAD Video Tools\`（含 x86）。
> 注意：实际安装目录是 **`RADVideo`（无空格）**，只有老安装器才用 `RAD Video Tools`（有空格）—— 两个名字都扫。

### 3. Python（外部，检测运行时）
`Find-Python`：依次试 `python`、`py`，用 `--version` 验证；都不可用时扫常见绝对路径（`%LOCALAPPDATA%\Python\bin\python.exe`、`C:\Python*\python.exe` 等）。封装只用标准库，**不需要 lz4**。

### 4. WwiseConsole.exe（外部，只检测不自动装）
`Find-WwiseConsole` 按序找：`-Wwise` 参数 → `config.json` → 包内 `Wwise\` → `C:\Audiokinetic`、`C:\Program Files\Audiokinetic`（递归找 `WwiseConsole.exe`）。

### 5. wproj 项目（已内置，检测到即用）
`Find-Wproj` 按序找：`-Wproj` 参数 → `config.json` → 包根递归 `*.wproj`。内置的 `wwise-project\intro-convert\intro-convert.wproj` 会被自动命中。

### 6. bink2w64.dll（商业 DLL，**不随包分发**，从玩家游戏里取）
`Find-Hd2GameDir` + `Find-BinkDll` 按序找：

1. `-GameDir` 参数（游戏根目录或它的 `bin\` 目录都接受）
2. `config.json` 里记住的上次结果
3. Steam 注册表 —— `HKCU\Software\Valve\Steam` 的 `SteamPath`，或 `HKLM\SOFTWARE\WOW6432Node\Valve\Steam` 的 `InstallPath` → 该库的 `steamapps\common\Helldivers 2`
4. `steamapps\libraryfolders.vdf` 里登记的全部库（游戏装在非默认盘时靠这条命中）
5. `%LOCALAPPDATA%\Helldivers2ModManager\settings.json` 的 `GameDirectory`
6. 所有固定磁盘上的常见路径（`SteamLibrary`、`Steam`、`Program Files (x86)\Steam` …）

命中后：把 `binktest.exe`、`BinkExtractAudio.exe`、`bink2w64.dll` **三个文件复制到 `%TEMP%\hd2_bink_work\`**，此后所有 bink 工具调用都指向那里 —— 包目录与游戏目录都不被写入，脚本退出时该目录被删除。

> **为什么需要它**：`BinkExtractAudio.exe`（把 `.bk2` 里的 BINK 音轨提成 wav）和 `binktest.exe`（全帧解码校验）都按名加载 `bink2w64.dll`。它是 RAD Game Tools / Epic Games Tools, LLC 的商业 DLL，所以本项目**不分发**。找不到时打印明确提示，并且仍可用 `-Wem` 传入现成 wem 绕过音频提取。

检测到的 Wwise / wproj / 游戏目录写回 `config.json`（`Save-Cfg`），下次更快。
> `config.json` 的读取是**容错**的：缺哪个键就补默认值。早期版本直接拿 `ConvertFrom-Json` 的结果当配置对象，一旦文件里少一个键，保存新路径时就会抛 "property cannot be found on this object" —— 已修。

## 四、打包封装（三层二进制操作）

### 第 1 层：视频编码（`tools\encode.ps1`）
- 定位 radvideo64 → 检测路径是否纯 ASCII（radvideo64 内部用 ANSI，中文路径会卡死）。
- 非 ASCII 复制到 `%TEMP%\hd2_encode_tmp\` 中转，编码后拷回（透明）。
- 唯一正确命令：`radvideo64.exe bink2c <in.mp4> <out.bk2> /V6344`。
- 产物 `.bk2` 头 flags **必须 `0x40012`**（`0x40010` 游戏崩溃，改头无效）。

### 第 2 层：音频（`BinkExtractAudio.exe` + `WwiseConsole.exe`）
```
video.bk2 ──BinkExtractAudio──▶ audio.wav（PCM，逐帧拉 BINK 音轨）
audio.wav ──WwiseConsole convert-external-source──▶ audio.wem（Vorbis）
```
- 脚本动态生成 `wsources.xml`（`build-mod.ps1:251`），指定 `Conversion="Vorbis Quality High"`。
- 先 `migrate` 再 `convert-external-source`，产物 `Windows\audio.wem`。
- 游戏音频 = stream 开头 WAV 区（wem），**不是** BINK 音轨，故必须先提 wem。

### 第 3 层：容器封装（`tools\scripts\make-final-patch2.py`，核心）

**输入**（4 个文件）：`--wem`（音频）、`--v2`（新视频 bk2）、`--v1`（原版告示）、`--base`（基底容器）。

**前置断言**：`wem` 头 = `RIFF`；`v1`/`v2` 头 = `KB2n`（BINK2 魔数），否则报错。

**stream 拼装**：
```
stream = wem + pad16 + v1(告示) + pad16 + v2(新视频)
```
（`pad16` = 16 字节对齐，偏移必须是 16 的倍数。）

**更新基底容器 9 个字段**：

| 偏移 | 字段 | 含义 |
|---|---|---|
| `0x0104` | WAV 长度 | stream 开头音频段大小 |
| `0x0308` | WAV 长度副本 | 冗余副本 |
| `0x0130/0x0180/0x01D0/0x0220/0x0270` | 视频1偏移引用 ×5 | 告示在 stream 里的位置 |
| `0x0294` | 视频1 size | 告示大小 |
| `0x02C0` | 视频2偏移 | 新视频位置 |
| `0x02E4` | 视频2 size | 新视频大小 |

**输出 + 自校验**：写出 `9ba626afa44a3aa3.patch_N` + `.patch_N.stream`，然后回读这些偏移断言（RIFF/KB2n 魔数 + 字段值），全过才打印 `OK all checks passed`。

## 五、关键铁律

1. **视频必须 `bink2c /V6344`**（flags=0x40012）——游戏内置 bink2w64.dll 只认此模式；`0x40010` 崩溃，改头无效。
2. **音频走 Wwise Vorbis wem**，不是 BINK 音轨——游戏用 Wwise 引擎播 stream 开头 wem。
3. **patch 编号 0..N 连续无空洞**——有空洞游戏不读该 mod（`--num` 默认 0）。
4. **源视频不限分辨率**——低于 720p 会自动重压到 1280x720，超过 1440p 或 60fps 会自动降级到 2560x1440 / 60fps（两步都需要 ffmpeg）。缺 ffmpeg 时直接阻断，绝不输出游戏内花屏的成品。
5. **中文/非 ASCII 路径**会卡死 radvideo64 → `encode.ps1` 强制 ASCII 中转。
6. **不自动装商业依赖**——radvideo64 与 Wwise 只「检测 + 引导」，ffmpeg 与 Python 免安装版可在用户确认后代下载。
