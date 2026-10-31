# niri 上真正显示 Wallpaper Engine 壁纸

这是本仓库**最重要的一篇**。

前面的 `README.md` 解决的是「让 WE 程序能启动、能浏览、能看视频」，
但**壁纸本身显示不出来**——因为 WE 依赖 Windows 的 `Progman`/`WorkerW` 桌面层。

这篇讲的是**另一条完全不同的路**：不运行 WE，而是用开源项目
[`linux-wallpaperengine`](https://github.com/Almamu/linux-wallpaperengine)
直接解析 WE 的壁纸格式，渲染到 niri 的背景层。

**结果是：真的能看到壁纸。** 创意工坊里的 scene 和 video 都能用。

---

## 原理：为什么这条路能成

两条路的核心差异：

| | 原版 WE（Wine） | linux-wallpaperengine |
|---|---|---|
| 运行什么 | `wallpaper64.exe` | 原生 Linux 程序 |
| 壁纸挂哪 | `SetParent` 到 Windows `WorkerW` 窗口 | wlr-layer-shell 的 `background` 层 |
| Wayland 支持 | ❌ 没有 `Progman` | ✅ 原生 layer-shell |
| 性能 | Wine 转译开销 | 原生 Vulkan/OpenGL |
| 需要 Proton | 是 | 否 |

`linux-wallpaperengine` 自己实现了 WE 的壁纸格式解析：

- `scene.pkg` — 场景壁纸（粒子、着色器、模型）
- `project.json` — 壁纸元数据
- 视频类直接交给 libmpv 解码

所以它**不需要 Windows 桌面层**，只需要一个能承载画面的 Wayland surface。
niri 的 `background` layer 正好就是。

---

## 安装

### Arch / Manjaro

```bash
# 上游主包（推荐，更新活跃）
yay -S linux-wallpaperengine-git
```

> ⚠️ **不要装 `niri-wallpaperengine-git`**
>
> 那个包带一个 niri 专用补丁，但补丁已经跟不上下游代码了，构建会失败：
>
> ```
> patch unexpectedly ends in middle of line
> Hunk #1 FAILED at 116.
> ```
>
> 上游主包已经内置了 layer-shell 支持，加 `--layer background` 就行，不需要那个补丁。

### 其他发行版

从源码构建：

```bash
git clone --recurse-submodules https://github.com/Almamu/linux-wallpaperengine
cd linux-wallpaperengine
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
sudo cmake --install build
```

依赖：`cmake` `gcc` `glfw` `glew` `freeglut` `lz4` `ffmpeg` `mpv`
`libpulse` `wayland` `wayland-protocols` `sdl2` `glm`

---

## 关键：assets 目录

**这是最容易踩的坑。**

`linux-wallpaperengine` 需要 WE 的 `assets`（着色器、材质、粒子预设），
默认去 `/opt/linux-wallpaperengine/assets` 找。但 Steam 版的 assets 在**游戏目录**里。

不指定就会报：

```
Cannot find directory for steam app wallpaper_engine: assets
Cannot find a valid assets folder, resolved to "/opt/linux-wallpaperengine/assets"
```

然后启动即退出。

**正确做法**：用 `--assets-dir` 指向游戏目录：

```bash
WE_ASSETS=/path/to/SteamLibrary/steamapps/common/wallpaper_engine/assets
```

目录结构应该是：

```
wallpaper_engine/assets/
├── effects/
├── fonts/
├── materials/
├── models/
├── particles/
├── presets/
├── scenes/
├── scripts/
├── shaders/
└── zcompat/
```

---

## 最小可用命令

```bash
linux-wallpaperengine \
  --assets-dir "$WE_ASSETS" \
  --screen-root eDP-2 \
  --layer background \
  --bg "$WORKSHOP/2981249186" \
  --silent \
  --fps 30 \
  --hwdec no
```

逐个解释：

| 参数 | 作用 | 必须 |
|---|---|---|
| `--assets-dir` | WE 资源目录，不给就启动失败 | ✅ |
| `--screen-root` | 目标显示器名（`niri msg outputs` 查） | ✅ |
| `--layer background` | **niri 专用**，见下方说明 | ✅ |
| `--bg` | 壁纸目录路径 | ✅ |
| `--silent` | 静音（壁纸可能带音效） | 建议 |
| `--fps 30` | 限帧，省电 | 建议 |
| `--hwdec no` | 关硬解，见「已知限制」 | 视情况 |

### `--layer background` 为什么必须加

默认是 `bottom` 层。在 niri 上，`bottom` 层的 surface 会被**克隆到每个工作区**，
导致总览界面里每个工作区缩略图都显示同一张壁纸，很乱。

`background` 层配合 niri 的 `place-within-backdrop` 规则才是正确的用法：

```kdl
// ~/.config/niri/config.kdl
layer-rule {
    match namespace="linux-wallpaperengine"
    place-within-backdrop true
}
```

---

## 查显示器名

```bash
niri msg outputs
```

输出类似：

```
Output "BOE NE160QDM-NZC Unknown" (eDP-2)
```

括号里的 `eDP-2` 就是 `--screen-root` 要的值。

---

## 已知限制

### 1. NTFS 上无法硬件解码

如果 Steam 库在 NTFS 分区（双系统共用盘常见），`--hwdec nvdec-copy` 会失败：

```
filesystem error: The specified mount cannot be handled by
any of the filesystem adapters: Success [/mnt/data/...]
```

**原因**：`linux-wallpaperengine` 的文件系统适配器不支持 ntfs-3g 挂载点。
和 Proton prefix 那个「冒号问题」是同一类根源。

**解决**：

- **软解**（默认可用）：加 `--hwdec no`，CPU 占用高但能用
- **复制到 ext4**：把壁纸目录复制到 Linux 原生分区，硬解就能工作

### 2. 视频壁纸比场景壁纸吃 CPU 得多

实测（4K，24 核机器）：

| 类型 | 单核 CPU | 整机 CPU |
|---|---|---|
| `scene`（场景） | 3-10% | <1% |
| `video`（视频，软解） | 90-95% | ~4% |

**优先用 scene 类型壁纸。** 它实时渲染，不吃解码，反而更省。

查壁纸类型：

```bash
jq -r '.type' "$WORKSHOP/<id>/project.json"
```

### 3. 不是所有壁纸都能渲染

- ✅ `scene` — 完全支持
- ✅ `video` — 支持（mpv 解码）
- ⚠️ `web` — 部分支持，依赖 CEF 特性可能失败
- ❌ 带特殊脚本 API 的壁纸可能报错

---

## 完整教程：从零到开机自启

### 第 1 步：确认环境

```bash
# niri 版本（需要支持 layer-shell，26.x 都行）
niri msg version

# 显示器名
niri msg outputs | head -3

# 壁纸目录
ls ~/.local/share/Steam/steamapps/workshop/content/431960 | head
```

### 第 2 步：安装

```bash
yay -S linux-wallpaperengine-git
which linux-wallpaperengine
```

### 第 3 步：找出你的路径

```bash
# 游戏目录（assets 在这）
WE_DIR=$(find /mnt ~/.local/share/Steam -maxdepth 6 \
         -type d -name wallpaper_engine 2>/dev/null | head -1)
echo "WE_DIR=$WE_DIR"
echo "ASSETS=$WE_DIR/assets"

# 创意工坊目录
WORKSHOP=$(dirname "$(dirname "$WE_DIR")")/workshop/content/431960
echo "WORKSHOP=$WORKSHOP"
```

### 第 4 步：先手动测一个

选一个 **scene** 类型（省 CPU）：

```bash
for d in "$WORKSHOP"/*/; do
    t=$(jq -r '.type // "?"' "$d/project.json" 2>/dev/null)
    [ "$t" = "scene" ] && echo "$(basename "$d")  $(jq -r '.title' "$d/project.json")"
done | head -10
```

挑一个 ID，然后：

```bash
linux-wallpaperengine \
  --assets-dir "$WE_DIR/assets" \
  --screen-root eDP-2 \
  --layer background \
  --bg "$WORKSHOP/2981249186" \
  --silent --fps 30 --hwdec no
```

**这时背景应该变了。** 确认能看到后按 `Ctrl+C` 停掉。

如果没变化，看输出里有没有 `VO:` 行：

```
VO: [libmpv] 3840x2160 yuv420p     ← 视频解码成功
```

没有的话检查 `--assets-dir` 和 `--bg` 路径。

### 第 5 步：装切换脚本

复制本仓库的 [`scripts/we-wallpaper`](scripts/we-wallpaper) 到 `~/.local/bin/`：

```bash
install -Dm755 scripts/we-wallpaper ~/.local/bin/we-wallpaper
```

改开头的三个变量：

```bash
WE_ASSETS="/你的路径/wallpaper_engine/assets"
WORKSHOP="/你的路径/workshop/content/431960"
OUTPUT="eDP-2"     # 你的显示器名
```

用法：

```bash
we-wallpaper              # 列出所有壁纸，▶ 标记当前
we-wallpaper 2981249186   # 切换
we-wallpaper current      # 当前是哪个
we-wallpaper next         # 随机换
we-wallpaper stop         # 停
```

### 第 6 步：配置 niri layer-rule

```kdl
// ~/.config/niri/config.kdl

// 壁纸放在 backdrop 层，避免总览里被克隆到每个工作区
layer-rule {
    match namespace="linux-wallpaperengine"
    place-within-backdrop true
}
```

### 第 7 步：开机自启

```kdl
// ~/.config/niri/config.kdl

spawn-at-startup "~/.local/bin/we-wallpaper" "2981249186"
```

验证配置：

```bash
niri validate
```

应该输出 `config is valid`。

### 第 8 步：验证

重新登录，或者手动跑一次：

```bash
we-wallpaper 2981249186
```

检查是否挂到背景层：

```bash
niri msg layers | grep -A2 linux-wallpaperengine
```

期望：

```
Background layer:
    Surface:
      Namespace: "linux-wallpaperengine"
```

---

## 排查

### 启动即退出，日志说找不到 assets

```
Cannot find a valid assets folder, resolved to "/opt/linux-wallpaperengine/assets"
```

→ 加 `--assets-dir <游戏目录>/assets`

### 硬解失败

```
Device does not support the VK_KHR_video_decode_queue extension!
CUDA_ERROR_OUT_OF_MEMORY
Error allocating a VDPAU video surface
```

→ 加 `--hwdec no` 走软解。若壁纸在 NTFS 上，硬解本来也不可用。

### 进程在跑但屏幕没变化

```bash
niri msg layers | grep linux-wallpaperengine
```

- **没有输出** → layer-shell surface 没创建，检查 `--layer background` 和显示器名
- **有输出但看不见** → 可能被其他 surface 遮挡，检查 niri 的 `layer-rule` 和背景色设置

### 总览界面里壁纸重复出现

→ 少了 `--layer background`，或没配 `place-within-backdrop` 规则

### CPU 占用高

1. 换 `scene` 类型壁纸（最大收益）
2. 降帧率：`--fps 15`
3. 把壁纸复制到 ext4 后用硬解
4. 加 `--disable-particles`（关粒子特效）

### 换壁纸后旧进程没退

脚本里用 `ps -eo pid,args | grep -F` 定位进程，而不是 `pkill -f`。
后者会匹配到脚本自己的命令行，把自己杀掉——这是实际踩过的坑。

---

## 和原版 WE 共存

两者**不冲突**，可以同时用：

- `linux-wallpaperengine` 负责**显示壁纸**（后台常驻）
- 原版 WE 负责**浏览创意工坊、订阅、看视频**（按需打开）

订阅新壁纸后，`we-wallpaper` 的列表会自动包含它（读同一个创意工坊目录）。

---

## 实测数据

作者的机器（Arch / niri 26.04 / RTX 5070 Ti + ArrowLake / 24 核）：

| 项目 | 值 |
|---|---|
| 壁纸 | `2981249186` 4K SCI-FI Black Hole（scene） |
| 单核 CPU | 3.1% |
| 整机 CPU | 5.8%（含系统其他进程） |
| 内存 | 0.8% |
| 层 | `background` |
| 硬解 | 不可用（NTFS） |

---

## 参考

- [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) — 上游项目
- [niri layer-shell 文档](https://yalter.github.io/niri/Configuration:-Layer-Rules.html)
- [wlr-layer-shell 协议](https://wayland.app/protocols/wlr-layer-shell-unstable-v1)
