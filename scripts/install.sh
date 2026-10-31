#!/usr/bin/env bash
#
# install.sh — Wallpaper Engine Linux 适配一键安装
#
# 解决的问题：
#   1. prefix 在 NTFS 分区上导致 Proton 无法创建 dosdevices/c: 符号链接
#      → 游戏启动即崩溃 / 卡死
#   2. Wallpaper Engine「打开文件夹」「双击视频」无反应
#      → Wine 的 explorer.exe 不转发到主机
#
# 用法：
#   ./install.sh                 # 自动检测
#   ./install.sh --dry-run       # 只看要做什么，不实际改动
#   ./install.sh --uninstall     # 还原
#
# 作者：Little Code Sauce
# 许可：MIT
#
set -euo pipefail

APPID="431960"
WE_DIRNAME="wallpaper_engine"
DRY_RUN=0
UNINSTALL=0

for arg in "$@"; do
    case "$arg" in
        --dry-run)   DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    esac
done

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

info()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 定位路径

info "定位 Steam 与 Wallpaper Engine 安装位置"

STEAM_ROOTS=(
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
)

STEAM_ROOT=""
for r in "${STEAM_ROOTS[@]}"; do
    [ -d "$r/steamapps" ] && { STEAM_ROOT="$r"; break; }
done
[ -n "$STEAM_ROOT" ] || die "找不到 Steam 安装目录"
ok "Steam: $STEAM_ROOT"

# 在所有库目录里找 Wallpaper Engine
LIB=""
MANIFEST=""
while IFS= read -r vdf; do
    libdir=$(dirname "$vdf")
    if [ -f "$libdir/appmanifest_${APPID}.acf" ]; then
        LIB="$libdir"
        MANIFEST="$libdir/appmanifest_${APPID}.acf"
        break
    fi
done < <(find "$STEAM_ROOT/steamapps" -maxdepth 1 -name "libraryfolders.vdf" 2>/dev/null
         # 其他库的位置从 libraryfolders.vdf 里解析
         )

# 如果上面没找到，扫常见挂载点
if [ -z "$LIB" ]; then
    for base in /mnt/*/SteamLibrary /mnt/*/Steam /media/*/*/SteamLibrary; do
        if [ -f "$base/steamapps/appmanifest_${APPID}.acf" ]; then
            LIB="$base/steamapps"
            MANIFEST="$LIB/appmanifest_${APPID}.acf"
            break
        fi
    done
fi
[ -n "$LIB" ] || die "找不到 Wallpaper Engine 安装库（appid $APPID）"
ok "游戏库: $LIB"

WE_DIR="$LIB/common/$WE_DIRNAME"
[ -d "$WE_DIR" ] || die "找不到游戏目录: $WE_DIR"

COMPAT_DIR="$LIB/compatdata/$APPID"
PREFIX="$COMPAT_DIR/pfx"
ok "Prefix: $COMPAT_DIR"

# ---------------------------------------------------------------- 卸载模式

if [ "$UNINSTALL" -eq 1 ]; then
    info "还原原始 explorer.exe"
    for d in "$PREFIX/drive_c/windows" "$PREFIX/drive_c/windows/system32"; do
        if [ -e "$d/explorer.exe.wine-orig" ]; then
            run rm -f "$d/explorer.exe"
            run cp -P "$d/explorer.exe.wine-orig" "$d/explorer.exe"
            ok "已还原 $d/explorer.exe"
        fi
    done
    info "清理转发器日志与临时文件"
    run rm -f "$PREFIX/drive_c/explorer-fwd.log"
    run rm -f "$PREFIX/drive_c/windows/system32/we-open.bat"
    ok "卸载完成。注册表关联保留（无害）"
    exit 0
fi

# ---------------------------------------------------------------- 第 1 步：检查 prefix 文件系统

info "第 1 步：检查 prefix 所在文件系统"

FSTYPE=$(findmnt -no FSTYPE -T "$COMPAT_DIR" 2>/dev/null || echo "unknown")
ok "文件系统类型: $FSTYPE"

case "$FSTYPE" in
    fuseblk|ntfs|ntfs3|vfat|exfat)
        warn "prefix 位于 $FSTYPE 分区上，Proton 无法创建 dosdevices/c: 符号链接"
        warn "这是 NTFS 不允许文件名含冒号导致的，会导致游戏启动即崩溃"
        echo
        echo "  修复方式：把 compatdata 迁到 Linux 原生分区（ext4/btrfs/xfs）"
        echo
        echo "    EXT4_ROOT=\"\$HOME/.local/share/Steam/steamapps\""
        echo "    mkdir -p \"\$EXT4_ROOT\""
        echo "    mv \"$LIB/compatdata\" \"\$EXT4_ROOT/compatdata_$APPID.bak\" 2>/dev/null || true"
        echo "    mkdir -p \"\$EXT4_ROOT/compatdata\""
        echo "    ln -sfn \"\$EXT4_ROOT/compatdata\" \"$LIB/compatdata\""
        echo
        echo "  注意：整个 compatdata 目录建议统一放到 ext4，一次解决所有游戏。"
        echo
        read -r -p "  现在自动迁移吗？[y/N] " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            EXT4_ROOT="$STEAM_ROOT/steamapps"
            [ -d "$EXT4_ROOT" ] || die "目标目录不存在: $EXT4_ROOT"
            EXT4_FS=$(findmnt -no FSTYPE -T "$EXT4_ROOT" 2>/dev/null)
            case "$EXT4_FS" in
                fuseblk|ntfs|ntfs3|vfat|exfat)
                    die "Steam 主目录也在 $EXT4_FS 上，需要另选一个 ext4 路径" ;;
            esac
            run mkdir -p "$EXT4_ROOT/compatdata"
            if [ -d "$COMPAT_DIR" ] && [ ! -L "$COMPAT_DIR" ]; then
                run cp -a "$COMPAT_DIR" "$EXT4_ROOT/compatdata/$APPID" 2>/dev/null || true
            fi
            run rm -rf "$COMPAT_DIR"
            run ln -sfn "$EXT4_ROOT/compatdata/$APPID" "$COMPAT_DIR"
            ok "已迁移 prefix 到 $EXT4_ROOT/compatdata/$APPID"
        else
            warn "跳过迁移。若游戏无法启动，请手动处理后再运行本脚本。"
        fi
        ;;
    *)
        ok "文件系统支持符号链接，无需迁移"
        ;;
esac

# ---------------------------------------------------------------- 第 2 步：编译转发器

info "第 2 步：编译 explorer 转发器"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="$SCRIPT_DIR/src/explorer.c"
[ -f "$SRC" ] || die "找不到源码: $SRC"

if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    warn "缺少 mingw-w64 交叉编译器"
    echo "  Arch:   sudo pacman -S mingw-w64-gcc"
    echo "  Debian: sudo apt install gcc-mingw-w64-x86-64"
    echo "  Fedora: sudo dnf install mingw64-gcc"
    die "请先安装编译器"
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
run x86_64-w64-mingw32-gcc -O2 -o "$BUILD_DIR/explorer.exe" "$SRC"
ok "编译完成: $BUILD_DIR/explorer.exe"

# ---------------------------------------------------------------- 第 3 步：部署

info "第 3 步：部署转发器到 prefix"

for d in "$PREFIX/drive_c/windows/system32" "$PREFIX/drive_c/windows"; do
    [ -d "$d" ] || continue
    if [ -e "$d/explorer.exe" ] && [ ! -e "$d/explorer.exe.wine-orig" ]; then
        run cp -P "$d/explorer.exe" "$d/explorer.exe.wine-orig"
        ok "已备份原文件: $d/explorer.exe.wine-orig"
    fi
    run rm -f "$d/explorer.exe"
    run cp "$BUILD_DIR/explorer.exe" "$d/explorer.exe"
    ok "已部署: $d/explorer.exe"
done

# ---------------------------------------------------------------- 第 4 步：注册表关联

info "第 4 步：写入文件类型关联（供 winebrowser 转发）"

SYSREG="$PREFIX/system.reg"
[ -f "$SYSREG" ] || die "找不到 system.reg"

if grep -aq 'we-linux-marker' "$SYSREG" 2>/dev/null; then
    ok "关联已存在，跳过"
else
    [ -e "$SYSREG.bak.we" ] || run cp "$SYSREG" "$SYSREG.bak.we"
    TS=$(date +%s)
    if [ "$DRY_RUN" -eq 0 ]; then
        cat >> "$SYSREG" <<EOF

[Software\\\\Classes\\\\mp4file] $TS
#time=1dd67daeaa56f7a
@="MP4 Video"
; we-linux-marker

[Software\\\\Classes\\\\mp4file\\\\shell\\\\open\\\\command] $TS
#time=1dd67daeaa56f7a
@="\\"C:\\\\windows\\\\system32\\\\winebrowser.exe\\" \\"%1\\""

[Software\\\\Classes\\\\mkvfile\\\\shell\\\\open\\\\command] $TS
#time=1dd67daeaa56f7a
@="\\"C:\\\\windows\\\\system32\\\\winebrowser.exe\\" \\"%1\\""

[Software\\\\Classes\\\\webmfile\\\\shell\\\\open\\\\command] $TS
#time=1dd67daeaa56f7a
@="\\"C:\\\\windows\\\\system32\\\\winebrowser.exe\\" \\"%1\\""

[Software\\\\Classes\\\\avifile\\\\shell\\\\open\\\\command] $TS
#time=1dd67daeaa56f7a
@="\\"C:\\\\windows\\\\system32\\\\winebrowser.exe\\" \\"%1\\""

[Software\\\\Classes\\\\movfile\\\\shell\\\\open\\\\command] $TS
#time=1dd67daeaa56f7a
@="\\"C:\\\\windows\\\\system32\\\\winebrowser.exe\\" \\"%1\\""

[Software\\\\Classes\\\\.mp4] $TS
#time=1dd67daeaa56f7a
@="mp4file"
"Content Type"="video/mp4"
"PerceivedType"="video"

[Software\\\\Classes\\\\.mkv] $TS
#time=1dd67daeaa56f7a
@="mkvfile"
"Content Type"="video/x-matroska"

[Software\\\\Classes\\\\.webm] $TS
#time=1dd67daeaa56f7a
@="webmfile"
"Content Type"="video/webm"

[Software\\\\Classes\\\\.avi] $TS
#time=1dd67daeaa56f7a
@="avifile"
"Content Type"="video/x-msvideo"

[Software\\\\Classes\\\\.mov] $TS
#time=1dd67daeaa56f7a
@="movfile"
"Content Type"="video/quicktime"
EOF
        ok "已写入注册表关联"
    else
        echo "  [dry-run] 追加注册表关联到 $SYSREG"
    fi
fi

# ---------------------------------------------------------------- 完成

echo
ok "安装完成"
echo
echo "  启动方式："
echo "    Steam 里直接点「开始游戏」即可"
echo
echo "  验证「打开文件夹」："
echo "    $PREFIX/drive_c/explorer-fwd.log   # 每次调用都会记录"
echo
echo "  还原："
echo "    $0 --uninstall"
echo
