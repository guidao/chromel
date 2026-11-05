#!/bin/bash
set -euo pipefail
CHROMEL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -f "$CHROMEL_ROOT/build/chromel-module.dylib" ]]; then
  "$CHROMEL_ROOT/scripts/build.sh"
fi
CHROMEL_HOST="$(python3 "$CHROMEL_ROOT/scripts/prepare-host.py")"
exec "$CHROMEL_HOST/Contents/MacOS/Emacs" "$@" -L "$CHROMEL_ROOT" -l chromel
