#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache build/音量.app/Contents/{MacOS,Resources}
xcrun clang -std=c11 -O2 -mmacosx-version-min=14.2 -c Sources/AudioRender.c -o .build/AudioRender.o
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.2" \
  -module-cache-path "$PWD/.build/module-cache" \
  -import-objc-header Sources/AudioRender.h \
  Sources/CoreAudioSupport.swift Sources/ProcessVolume.swift Sources/VolumeApp.swift \
  .build/AudioRender.o -o build/音量.app/Contents/MacOS/ProcessVolume \
  -framework SwiftUI -framework AppKit -framework CoreAudio -framework ServiceManagement
cp Resources/Info.plist build/音量.app/Contents/Info.plist
codesign --force --sign - build/音量.app
printf '已构建：%s/build/音量.app\n' "$PWD"
