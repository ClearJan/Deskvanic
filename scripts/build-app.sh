#!/bin/zsh
# Deskvanic 应用打包脚本：Release 构建 → 组装 .app → ad-hoc 签名 → 验证。
# 用法：scripts/build-app.sh [--debug]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="Release"
if [[ "${1:-}" == "--debug" ]]; then
  CONFIG="Debug"
fi

echo "==> swift build -c $CONFIG"
if [[ "$CONFIG" == "Release" ]]; then
  swift build -c release
  BIN=".build/release/DeskvanicApp"
else
  swift build
  BIN=".build/debug/DeskvanicApp"
fi

VERSION="$(git describe --tags --always 2>/dev/null || echo "0.1.0")"
APP="build/Deskvanic.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 组装 $APP"
cp "$BIN" "$APP/Contents/MacOS/DeskvanicApp"
cp AppResources/Info.plist "$APP/Contents/Info.plist"

# 版本信息写入（构建号 = 时间戳，保证每次构建可区分）
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
if [[ -f AppResources/AppIcon.icns ]]; then
  cp AppResources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist"
fi

echo "==> ad-hoc 签名（正式签名见 docs/RELEASE_CHECKLIST.md）"
codesign --force --sign - --timestamp=none \
  --options runtime \
  "$APP"

echo "==> 验证"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP" 2>/dev/null && echo "Gatekeeper: 通过" || echo "Gatekeeper: ad-hoc 签名，本机可运行（正式分发需 Developer ID 签名 + 公证）"

echo "✅ 完成: $ROOT/$APP"
