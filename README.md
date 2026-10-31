# Wallpaper Engine on Linux

在 Linux 上把 Wallpaper Engine 用起来。**两条独立的路线**，按你的需求选：

| 路线 | 能做什么 | 不能做什么 | 文档 |
|---|---|---|---|
| **A. 原生渲染**（推荐） | **真正显示壁纸到桌面**、读创意工坊素材 | 不能用 WE 界面 | [docs/NIRI-WALLPAPER.md](docs/NIRI-WALLPAPER.md) |
| **B. Wine 跑原版** | 用 WE 界面浏览、看视频、打开文件夹 | 壁纸显示不出来 | 本文件 |

**想要壁纸 → 看路线 A。想用 WE 界面 → 看路线 B。两者可以同时用。**

面向人类阅读，也面向 agent 自动化执行（见 [AGENT.md](AGENT.md)）。

---

## 先搞清楚：为什么原版 WE 显示不了壁纸

这是很多人卡住的地方，先说清楚，省得你白折腾。

Wallpaper Engine 把壁纸"贴到桌面"的实现是：

```c
HWND progman = FindWindowW(L"Progman", NULL);
HWND workerw = FindWindowExW(progman, NULL, L"WorkerW", NULL);
SetParent(myRenderWindow, workerw);   // 我的窗口变成壁纸
```

它依赖 Windows 独有的 `Progman` / `WorkerW` 窗口层级。

- **Wayland**：没有这套层级
- **X11**：**同样没有**（这是 Windows 独有的，不是 X11/Wayland 之争）

所以在 Wine 里跑 WE，壁纸永远出不来，会卡在初始化抛 `COMException`。
**换 X11 也一样不行**，别浪费时间。

正确做法是用原生项目 [`linux-wallpaperengine`](https://github.com/Almamu/linux-wallpaperengine)
自己解析 WE 的壁纸格式，渲染到 Wayland 的 `background` layer。

详见 **[docs/NIRI-WALLPAPER.md](docs/NIRI-WALLPAPER.md)**。

---

## 路线 A：原生渲染壁纸

一句话：

```bash
yay -S linux-wallpaperengine-git

linux-wallpaperengine \
  --assets-dir /path/to/wallpaper_engine/assets \
  --screen-root eDP-2 \
  --layer background \
  --bg /path/to/workshop/content/431960/<壁纸ID> \
  --silent --fps 30 --hwdec no
```

**完整教程**（含原理、参数详解、开机自启、排查）：
👉 **[docs/NIRI-WALLPAPER.md](docs/NIRI-WALLPAPER.md)**

配套脚本 [`scripts/we-wallpaper`](scripts/we-wallpaper) 提供列表/切换/随机功能：

```bash
we-wallpaper            # 列出所有壁纸
we-wallpaper 2981249186 # 切换
we-wallpaper next       # 随机
```

---

## 路线 B：Wine 跑原版 WE

解决的是**两个独立故障**。

### 问题 B1：启动即崩溃 / 卡在「正在运行」但没窗口

**症状**

- Steam 显示「正在运行」，几秒后自己退出
- 或者进程活着但永远看不到界面
- 手动用 Proton 启动会看到：

```
OSError: [Errno 22] Invalid argument:
  '../drive_c' -> '.../pfx/dosdevices/c:'
```

**原因**

Wine/Proton 建 prefix 时**必须**创建 `dosdevices/c:` 这类名字含冒号的符号链接。

如果 Steam 库放在 **NTFS** 分区（双系统共用盘最常见），Linux 的 `ntfs-3g`
驱动不允许文件名包含冒号（冒号在 NTFS 里是备用数据流分隔符），创建直接返回 `EINVAL`。

prefix 建不出来 → Proton 中止 → 游戏根本没起来。

**这不是硬盘坏了。** 是文件系统格式限制。

**修复**

把 `compatdata`（只有几百 MB）放到 Linux 原生分区，游戏本体继续留在 NTFS：

```bash
LIB=/mnt/data/SteamLibrary/steamapps          # 你的 NTFS 库
EXT4=$HOME/.local/share/Steam/steamapps       # 必须在 ext4/btrfs/xfs 上

mkdir -p "$EXT4/compatdata"
mv "$LIB/compatdata" "$LIB/compatdata_ntfs_old"   # 不要 rm，NTFS 上删不干净
ln -sfn "$EXT4/compatdata" "$LIB/compatdata"
```

> 为什么用 `mv` 而不是 `rm -rf`：NTFS 上的 prefix 含 Windows reparse point，
> `rm` 会报 `输入/输出错误` 删不掉。整个目录改名挪开最省事。

### 问题 B2：点「打开文件夹」没反应，双击视频打不开

**症状**

- 在 WE 界面里点「在资源管理器中打开」，什么都不发生
- 双击壁纸的视频文件，没有播放器启动
- **没有任何报错**（这点很关键）

**原因**

WE 内部实现是：

```
ShellExecuteExW("explorer.exe", "/n,/select,<path>")
```

它**直接启动 Wine 自带的 `explorer.exe`**，走 Wine 内部路径，
**完全不经过系统文件关联**。所以把 `.mp4` 关联到 `winebrowser` 也没用——根本没被调用到。

而 Wine 的 `explorer.exe` 只会打开它自己那个简陋窗口，不转发到主机的 nautilus/mpv。

另外 WE 调用时带了 `SEE_MASK_FLAG_NO_UI`，把错误提示抑制了，
所以表现为「点了没反应」。

**修复**

用一个自己编译的 `explorer.exe` 替换 prefix 里的原版。它解析 `/n,/select,<path>`，
把路径交给 `winebrowser.exe` → `xdg-open` → 主机的默认程序。

见 [`src/explorer.c`](src/explorer.c)。

---

## 快速开始（路线 B）

```bash
git clone https://github.com/he60crlixi/wallpaper-engine-linux
cd wallpaper-engine-linux
./scripts/diagnose.sh --dry-run   # 先看环境
./scripts/install.sh              # 修复 B1 + B2
```

脚本会：

1. 检测 prefix 所在文件系统，NTFS 上提示并可选迁移
2. 用 `mingw-w64` 编译转发器
3. 备份并替换 `explorer.exe`
4. 写入视频/文件夹关联注册表
5. 输出验证方法

还原：

```bash
./scripts/install.sh --uninstall
```

---

## 手动步骤（路线 B）

### 依赖

```bash
# Arch
sudo pacman -S mingw-w64-gcc

# Debian/Ubuntu
sudo apt install gcc-mingw-w64-x86-64

# Fedora
sudo dnf install mingw64-gcc
```

### 编译与部署

```bash
APPID=431960
LIB=/mnt/data/SteamLibrary/steamapps
PREFIX="$LIB/compatdata/$APPID/pfx"

# 1. 编译
x86_64-w64-mingw32-gcc -O2 -o explorer.exe src/explorer.c

# 2. 备份原文件（它是指向 Proton 目录的符号链接，用 cp -P 保留链接）
cp -P "$PREFIX/drive_c/windows/system32/explorer.exe" \
      "$PREFIX/drive_c/windows/system32/explorer.exe.wine-orig"

# 3. 替换（两个位置都要）
cp explorer.exe "$PREFIX/drive_c/windows/system32/explorer.exe"
cp explorer.exe "$PREFIX/drive_c/windows/explorer.exe"

# 4. 关掉 wineserver 让它重新加载
WINEPREFIX="$PREFIX" wineserver -k
```

---

## 验证（路线 B）

### 转发器是否被调用

启动 WE，在界面里点「打开文件夹」，然后：

```bash
cat "$PREFIX/drive_c/explorer-fwd.log"
```

正常输出：

```
[fwd] start argc=2
[fwd] arg[1]=/n,/select,Z:\mnt\data\...\workshop\content\431960\3370793692
[fwd] target=Z:\mnt\data\...\3370793692
[fwd] cmd="C:\windows\system32\winebrowser.exe" "..."
[fwd] CreateProcess=1 err=0
```

`CreateProcess=1 err=0` 表示转发成功，主机应该弹出了文件管理器。

### 手动测试转发器

```bash
export WINEPREFIX="$PREFIX"
wine "$PREFIX/drive_c/windows/system32/explorer.exe" \
     '/n,/select,Z:\path\to\some\file.mp4'
```

---

## 排查（路线 B）

### 界面启动后看不见窗口

平铺式合成器（niri/sway/Hyprland）会把新窗口挤进平铺布局，WE 的窗口可能被压到屏幕外。

niri 里加窗口规则让它浮动：

```kdl
// ~/.config/niri/config.kdl
window-rule {
    match app-id="steam_app_431960"
    open-floating true
    default-column-width { proportion 0.6; }
}
```

或者先切到空工作区再启动。

### Steam 显示「正在运行」但进程已经死了

残留进程会让 Steam 误判：

```bash
pkill -x wallpaper64.exe
WINEPREFIX="$PREFIX" wineserver -k
```

### 修改注册表后没生效

`regedit /S` 在 Proton 的 prefix 里会**静默失败**，不报错但也没写进去。
直接追加到 `system.reg` 文本文件更可靠（脚本用的就是这个方式）：

```bash
grep -a "mp4file" "$PREFIX/system.reg"
```

### `wine start` 报 `ShellExecuteEx 失败`

Wine 的 `ShellExecuteExW` 在部分 prefix 下整体失效（连 `notepad.exe` 都启动不了）。
这是 Wine 自身的问题，改注册表绕不过去——这也是为什么要替换 `explorer.exe`
而不是只改关联。

---

## 两条路线对比

| | A. linux-wallpaperengine | B. Wine 原版 WE |
|---|---|---|
| **显示壁纸** | ✅ | ❌ |
| 用 WE 界面浏览 | ❌ | ✅ |
| 看创意工坊视频 | 播放器打开 | WE 内预览 |
| 点「打开文件夹」 | 不适用 | ✅（修好后） |
| 订阅/管理创意工坊 | ❌（去 WE 或网页） | ✅ |
| CPU（scene 壁纸） | 3-10% 单核 | — |
| CPU（video 壁纸） | 90%+ 单核（软解） | — |
| 需要 Proton | ❌ | ✅ |
| 需要 Wine prefix | ❌ | ✅ |

**推荐组合**：A 常驻显示壁纸，需要管理创意工坊时开 B。

---

## 已验证环境

| 项 | 版本 |
|---|---|
| 发行版 | Arch Linux |
| 内核 | 7.2.11 |
| 桌面 | niri 26.04 (Wayland) |
| GPU | NVIDIA RTX 5070 Ti Mobile + Intel ArrowLake |
| 驱动 | nvidia-open 615.78.08 |
| Proton | Experimental 11.0 |
| 游戏库 | NTFS (ntfs-3g)，prefix 在 ext4 |
| WE 版本 | build 20000800000042 |
| linux-wallpaperengine | r643.a0ddce58 |

---

## 目录结构

```
.
├── README.md                  # 本文件：总览 + 路线 B
├── AGENT.md                   # agent 执行指南
├── docs/
│   └── NIRI-WALLPAPER.md      # 路线 A：原生渲染壁纸（核心教程）
├── src/
│   └── explorer.c             # 路线 B：explorer.exe 转发器
└── scripts/
    ├── install.sh             # 路线 B：一键安装/还原
    ├── diagnose.sh            # 环境诊断
    └── we-wallpaper           # 路线 A：壁纸切换脚本
```

---

## 许可

MIT
