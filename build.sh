#!/bin/bash
# 构建 SketchSearch.app
#
#   ./build.sh              编译（arm64 + x86_64 通用二进制）并打包
#   ./build.sh --install    编译后安装到 /Applications
#   ./build.sh --package    编译后产出可分享的 DMG，输出到桌面（~/Desktop）
#   ./build.sh --zip        同上，但产出 zip 而不是 DMG
#   ./build.sh --fast       只编译当前架构，速度快（本机自用够了）
#
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="SketchSearch"
VERSION="1.0.1"
MIN_MACOS="14.0"
BUILD_DIR="build"
DIST_DIR="dist"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MCACHE="$PWD/$BUILD_DIR/mcache"

MODE="${1:-build}"
UNIVERSAL=1
[ "$MODE" = "--fast" ] && UNIVERSAL=0

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$MCACHE"

if [ "$UNIVERSAL" = "1" ]; then
    ARCHS="arm64 x86_64"
    echo "==> 编译通用二进制（Apple 芯片 + Intel）"
else
    ARCHS="$(uname -m)"
    echo "==> 编译（仅 ${ARCHS}）"
fi

SLICES=()
for ARCH in $ARCHS; do
    OUT="$BUILD_DIR/$APP_NAME-$ARCH"
    echo "    - $ARCH"
    xcrun --sdk macosx swiftc \
        -module-cache-path "$MCACHE" \
        -O \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        Sources/*.swift \
        -o "$OUT" \
        -lsqlite3 -lz
    SLICES+=("$OUT")
done

if [ "${#SLICES[@]}" -gt 1 ]; then
    lipo -create -output "$APP_DIR/Contents/MacOS/$APP_NAME" "${SLICES[@]}"
else
    cp "${SLICES[0]}" "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

echo "==> 组装应用包"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
    # 图标统一由下面的 Icon Composer 工程生成，旧的 AppIcon.icns 不再使用

# macOS 26 的新图标格式：用 Icon Composer 工程（Resources/SketchSearch.icon）编译出
# Assets.car + icns。只提供旧的 .icns 时，系统会判定图标不符合新规范，
# 在 Dock / Finder 里给图标外面再套一层标准底板。走这条路才是原生玻璃图标。
ICON_SRC="Resources/$APP_NAME.icon"
if [ -d "$ICON_SRC" ]; then
    echo "==> 编译图标（Icon Composer 工程）"
    rm -rf "$BUILD_DIR/iconout" "$BUILD_DIR/iconwork"
    mkdir -p "$BUILD_DIR/iconout" "$BUILD_DIR/iconwork"
    # 复制一份再改，不动 Resources 里的源工程
    cp -R "$ICON_SRC" "$BUILD_DIR/iconwork/$APP_NAME.icon"
    # Icon Composer 新建工程默认按 iOS 来（supported-platforms.squares = "shared"），
    # 每次在 Icon Composer 里保存都会把平台声明写回去，所以放在构建流程里自动修正成 macOS。
    python3 - "$BUILD_DIR/iconwork/$APP_NAME.icon/icon.json" <<'PYEOF'
import collections, json, sys
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle, object_pairs_hook=collections.OrderedDict)
    data["supported-platforms"] = collections.OrderedDict([("squares", ["macOS"])])
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print("   平台声明已修正为 macOS")
except Exception as error:
    print("   平台声明修正失败：", error)
PYEOF
    # 主题色也走资产目录（Info.plist 的 NSAccentColorName 指向它）：
    # 顶部标签栏这类系统控件只认应用级强调色，SwiftUI 的 .tint() 改不动。
    cp -R Resources/Assets.xcassets "$BUILD_DIR/iconwork/" 2>/dev/null || true
    if xcrun actool --compile "$BUILD_DIR/iconout" \
        --platform macosx --minimum-deployment-target "$MIN_MACOS" \
        --app-icon "$APP_NAME" \
        --output-partial-info-plist "$BUILD_DIR/iconout/partial.plist" \
        "$BUILD_DIR/iconwork/$APP_NAME.icon" \
        "$BUILD_DIR/iconwork/Assets.xcassets" >/dev/null 2>&1; then
        cp "$BUILD_DIR/iconout/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
        cp "$BUILD_DIR/iconout/$APP_NAME.icns" "$APP_DIR/Contents/Resources/$APP_NAME.icns"
        # actool 输出的键（CFBundleIconFile / CFBundleIconName）已经写在 Resources/Info.plist 里
        echo "   Assets.car + $APP_NAME.icns"
    else
        echo "   actool 失败"
    fi
fi
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

xattr -cr "$APP_DIR" 2>/dev/null || true
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 \
    || echo "   （临时签名失败，不影响本机运行）"

echo "==> 完成：$APP_DIR"
echo "   架构：$(lipo -archs "$APP_DIR/Contents/MacOS/$APP_NAME")"
echo "   体积：$(du -sh "$APP_DIR" | awk '{print $1}')"

case "$MODE" in
    --install)
        echo "==> 安装到 /Applications"
        rm -rf "/Applications/$APP_NAME.app"
        cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
        xattr -cr "/Applications/$APP_NAME.app" 2>/dev/null || true
        echo "   已安装：/Applications/$APP_NAME.app"
        ;;
    --package)
        echo "==> 打包分发文件（DMG）"
        # 分发用的 dmg 统一放到桌面（方便直接发给别人）；
        # 工作区里的 dist/ 只作为打包中转目录。
        OUT_DIR="${ZIP_DIR:-$HOME/Desktop}"
        STAGE="$DIST_DIR/dmg"
        rm -rf "$DIST_DIR"
        mkdir -p "$STAGE" "$OUT_DIR"
        cp -R "$APP_DIR" "$STAGE/"
        cp Resources/使用说明.txt "$STAGE/使用说明.txt"
        cp LICENSE "$STAGE/LICENSE"
        # 指向 /Applications 的软链接：打开 dmg 后可以直接把 app 拖进去安装
        ln -s /Applications "$STAGE/Applications"
        DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
        rm -f "$DMG"
        # UDZO = 压缩只读，体积小、挂载快
        hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
            -ov -format UDZO "$DMG"
        echo "   已生成：${DMG}（$(du -sh "$DMG" | awk '{print $1}')）"
        echo "   卷内含：SketchSearch.app + 使用说明.txt + LICENSE + Applications 快捷方式"
        ;;
    --zip)
        echo "==> 打包分发文件（zip）"
        OUT_DIR="${ZIP_DIR:-$HOME/Desktop}"
        rm -rf "$DIST_DIR"
        mkdir -p "$DIST_DIR/SketchSearch" "$OUT_DIR"
        cp -R "$APP_DIR" "$DIST_DIR/SketchSearch/"
        cp Resources/使用说明.txt "$DIST_DIR/SketchSearch/使用说明.txt"
        cp LICENSE "$DIST_DIR/SketchSearch/LICENSE"
        # 用 ditto 打包：保留符号链接与代码签名，避免解压后签名失效
        ditto -c -k --sequesterRsrc --keepParent \
              "$DIST_DIR/SketchSearch" "$OUT_DIR/$APP_NAME-$VERSION.zip"
        echo "   已生成：$OUT_DIR/$APP_NAME-$VERSION.zip（$(du -sh "$OUT_DIR/$APP_NAME-$VERSION.zip" | awk '{print $1}')）"
        ;;
esac
