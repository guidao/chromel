#!/usr/bin/env python3
"""Create a private Emacs bundle with CEF inside its sandbox-readable bundle."""
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(os.environ.get("EMACS_APP", "/Applications/Emacs.app")).resolve()
build = root / "build"
runtime = build / "WebRuntime.app"
host = build / "EmacsWeb.app"
marker = build / "host.json"
if not (source / "Contents/MacOS/Emacs").is_file():
    raise SystemExit("Set EMACS_APP to a Cocoa Emacs.app bundle")
if not (runtime / "Contents/Frameworks").is_dir():
    raise SystemExit("Run scripts/build.sh first")
stamp = {
    "source": str(source),
    "binary": hashlib.sha256((source / "Contents/MacOS/Emacs").read_bytes()).hexdigest(),
    "plist": hashlib.sha256((source / "Contents/Info.plist").read_bytes()).hexdigest(),
    "helper": (build / "web-helper").stat().st_mtime_ns,
    "framework": (runtime / "Contents/Frameworks/Chromium Embedded Framework.framework/Chromium Embedded Framework").stat().st_mtime_ns,
}
if not (marker.is_file() and host.is_dir() and json.loads(marker.read_text()) == stamp):
    if host.exists() and not marker.exists():
        raise SystemExit(f"Refusing to overwrite an unmarked existing bundle: {host}")
    print("Preparing a private Emacs + CEF bundle (original Emacs.app is unchanged)", file=sys.stderr)
    subprocess.run(["ditto", str(source), str(host)], check=True)
    subprocess.run(["ditto", str(runtime / "Contents/Frameworks"),
                    str(host / "Contents/Frameworks")], check=True)
    path = host / "Contents/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleIdentifier="org.emacs.web.host", CFBundleName="Emacs Web",
                CFBundleDisplayName="Emacs Web")
    path.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(host)], check=True)
    marker.write_text(json.dumps(stamp, indent=2) + "\n")
print(host)
