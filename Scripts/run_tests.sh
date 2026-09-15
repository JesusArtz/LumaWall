#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
TEST_DIR="$PROJECT_DIR/build/tests"
MODULE_CACHE_DIR="$PROJECT_DIR/build/TestModuleCache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
mkdir -p "$TEST_DIR" "$MODULE_CACHE_DIR"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" SWIFT_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
xcrun swiftc -sdk "$SDK_PATH" -target "$ARCH-apple-macosx14.0" -framework CoreGraphics -framework ImageIO -framework Security \
  "$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/ProductSupport.swift" \
  "$PROJECT_DIR/Sources/AppSettings.swift" "$PROJECT_DIR/Sources/ScenePackage.swift" \
  "$PROJECT_DIR/Sources/WETexture.swift" "$PROJECT_DIR/Sources/WallpaperImporter.swift" \
  "$PROJECT_DIR/Sources/WallpaperStorage.swift" "$PROJECT_DIR/Sources/WorkshopServices.swift" \
  "$PROJECT_DIR/Sources/SteamServices.swift" \
  "$PROJECT_DIR/Tests/main.swift" -o "$TEST_DIR/LumaWallTests"
"$TEST_DIR/LumaWallTests"
