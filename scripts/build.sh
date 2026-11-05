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
# CMake caches absolute source/build paths, which become stale after a move.
python3 - <<'PY'
from pathlib import Path
import shutil

root = Path.cwd().resolve()
build = root / "build"
cache = build / "CMakeCache.txt"
if cache.is_file():
    paths = {}
    for line in cache.read_text().splitlines():
        key, separator, value = line.partition("=")
        if separator:
            paths[key] = value
    expected = {"CMAKE_HOME_DIRECTORY:INTERNAL": root,
                "CMAKE_CACHEFILE_DIR:INTERNAL": build.resolve()}
    if any(key in paths and Path(paths[key]).resolve() != path
           for key, path in expected.items()):
        print("Project moved; resetting CMake cache for the current directory.")
        cache.unlink()
        if (build / "CMakeFiles").is_dir():
            shutil.rmtree(build / "CMakeFiles")
PY
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCEF_ROOT="$CEF_ROOT" -DEMACS_INCLUDE_DIR="$EMACS_INCLUDE_DIR" \
  -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)"
cmake --build build --parallel "${BUILD_JOBS:-4}"
python3 scripts/package.py "$CEF_ROOT" build
echo 'Ready: ./scripts/launch.sh -Q, then M-x chromel.'
