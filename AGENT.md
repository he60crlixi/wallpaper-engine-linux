# AGENT.md — 给自动化 agent 的执行指南

本文件面向 AI agent。人类请看 [README.md](README.md)。

## 任务识别

先判断用户要什么，两条路线完全不同：

| 用户诉求 | 路线 | 文档 |
|---|---|---|
| 「壁纸显示不出来」「桌面没有壁纸」 | **A：原生渲染** | [docs/NIRI-WALLPAPER.md](docs/NIRI-WALLPAPER.md) |
| 「WE 启动不了」「点了没反应」「打不开文件夹」 | **B：Wine 修复** | 本文件下方 |
| 「想用 WE 界面管理创意工坊」 | B | 本文件下方 |

**关键**：如果用户抱怨壁纸不显示，**不要**尝试修复 Wine 里的 WE——
原理上做不到。直接引导到路线 A。

## 路线 A：原生渲染壁纸（最快见效）

### 一句话方案

```bash
yay -S linux-wallpaperengine-git

linux-wallpaperengine \
  --assets-dir <WE游戏目录>/assets \
  --screen-root <显示器名> \
  --layer background \
  --bg <创意工坊>/<壁纸ID> \
  --silent --fps 30 --hwdec no
```

### 三个必踩的坑

1. **`--assets-dir` 必须给**
   默认找 `/opt/linux-wallpaperengine/assets`，Steam 版在游戏目录里。不给就启动即退出。

2. **`--layer background` 必须给**
   默认 `bottom` 层，在 niri 上会被克隆到每个工作区，总览界面里一片重复。
   配合 niri 的 `layer-rule { place-within-backdrop true }`。

3. **`--hwdec no` 通常必须给**
   壁纸在 NTFS 上时硬解会报：
   ```
   filesystem error: The specified mount cannot be handled by
   any of the filesystem adapters
   ```
   这是 ntfs-3g 的限制，不是配置问题。

### 不要装 niri-wallpaperengine-git

那个包的 niri 补丁已经过期，构建必失败：

```
patch unexpectedly ends in middle of line
Hunk #1 FAILED at 116.
```

用上游 `linux-wallpaperengine-git`，它已内置 layer-shell 支持。

### 路径探测

```bash
WE_DIR=$(find /mnt "$HOME/.local/share/Steam" -maxdepth 6 \
         -type d -name wallpaper_engine 2>/dev/null | head -1)
ASSETS="$WE_DIR/assets"
WORKSHOP=$(dirname "$(dirname "$WE_DIR")")/workshop/content/431960
OUTPUT=$(niri msg outputs | grep -oP '\(\K[^)]+(?=\)$)' | head -1)
```

### 验证成功

```bash
niri msg layers | grep -A2 linux-wallpaperengine
```

期望：

```
Background layer:
    Surface:
      Namespace: "linux-wallpaperengine"
```

日志里应有 `VO: [libmpv] WxH ...` 表示解码成功。

### 选壁纸：优先 scene

```bash
jq -r '.type' "$WORKSHOP/<id>/project.json"
```

| 类型 | 单核 CPU | 建议 |
|---|---|---|
| `scene` | 3-10% | **首选** |
| `video` | 90-95%（软解） | 能接受再用 |

## 路线 B：Wine 修复

### 执行顺序

```bash
./scripts/diagnose.sh          # 先诊断
./scripts/install.sh           # 再修
```

### 问题 B1：prefix 在 NTFS 上

诊断信号：`compatdata` 在 `fuseblk`/`ntfs`/`ntfs3` 上，
或 `dosdevices/c: 缺失或损坏`。

```bash
LIB=<库>/steamapps
EXT4=$HOME/.local/share/Steam/steamapps   # 确认 ext4
mkdir -p "$EXT4/compatdata"
mv "$LIB/compatdata" "$LIB/compatdata_ntfs_old"   # 不删，只挪
ln -sfn "$EXT4/compatdata" "$LIB/compatdata"
```

### 问题 B2：explorer.exe 不转发

诊断信号：`仍是原版 Wine explorer.exe`，或 `wine start` 对任何路径都失败。

```bash
sudo pacman -S mingw-w64-gcc
x86_64-w64-mingw32-gcc -O2 -o explorer.exe src/explorer.c

PREFIX="$LIB/compatdata/431960/pfx"
for d in "$PREFIX/drive_c/windows" "$PREFIX/drive_c/windows/system32"; do
    [ -e "$d/explorer.exe.wine-orig" ] || cp -P "$d/explorer.exe" "$d/explorer.exe.wine-orig"
    rm -f "$d/explorer.exe"
    cp explorer.exe "$d/explorer.exe"
done
WINEPREFIX="$PREFIX" wineserver -k
```

## 关键约束（两条路线都适用）

1. **不要**假设用户环境与作者一致。先跑诊断，再动手。
2. **不要**直接 `rm -rf` NTFS 上的 compatdata —— 含 Windows reparse point，
   删除报 `Input/output error`。用 `mv` 改名挪开。
3. **不要**用 `regedit /S` 写注册表。Proton prefix 下会**静默失败**
   （exit 0 但没写入）。直接追加到 `system.reg`。
4. **不要**改 Proton 安装目录里的文件。只改 `compatdata/<appid>/pfx/` 内的副本。
5. 替换 `explorer.exe` 前**必须**用 `cp -P` 备份（原文件是符号链接）。
6. **不要**建议用户换 X11 来让壁纸工作 —— X11 同样没有 `Progman`，一样不行。
7. **不要**用 `pkill -f linux-wallpaperengine` 管理壁纸进程 —— 会匹配到自己的
   命令行导致自杀。用 `ps -eo pid,args | grep -F` 精确定位。

## 常见失败模式

### 壁纸进程在跑但屏幕没变化

```bash
niri msg layers | grep linux-wallpaperengine
```

- 无输出 → 少了 `--layer background`，或显示器名错
- 有输出但看不见 → 检查 niri `layer-rule`，可能被其他 surface 盖住

### 总览界面里壁纸重复

少了 `--layer background` 或没配 `place-within-backdrop`。

### 硬解失败

```
Device does not support the VK_KHR_video_decode_queue extension!
CUDA_ERROR_OUT_OF_MEMORY
```

→ `--hwdec no`。若壁纸在 NTFS 上，硬解本来不可用。

### `wine start` 对任何路径都失败

```
ShellExecuteEx
[exit: 1]
```

连 `notepad.exe` 都启动不了 → Wine 的 `ShellExecuteExW` 整体失效。
**不是配置问题**，改注册表无效。必须替换 `explorer.exe`。

### 转发器日志显示 `target=(empty)`

参数解析失败。WE 把 `/n,/select,<path>` 作为**单个参数**传入，不是拆开的。
解析器必须在整串里 `strstr("/select,")`。

### 界面启动但用户看不到

平铺合成器把窗口挤到屏幕外：

```bash
niri msg windows | grep -A6 'Wallpaper UI'
```

若 `Is floating: no`：

```bash
niri msg action move-window-to-floating --id <id>
```

## 不要做的事

- 不要试图让壁纸在原版 WE（Wine）里工作。原理上不可能。
- 不要建议用户格式化 NTFS 分区。双系统共用盘必须保留。
- 不要安装 `keyd` 之类无关工具。
- 不要在用户没要求时改动其他游戏的 prefix。
- 不要向用户承诺「完整适配」。两条路线各有边界，说清楚。

## 已验证环境

Arch Linux / kernel 7.2.11 / niri 26.04 (Wayland) / NVIDIA 615.78.08 /
Proton Experimental 11.0 / 游戏库在 NTFS，prefix 在 ext4 /
WE build 20000800000042 / linux-wallpaperengine r643.a0ddce58
