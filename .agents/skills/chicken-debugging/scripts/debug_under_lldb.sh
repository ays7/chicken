#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APP_PATH="${REPO_ROOT}/cotvnc/DerivedData/Build/Products/Development/Chicken Fork.app"

echo "==> Building Chicken Fork (Development / Debug)..."
cd "${REPO_ROOT}/cotvnc"
xcodebuild -project ChickenFork.xcodeproj \
  -scheme "Chicken Fork" \
  -configuration Development \
  -derivedDataPath ./DerivedData \
  ONLY_ACTIVE_ARCH=YES \
  DEBUG_INFORMATION_FORMAT="dwarf-with-dsym" \
  GCC_OPTIMIZATION_LEVEL=0 \
  build > /dev/null

echo "==> Launching ${APP_PATH} under LLDB..."
lldb "${APP_PATH}" --batch \
  -o "run" \
  -k "thread backtrace all" \
  -k "frame variable" \
  -k "register read"
