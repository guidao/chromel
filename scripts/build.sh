#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This backend requires macOS" >&2
  exit 1
fi
EMACS_BIN="${EMACS:-emacs}"
if [[ -z "${CEF_ROOT:-}" ]]; then
  CEF_ROOT="$(python3 scripts/fetch-cef.py)"
fi
if [[ -z "${EMACS_INCLUDE_DIR:-}" ]]; then
  EMACS_INCLUDE_DIR="$("$EMACS_BIN" -Q --batch --eval '(princ (expand-file-name "include" invocation-directory))')"
  if [[ ! -f "$EMACS_INCLUDE_DIR/emacs-module.h" ]]; then
    EMACS_REAL="$(python3 -c 'import os, shutil, sys; print(os.path.realpath(shutil.which(sys.argv[1]) or sys.argv[1]))' "$EMACS_BIN")"
    EMACS_INCLUDE_DIR="$(dirname "$(dirname "$EMACS_REAL")")/include"
  fi
fi
if [[ ! -f "$EMACS_INCLUDE_DIR/emacs-module.h" ]]; then
  echo 'Set EMACS_INCLUDE_DIR to the directory containing emacs-module.h.' >&2
  exit 1
fi
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCEF_ROOT="$CEF_ROOT" -DEMACS_INCLUDE_DIR="$EMACS_INCLUDE_DIR" \
  -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)"
cmake --build build --parallel "${BUILD_JOBS:-4}"
python3 scripts/package.py "$CEF_ROOT" build
echo 'Ready: ./scripts/launch.sh -Q, then M-x chromel.'
