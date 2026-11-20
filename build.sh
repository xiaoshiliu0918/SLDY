#!/usr/bin/env bash
# 不装 Theos 也能编译（需要 macOS + Xcode Command Line Tools）
set -euo pipefail
cd "$(dirname "$0")"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"

clang -dynamiclib \
  -arch arm64 \
  -isysroot "$SDK" \
  -miphoneos-version-min=15.0 \
  -fobjc-arc -O2 \
  -framework UIKit -framework Foundation -framework QuartzCore \
  -install_name "@executable_path/Frameworks/AwemeLitePlus.dylib" \
  Hooks.m ACConfig.m ACUtils.m ACFloatingBall.m ACFullscreenController.m \
  ACMediaSaver.m \
  -o AwemeLitePlus.dylib

echo "built: $(pwd)/AwemeLitePlus.dylib"
