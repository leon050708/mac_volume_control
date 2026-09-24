#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
xcrun clang -std=c11 -g -fsanitize=address,undefined \
  Sources/AudioRender.c Tests/AudioRenderTests.c -framework CoreAudio -o .build/AudioRenderTests
.build/AudioRenderTests
plutil -lint Resources/Info.plist
