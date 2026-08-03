#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/LumaWall.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$MODULE_CACHE_DIR"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
xcrun swiftc -parse-as-library -O -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" \
  -framework SwiftUI -framework AppKit -framework AVFoundation -framework QuartzCore \
  -framework Metal -framework MetalKit -framework CoreGraphics -framework ImageIO \
  -framework ServiceManagement -framework UniformTypeIdentifiers \
  "$PROJECT_DIR"/Sources/*.swift -o "$MACOS_DIR/LumaWall"

cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.png" "$RESOURCES_DIR/AppIcon.png"
codesign --force --deep --sign - "$APP_DIR"
echo "$APP_DIR"
