#!/bin/bash
# 一键安装好事桌宠：编译（如需）→ 装进「应用程序」→ 去掉下载隔离标记 → 启动
#
#   ./install.sh                    编译（如需要）后安装并启动
#   ./install.sh --from 路径.app     安装一个已有的应用包（比如从 dmg 拖到下载文件夹的那个）
#   ./install.sh --build            强制重新编译再安装
#   ./install.sh --uninstall        退出并删除「应用程序」里的应用（保留位置、音量等设置）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="好事桌宠"
EXECUTABLE="GoodThingPet"
BUILD_APP="build/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"
SOURCE=""
FORCE_BUILD=0

die() { printf '\n安装中止：%s\n' "$1" >&2; exit 1; }
quit_running() { pkill -x "$EXECUTABLE" >/dev/null 2>&1 || true; }

case "${1:-}" in
    --uninstall)
        quit_running
        if [ ! -e "$TARGET" ]; then
            printf '「应用程序」里没有%s，无需卸载。\n' "$APP_NAME"; exit 0
        fi
        rm -rf "$TARGET" || die "删除 $TARGET 失败，可能需要：sudo ./install.sh --uninstall"
        printf '已卸载 %s。位置、音量、大小等设置仍保留在用户偏好里。\n' "$TARGET"
        exit 0
        ;;
    --from)
        SOURCE="${2:-}"
        if [ -z "$SOURCE" ] || [ ! -d "$SOURCE" ]; then
            die "用法：./install.sh --from /路径/好事桌宠.app"
        fi
        ;;
    --build) FORCE_BUILD=1 ;;
    "") ;;
    *) printf '未知参数：%s（可用：--from 路径 / --build / --uninstall）\n' "$1" >&2; exit 2 ;;
esac

if [ -n "$SOURCE" ]; then
    BUNDLE="$SOURCE"
else
    BUNDLE="$BUILD_APP"
    if [ "$FORCE_BUILD" = "1" ] || [ ! -d "$BUNDLE" ]; then ./build.sh; fi
fi

quit_running
sleep 0.5
# 覆盖安装：先删旧版，避免新旧签名混杂导致启动失败
if [ -e "$TARGET" ]; then rm -rf "$TARGET"; fi
cp -R "$BUNDLE" "$TARGET" || die "写入 $TARGET 失败。需要管理员权限时改用：sudo ./install.sh"
# 从浏览器、dmg 或网盘拿到的包会带 com.apple.quarantine，本地签名会被 Gatekeeper 拦住
before="$(xattr -p com.apple.quarantine "$TARGET" 2>/dev/null || true)"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
if [ -n "$before" ]; then printf '已移除下载隔离标记。\n'; fi
open "$TARGET"
printf '已安装并启动：%s\n' "$TARGET"
printf '入口在菜单栏最右侧的「好事」，点桌面上的人物就播放。\n'
