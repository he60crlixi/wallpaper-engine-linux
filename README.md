# Wallpaper Engine on Linux

让 Wallpaper Engine 在 Linux（Proton/Wine）下**能启动、能浏览壁纸库、能看视频**，
并让「打开文件夹」「双击视频」调用主机的文件管理器和播放器。

> **这不是完整适配。** 壁纸渲染功能在 Wayland 下**用不了**（详见下方能力边界）。
> 本方案的目标是：把 WE 当成一个「壁纸/视频浏览器」来用，而不是让它接管桌面。

面向人类阅读，也面向 agent 自动化执行。

---

## 能力边界（先看这个）

| 功能 | 状态 | 说明 |
|---|---|---|
| 启动程序 | ✅ | 修好 prefix 后正常 |
| 打开主界面 | ✅ | 浏览创意工坊、预览图 |
| 点「打开文件夹」 | ✅ | 弹出主机文件管理器 |
| 双击视频文件 | ✅ | 用主机播放器（mpv 等）播放 |
| 应用壁纸到桌面 | ❌ | **Wayland 下不可用** |
| 壁纸实时渲染预览 | ❌ | 同上 |

**为什么壁纸功能不行**：WE 依赖 Windows DWM 桌面合成器，把渲染窗口塞到桌面图标层
**下面**。Wayland 没有这个层，XWayland 是 `-rootless` 模式，没有「桌面」可挂载。
WE 会卡在初始化抛 `COMException`，壁纸永远出不来。

这是原理性限制，不是配置问题，**改配置绕不过去**。

如果你要的是「Linux 桌面动态壁纸」，用原生方案：

| 工具 | 说明 |
|---|---|
| `swww` | Wayland 壁纸守护进程，支持 GIF/视频 |
| `mpvpaper` | 用 mpv 播放视频当壁纸 |
| `hyprpaper` | Hyprland 专用 |

这些不读 Steam 创意工坊，素材要另外找。

---

## 两个独立的问题

这套方案解决的是**两个完全不同**的故障，容易混在一起，所以分开说。

### 问题 A：启动即崩溃 / 卡在「正在运行」但没窗口

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

如果 Steam 库放在 **NTFS** 分区（双系统共用盘最常见），Linux 的 `ntfs-3g` 驱动不允许文件名包含冒号（冒号在 NTFS 里是备用数据流分隔符），创建直接返回 `EINVAL`。

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

### 问题 B：点「打开文件夹」没反应，双击视频打不开

**症状**

- 在 Wallpaper Engine 界面里点「在资源管理器中打开」，什么都不发生
- 双击壁纸的视频文件，没有播放器启动
- **没有任何报错**（这点很关键）

**原因**

Wallpaper Engine 内部实现是：

```
ShellExecuteExW("explorer.exe", "/n,/select,<path>")
```

它**直接启动 Wine 自带的 `explorer.exe`**，走的是 Wine 内部路径，**完全不经过系统文件关联**。

所以你就算把 `.mp4` 关联到 `winebrowser` 也没用——根本没被调用到。

而 Wine 的 `explorer.exe` 只会打开它自己那个简陋的窗口，不会转发到 nautilus/nautilus/mpv。

另外 WE 调用时带了 `SEE_MASK_FLAG_NO_UI`，把错误提示抑制了，所以表现为「点了没反应」。

**修复**

用一个自己编译的 `explorer.exe` 替换 prefix 里的原版。它解析 `/n,/select,<path>`，把路径交给 `winebrowser.exe` → `xdg-open` → 主机的默认程序。

见 [`src/explorer.c`](src/explorer.c)。

---

## 快速开始

```bash
git clone https://github.com/<you>/wallpaper-engine-linux
cd wallpaper-engine-linux
./scripts/install.sh --dry-run    # 先看要做什么
./scripts/install.sh              # 实际执行
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

## 手动步骤（不想跑脚本）

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

## 验证

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

## 排查

### 界面启动后看不见窗口

平铺式合成器（niri/sway/Hyprland）会把新窗口挤进平铺布局，WE 的窗口可能被压到屏幕外。

niri 里加窗口规则，让它浮动：

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

残留进程会让 Steam 误判。清理：

```bash
pkill -x wallpaper64.exe
WINEPREFIX="$PREFIX" wineserver -k
```

### 修改注册表后没生效

`regedit /S` 在 Proton 的 prefix 里会**静默失败**，不报错但也没写进去。直接追加到 `system.reg` 文本文件更可靠（脚本用的就是这个方式）。

验证：

```bash
grep -a "mp4file" "$PREFIX/system.reg"
```

### `wine start` 报 `ShellExecuteEx 失败`

Wine 的 `ShellExecuteExW` 在部分 prefix 下整体失效（连 `notepad.exe` 都启动不了）。这是 Wine 自身的问题，改注册表绕不过去——这也是为什么要替换 `explorer.exe` 而不是只改关联。

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

其他发行版/Proton 版本理论上通用，因为问题都在 Wine 层。

---

## 目录结构

```
.
├── README.md
├── src/
│   └── explorer.c          # explorer.exe 转发器
└── scripts/
    ├── install.sh          # 一键安装/还原
    └── diagnose.sh         # 环境诊断
```

---

## 许可

MIT
