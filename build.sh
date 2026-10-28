#!/bin/bash
# 构建 CameraFloat.app（原生 Swift + AVFoundation）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CameraFloat"
APP="${APP_NAME}.app"
BUNDLE_ID="com.local.camerafloat"

echo "==> 清理旧构建"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift"
# 按当前机器架构选择编译目标（Apple Silicon arm64 / Intel x86_64）
ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  TARGET="arm64-apple-macos13.0" ;;
  x86_64) TARGET="x86_64-apple-macos13.0" ;;
  *)      echo "未知架构 $ARCH，回退到 arm64"; TARGET="arm64-apple-macos13.0" ;;
esac
echo "    target: $TARGET"

swiftc -O -swift-version 5 \
  -target "$TARGET" \
  -framework Cocoa -framework AVFoundation \
  Sources/main.swift \
  -o "$APP/Contents/MacOS/${APP_NAME}"

echo "==> 写入 Info.plist、图标与签名"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" 2>/dev/null

echo "==> 完成: $(pwd)/${APP}"
