#!/usr/bin/env bash
#
# diagnose.sh — Wallpaper Engine Linux 环境诊断
#
# 只读检查，不做任何修改。输出用于判断问题出在哪一层。
#
set -uo pipefail

APPID="431960"

c_bold=$'\033[1m'; c_dim=$'\033[2m'; c_red=$'\033[31m'
c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'

hdr()  { printf '\n%s== %s ==%s\n' "$c_bold" "$*" "$c_rst"; }
ok()   { printf '  %s✓%s %s\n' "$c_grn" "$c_rst" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_ylw" "$c_rst" "$*"; }
note() { printf '  %s%s%s\n' "$c_dim" "$*" "$c_rst"; }

hdr "系统"
printf '  内核      : %s\n' "$(uname -r)"
printf '  发行版    : %s\n' "$(grep -m1 '^PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '\"')"
printf '  会话类型  : %s\n' "${XDG_SESSION_TYPE:-?}"
printf '  桌面      : %s\n' "${XDG_CURRENT_DESKTOP:-?}"
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    note "Wayland 会话：原版 WE 无法贴壁纸（需 Progman/WorkerW），"
    note "  但 linux-wallpaperengine 可以渲染到 background layer，见 docs/NIRI-WALLPAPER.md"
fi

hdr "定位 Steam 与游戏"
STEAM_ROOT=""
for r in "$HOME/.local/share/Steam" "$HOME/.steam/steam" \
         "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
    [ -d "$r/steamapps" ] && { STEAM_ROOT="$r"; break; }
done
if [ -n "$STEAM_ROOT" ]; then
    ok "Steam: $STEAM_ROOT"
else
    bad "找不到 Steam"
fi

LIB=""; WE_DIR=""
for base in $(find /mnt /media /run/media -maxdepth 4 -type d -name steamapps 2>/dev/null) \
            "$STEAM_ROOT/steamapps"; do
    if [ -f "$base/appmanifest_${APPID}.acf" ]; then
        LIB="$base"
        break
    fi
done

if [ -n "$LIB" ]; then
    ok "游戏库: $LIB"
    WE_DIR="$LIB/common/wallpaper_engine"
    [ -d "$WE_DIR" ] && ok "游戏目录: $WE_DIR" || bad "缺游戏目录"
else
    bad "找不到 Wallpaper Engine (appid $APPID)"
fi

COMPAT="$LIB/compatdata/$APPID"
PREFIX="$COMPAT/pfx"

hdr "prefix 文件系统（问题 A）"
if [ -d "$COMPAT" ]; then
    FS=$(findmnt -no FSTYPE -T "$COMPAT" 2>/dev/null || echo unknown)
    printf '  路径      : %s\n' "$COMPAT"
    printf '  类型      : %s\n' "$FS"
    case "$FS" in
        fuseblk|ntfs|ntfs3|vfat|exfat)
            bad "NTFS/FAT 分区：Proton 无法创建 dosdevices/c: 符号链接"
            note "→ 把 compatdata 迁到 ext4/btrfs/xfs（见 README 问题 A）"
            ;;
        *) ok "支持符号链接" ;;
    esac

    if [ -L "$COMPAT" ]; then
        ok "compatdata 是符号链接 → $(readlink "$COMPAT")"
    fi

    if [ -d "$PREFIX/dosdevices" ]; then
        if [ -e "$PREFIX/dosdevices/c:" ] && [ -d "$PREFIX/drive_c" ]; then
            ok "dosdevices/c: 正常"
        else
            bad "dosdevices/c: 缺失或损坏"
        fi
    else
        bad "prefix 未创建（dosdevices 不存在）"
    fi
else
    bad "compatdata/$APPID 不存在（从未成功启动过）"
fi

hdr "explorer.exe 转发器（问题 B）"
if [ -d "$PREFIX/drive_c/windows/system32" ]; then
    SYS="$PREFIX/drive_c/windows/system32/explorer.exe"
    WIN="$PREFIX/drive_c/windows/explorer.exe"

    for f in "$SYS" "$WIN"; do
        [ -e "$f" ] || { bad "缺失: $f"; continue; }
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        if [ "$sz" -lt 300000 ] 2>/dev/null; then
            ok "已替换为转发器 ($(basename "$(dirname "$f")")/explorer.exe, ${sz}B)"
        else
            warn "仍是原版 Wine explorer.exe (${sz}B) → 需要替换"
        fi
    done

    for f in "$SYS.wine-orig" "$WIN.wine-orig"; do
        [ -e "$f" ] && note "备份存在: $f"
    done

    LOG="$PREFIX/drive_c/explorer-fwd.log"
    if [ -f "$LOG" ]; then
        ok "转发器日志存在，最后 5 行："
        tail -5 "$LOG" | sed 's/^/      /'
    else
        note "尚无转发器日志（未触发过，或未替换）"
    fi
else
    bad "prefix 不完整，无法检查"
fi

hdr "注册表关联"
SYSREG="$PREFIX/system.reg"
if [ -f "$SYSREG" ]; then
    n=$(grep -ac 'mp4file' "$SYSREG" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then
        ok "mp4file 关联已写入（$n 处）"
    else
        warn "未找到 mp4file 关联"
        note "注意：regedit /S 在 Proton prefix 里会静默失败，应直接追加 system.reg"
    fi
    grep -aq 'we-linux-marker' "$SYSREG" 2>/dev/null \
        && ok "install.sh 标记存在" \
        || note "无 install.sh 标记（可能是手动配置的）"
else
    bad "找不到 system.reg"
fi

hdr "壁纸渲染（linux-wallpaperengine）"
if command -v linux-wallpaperengine >/dev/null 2>&1; then
    ok "已安装: $(command -v linux-wallpaperengine)"
    ver=$(pacman -Q linux-wallpaperengine-git 2>/dev/null | awk '{print $2}')
    [ -n "$ver" ] && note "版本: $ver"

    # 是否正在运行
    pids=$(ps -eo pid,args 2>/dev/null | grep -F 'linux-wallpaperengine' \
           | grep -v grep | awk '{print $1}')
    if [ -n "$pids" ]; then
        ok "正在运行:"
        ps -eo pid,etime,%cpu,rss,args 2>/dev/null \
            | grep -F 'linux-wallpaperengine' | grep -v grep \
            | awk '{printf "      PID %s  %s  CPU %s%%  %sKB\n",$1,$2,$3,$4}'
        # 当前挂的壁纸
        ps -eo args 2>/dev/null | grep -F 'linux-wallpaperengine' | grep -v grep \
            | grep -oP -- '--bg \K\S+' | head -1 | while read -r bg; do
                note "壁纸: $(basename "$bg")"
            done
    else
        note "未运行"
    fi

    # layer-shell 挂载
    if command -v niri >/dev/null 2>&1 && niri msg version >/dev/null 2>&1; then
        if niri msg layers 2>/dev/null | grep -q 'linux-wallpaperengine'; then
            layer=$(niri msg layers 2>/dev/null \
                    | grep -B10 'linux-wallpaperengine' \
                    | grep -oP '^\s*\K\w+(?= layer:)' | tail -1)
            ok "已挂载到 layer: ${layer:-?}"
        else
            warn "未挂载到任何 layer（未运行，或 --layer 参数缺失）"
        fi
    fi

    # assets 是否可用
    if [ -n "$WE_DIR" ] && [ -d "$WE_DIR/assets/shaders" ]; then
        ok "assets 可用: $WE_DIR/assets"
    else
        warn "找不到 WE assets，启动时需 --assets-dir 指定"
    fi
else
    warn "未安装 linux-wallpaperengine"
    note "壁纸显示需要它，不是原版 WE 能做的"
    note "  Arch: yay -S linux-wallpaperengine-git"
fi

hdr "主机侧文件关联"
if command -v xdg-mime >/dev/null 2>&1; then
    for m in video/mp4 video/x-matroska image/gif; do
        d=$(xdg-mime query default "$m" 2>/dev/null)
        [ -n "$d" ] && ok "$m → $d" || warn "$m 无默认程序"
    done
fi
for t in xdg-open mpv; do
    command -v "$t" >/dev/null 2>&1 && ok "$t 可用" || warn "$t 不可用"
done
# winebrowser 在 prefix 内，不在主机 PATH
if [ -e "$PREFIX/drive_c/windows/system32/winebrowser.exe" ]; then
    ok "winebrowser.exe 存在（prefix 内）"
else
    warn "prefix 内缺 winebrowser.exe"
fi

hdr "Proton 与运行状态"
if [ -n "$LIB" ]; then
    ls "$LIB/common" 2>/dev/null | grep -i '^proton' | sed 's/^/  /' || warn "未找到 Proton"
fi

if pgrep -x wallpaper64.exe >/dev/null 2>&1; then
    warn "wallpaper64.exe 正在运行"
    ps -eo pid,etime,rss,comm | awk '$4 ~ /wallpaper|CrBrowser/ {printf "    %s  %s  %sKB  %s\n",$1,$2,$3,$4}'
    # CEF 主进程 comm 是 CrBrowserMain，不一定叫 wallpaperui.exe
    if pgrep -f 'wallpaperui\.exe' >/dev/null 2>&1 \
       || pgrep -x CrBrowserMain >/dev/null 2>&1; then
        ok "界面进程存在（wallpaperui / CrBrowserMain）"
    else
        warn "没有界面进程 → 界面没起来（可能卡在壁纸渲染初始化）"
    fi
else
    note "WE 当前未运行"
fi

# 僵尸进程
z=$(ps -eo stat,comm | awk '$1 ~ /^Z/ && $2 ~ /wallpaper|Cr/ {print $2}' | head -3)
[ -n "$z" ] && { warn "存在僵尸进程："; echo "$z" | sed 's/^/    /'; \
                 note "清理: pkill -x wallpaper64.exe && wineserver -k"; }

hdr "窗口（Wayland 合成器）"
if command -v niri >/dev/null 2>&1 && niri msg version >/dev/null 2>&1; then
    niri msg windows 2>/dev/null | grep -E 'Title:|Workspace' | paste - - 2>/dev/null \
        | sed 's/^/  /' | head -12
    if niri msg windows 2>/dev/null | grep -q 'Wallpaper UI'; then
        ok "Wallpaper UI 窗口存在"
        niri msg windows 2>/dev/null | grep -A5 'Title: "Wallpaper UI"' \
            | grep -E 'Workspace|floating' | sed 's/^/    /'
    else
        note "未找到 Wallpaper UI 窗口"
    fi
else
    note "非 niri 或 niri IPC 不可用，跳过"
fi

hdr "建议"
FS_NOW=$(findmnt -no FSTYPE -T "$COMPAT" 2>/dev/null || echo unknown)
case "$FS_NOW" in
    fuseblk|ntfs|ntfs3|vfat|exfat)
        echo "  → 先解决 prefix 文件系统问题（README「问题 A」）" ;;
esac
if [ -e "$PREFIX/drive_c/windows/system32/explorer.exe" ]; then
    sz=$(stat -c %s "$PREFIX/drive_c/windows/system32/explorer.exe" 2>/dev/null || echo 0)
    [ "$sz" -gt 300000 ] 2>/dev/null && echo "  → 运行 ./scripts/install.sh 替换 explorer.exe"
fi
echo "  → 完整说明见 README.md"
echo
