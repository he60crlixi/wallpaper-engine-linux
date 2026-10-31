# AGENT.md — 给自动化 agent 的执行指南

本文件面向 AI agent。人类请看 [README.md](README.md)。

## 任务目标

在 Linux 上让 Wallpaper Engine（Steam appid `431960`）能启动、能浏览壁纸库、
能看视频，并让界面里的「打开文件夹」「双击视频」调用主机的文件管理器和播放器。

## 能力边界（务必向用户说明）

| 功能 | 可行 |
|---|---|
| 启动、打开主界面 | ✅ |
| 浏览创意工坊、看预览 | ✅ |
| 「打开文件夹」弹主机文件管理器 | ✅ |
| 双击视频用主机播放器播放 | ✅ |
| **把壁纸应用到桌面** | ❌ **Wayland 下不可能** |

**不要向用户承诺壁纸能用。** WE 依赖 Windows DWM 桌面层，Wayland 没有该层
（XWayland 是 rootless），会卡在 `COMException`。这是原理性限制。

用户若需要动态壁纸，引导到原生方案：`swww` / `mpvpaper` / `hyprpaper`。

**不要**因为壁纸不能用就判定任务失败 —— 用户的实际诉求往往是「用 WE 浏览和看视频」。

## 关键约束

1. **不要**假设用户环境与本仓库作者一致。先跑诊断，再动手。
2. **不要**直接 `rm -rf` NTFS 上的 compatdata —— 里面含 Windows reparse point，
   删除会报 `Input/output error`。用 `mv` 改名挪开。
3. **不要**用 `regedit /S` 写注册表。Proton prefix 下它会**静默失败**
   （exit 0 但没写入）。直接追加到 `system.reg` 文本文件。
4. **不要**改 Proton 安装目录里的文件。只改 `compatdata/<appid>/pfx/` 内的副本。
5. 替换 `explorer.exe` 前**必须**用 `cp -P` 备份（原文件是符号链接）。

## 执行顺序

### 第 1 步：诊断

```bash
./scripts/diagnose.sh
```

读取输出，判断属于哪个问题：

| 诊断信号 | 问题 | 章节 |
|---|---|---|
| `compatdata` 在 `fuseblk`/`ntfs`/`ntfs3` | A：prefix 建不出来 | 问题 A |
| `dosdevices/c: 缺失或损坏` | A | 问题 A |
| `仍是原版 Wine explorer.exe` | B：不转发主机 | 问题 B |
| `ShellExecuteEx 失败` / `wine start` 全失败 | B（Wine 缺陷，改关联无效） | 问题 B |
| 有 `wallpaper64.exe` 但无 `wallpaperui.exe` | 卡在壁纸渲染 | 界面未显示 |
| `Wallpaper UI` 窗口存在但用户说看不见 | 平铺合成器挤压 | 界面未显示 |

### 第 2 步：修问题 A（prefix 文件系统）

仅当 prefix 位于 NTFS/FAT 时执行。

```bash
LIB=<游戏库路径>/steamapps
EXT4=$HOME/.local/share/Steam/steamapps   # 确认在 ext4 上
findmnt -no FSTYPE -T "$EXT4"             # 必须是 ext4/btrfs/xfs

mkdir -p "$EXT4/compatdata"
mv "$LIB/compatdata" "$LIB/compatdata_ntfs_old"   # 不删，只挪开
ln -sfn "$EXT4/compatdata" "$LIB/compatdata"
```

**注意**：`mv` 整个 compatdata 会影响该库所有游戏（它们的 prefix 同样不可用），
这是期望行为。旧目录留着，用户确认一切正常后可自行删除。

### 第 3 步：修问题 B（explorer 转发器）

```bash
sudo pacman -S mingw-w64-gcc          # 或对应发行版的 mingw 包
x86_64-w64-mingw32-gcc -O2 -o explorer.exe src/explorer.c

PREFIX="$LIB/compatdata/431960/pfx"
for d in "$PREFIX/drive_c/windows" "$PREFIX/drive_c/windows/system32"; do
    [ -e "$d/explorer.exe.wine-orig" ] || cp -P "$d/explorer.exe" "$d/explorer.exe.wine-orig"
    rm -f "$d/explorer.exe"
    cp explorer.exe "$d/explorer.exe"
done
```

### 第 4 步：写注册表关联

追加到 `$PREFIX/system.reg`（**不要**用 regedit）：

```bash
cat >> "$PREFIX/system.reg" <<'EOF'

[Software\\Classes\\mp4file\\shell\\open\\command] 1700000000
#time=1dd67daeaa56f7a
@="\"C:\\windows\\system32\\winebrowser.exe\" \"%1\""

[Software\\Classes\\.mp4] 1700000000
#time=1dd67daeaa56f7a
@="mp4file"
"Content Type"="video/mp4"
"PerceivedType"="video"
EOF
```

`system.reg` 是文本格式，Wine 启动时读取。时间戳字段（`1700000000`）随意但必须存在。

### 第 5 步：验证

```bash
WINEPREFIX="$PREFIX" wineserver -k    # 强制重载注册表

# 启动 WE 后，在界面点「打开文件夹」，然后：
cat "$PREFIX/drive_c/explorer-fwd.log"
```

期望看到 `CreateProcess=1 err=0`，且主机弹出文件管理器。

## 常见失败模式

### `wine start` 对任何路径都失败

```
ShellExecuteEx
[exit: 1]
```

连 `notepad.exe` 都启动不了 → Wine 的 `ShellExecuteExW` 在该 prefix 下整体失效。
**这不是配置问题**，改注册表无效。必须走替换 `explorer.exe` 的路线。

### 替换 explorer.exe 后出现 `ShellExecuteEx 失败: 找不到文件`

Wine 内部某些操作依赖真正的 explorer。若出现此错误：

1. 确认 `explorer.exe.wine-orig` 存在且是**符号链接**（`cp -P` 保留）
2. 还原：`cp -P explorer.exe.wine-orig explorer.exe`
3. 检查转发器是否至少能独立运行：
   ```bash
   WINEPREFIX="$PREFIX" wine 'C:\windows\system32\explorer.exe' '/n,/select,Z:\some\path'
   ```

### 转发器日志显示 `target=(empty)`

参数解析失败。Wallpaper Engine 把 `/n,/select,<path>` 作为**单个参数**传入，
不是拆开的。解析器必须在整串里 `strstr("/select,")`，不能只检查 argv[0]。

### 界面启动但用户看不到

平铺合成器（niri/sway/Hyprland）把窗口挤到屏幕外。检查：

```bash
niri msg windows | grep -A6 'Wallpaper UI'
```

若 `Is floating: no`，让它浮动：

```bash
niri msg action move-window-to-floating --id <id>
```

长期方案是在合成器配置里加窗口规则（见 README）。

### 进程活着但 Steam 显示异常

```bash
pkill -x wallpaper64.exe
WINEPREFIX="$PREFIX" wineserver -k
```

## 不要做的事

- 不要试图让壁纸渲染在 Wayland 下工作。WE 依赖 Windows DWM 桌面层，
  XWayland 是 rootless 模式，没有该层。会卡在 `COMException`。界面能用就够了。
- 不要建议用户格式化 NTFS 分区。双系统共用盘必须保留 NTFS。
- 不要安装 `keyd` 之类无关工具。
- 不要在用户没要求时改动其他游戏的 prefix。

## 已验证环境

Arch Linux / kernel 7.2.11 / niri 26.04 (Wayland) / NVIDIA 615.78.08 /
Proton Experimental 11.0 / 游戏库在 NTFS，prefix 在 ext4 / WE build 20000800000042
