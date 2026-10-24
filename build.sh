#!/bin/bash
# 构建好事桌宠：环境检查 → 编译 → 打包资源 → 本地签名 → 自检 →（可选）产出可分发文件
#
#   ./build.sh                 编译并自检，产物在 build/好事桌宠.app
#   ./build.sh --package       另外产出 dist/ 下的 zip、dmg 和 sha256 校验文件
#   ./build.sh --no-self-test  跳过自检（没有图形会话的环境里用）
#
# 环境变量：PET_VERSION（默认 1.1）、PET_BUILD（默认 2）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="好事桌宠"
EXECUTABLE="GoodThingPet"
BUNDLE_ID="local.goodthing.desktop-pet"
VERSION="${PET_VERSION:-1.1}"
BUILD_NUMBER="${PET_BUILD:-2}"
DEPLOY_TARGET="arm64-apple-macosx14.0"
BUNDLE="build/$APP_NAME.app"
DIST="dist"
PACKAGE=0
SELF_TEST=1

for arg in "$@"; do
    case "$arg" in
        --package) PACKAGE=1 ;;
        --no-self-test) SELF_TEST=0 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) printf '未知参数：%s（可用：--package / --no-self-test / --help）\n' "$arg" >&2; exit 2 ;;
    esac
done

die() { printf '\n构建中止：%s\n' "$1" >&2; exit 1; }

check_environment() {
    [ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上构建，当前系统是 $(uname -s)。"
    local arch
    arch="$(uname -m)"
    if [ "$arch" != "arm64" ]; then
        die "本项目只支持 Apple Silicon（arm64），当前是 $arch。Intel Mac 需把 DEPLOY_TARGET 改成 x86_64-apple-macosx14.0 后自行验证。"
    fi
    local os_major
    os_major="$(sw_vers -productVersion | cut -d. -f1)"
    if [ "$os_major" -lt 14 ]; then
        die "需要 macOS 14 或更新版本，当前是 $(sw_vers -productVersion)。"
    fi
    if ! command -v swiftc >/dev/null 2>&1; then
        die "找不到 swiftc。先安装 Xcode Command Line Tools：
    xcode-select --install
装完重新运行本脚本（不需要完整 Xcode）。"
    fi
}

compile() {
    printf '编译中…\n'
    rm -rf "$BUNDLE"
    mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
    if ! swiftc -O -target "$DEPLOY_TARGET" -framework AppKit -framework AVFoundation \
        Sources/main.swift Sources/Bridge.swift -o "$BUNDLE/Contents/MacOS/$EXECUTABLE"; then
        die "swiftc 编译失败。请把上面的完整报错贴到 issue：
    https://github.com/yuhanfu513-ops/FengGe-Desktop-Pet/issues"
    fi
    if [ ! -f Assets/face.png ]; then
        die "缺少 Assets/face.png，素材不完整。用 Finder 双击解压，别用终端 unzip（对中文文件名会报错并漏文件）。"
    fi
    cp -R Assets/. "$BUNDLE/Contents/Resources/"
    cp LICENSE LICENSE-SunPet "$BUNDLE/Contents/Resources/"
    cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$EXECUTABLE</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
    codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || die "本地签名失败。"
}

self_test() {
    printf '自检中…\n'
    local out
    if ! out="$("$BUNDLE/Contents/MacOS/$EXECUTABLE" --self-test 2>&1)"; then
        printf '%s\n' "$out" >&2
        die "自检未通过（上面每行 FAIL 都指向具体环节）。若报素材缺失，请重新完整下载素材。"
    fi
    printf '%s\n' "$out" | tail -1
}

package() {
    # 分发包用 ASCII 文件名：GitHub Release 会丢掉附件名里的非 ASCII 字符，
    # 中文名上传后会变成「-1.1.dmg」这种残缺名字
    local base="GoodThingPet-$VERSION"
    mkdir -p "$DIST"
    rm -f "$DIST/$base.zip" "$DIST/$base.dmg" "$DIST/$base.sha256"
    # zip 用 ditto 生成：Finder 双击和 unzip 都能正确解出中文文件名
    ditto -c -k --keepParent "$BUNDLE" "$DIST/$base.zip"
    local stage
    stage="$(mktemp -d)"
    cp -R "$BUNDLE" "$stage/"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$stage" -ov -format UDZO \
        "$DIST/$base.dmg" || die "生成 dmg 失败。"
    rm -rf "$stage"
    ( cd "$DIST" && shasum -a 256 "$base.zip" "$base.dmg" > "$base.sha256" )
    printf '分发包：\n'
    ls -lh "$DIST" | sed 1d | sed 's/^/  /'
}

check_environment
compile
if [ "$SELF_TEST" = "1" ]; then self_test; fi
if [ "$PACKAGE" = "1" ]; then package; fi
printf '完成：%s\n' "$BUNDLE"
printf '安装：./install.sh（或把 app 拖进「应用程序」）\n'
