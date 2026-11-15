#!/bin/bash
#
# scripts/package_dmg.sh
# Creates a styled, Retina-ready macOS installer DMG for Chicken Fork using dmgbuild.
#

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <path/to/Chicken Fork.app> <output_dmg_path>" >&2
  exit 1
fi

APP_PATH="$1"
DMG_PATH="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$APP_PATH" ]; then
  echo "Error: App bundle not found at '$APP_PATH'" >&2
  exit 1
fi

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

DMGBUILD_BIN="$(command -v dmgbuild || true)"
if [ -z "$DMGBUILD_BIN" ]; then
  VENV_DIR="${DMGBUILD_VENV:-/tmp/dmgbuild-venv}"
  if [ ! -x "$VENV_DIR/bin/dmgbuild" ]; then
    echo "Installing dmgbuild into $VENV_DIR..."
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip dmgbuild
  fi
  DMGBUILD_BIN="$VENV_DIR/bin/dmgbuild"
fi

REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

"$DMGBUILD_BIN" \
  -s "$SCRIPT_DIR/dmg_settings.py" \
  -D "repo_root=$REPO_ROOT" \
  -D "app_path=$APP_PATH" \
  "Chicken Fork" \
  "$DMG_PATH"

sync
