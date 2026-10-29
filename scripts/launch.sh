#!/bin/bash
set -euo pipefail
WEB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -f "$WEB_ROOT/build/web-module.dylib" ]]; then
  "$WEB_ROOT/scripts/build.sh"
fi
WEB_HOST="$(python3 "$WEB_ROOT/scripts/prepare-host.py")"
exec "$WEB_HOST/Contents/MacOS/Emacs" "$@" -L "$WEB_ROOT" -l web
