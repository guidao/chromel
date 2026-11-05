#!/usr/bin/env python3
"""Install the built CEF runtime into an existing Cocoa Emacs.app, with a backup."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from bundle_privacy import with_bluetooth_usage

ROOT = Path(__file__).resolve().parent.parent
FRAMEWORK = 'Chromium Embedded Framework.framework'
HELPERS = ['Chromel Helper' + suffix + '.app' for suffix in ['', ' (Alerts)', ' (GPU)', ' (Plugin)', ' (Renderer)']]
COMPONENTS = [FRAMEWORK, *HELPERS]
MARKER = Path('Contents/Resources/emacs-chromel-runtime.json')
LEGACY_MARKER = Path('Contents/Resources/emacs-web-runtime.json')
LEGACY_HELPERS = [name.replace('Chromel Helper', 'Web Helper') for name in HELPERS]


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True)


def bundle_info(app):
    if not app.is_dir() or app.suffix != '.app':
        raise ValueError(f'Not an application bundle: {app}')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleExecutable') != 'Emacs' or not (app / 'Contents/MacOS/Emacs').is_file():
        raise ValueError(f'Expected a Cocoa Emacs.app with Contents/MacOS/Emacs: {app}')
    return info


def running_pids(app):
    # comm is the full executable path on macOS. Do not search command arguments:
    # the installer itself contains the target path in its arguments.
    output = run('/bin/ps', '-axo', 'pid=,comm=').stdout
    executable = (app / 'Contents/MacOS/Emacs').resolve()
    pids = []
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith('/') and Path(parts[1]).resolve() == executable:
            pids.append(int(parts[0]))
    return pids


def require_stopped(app):
    pids = running_pids(app)
    if pids:
        raise ValueError(f'Quit this Emacs first (PID {", ".join(map(str, pids))}): {app}')


def signature(app):
    result = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=2', str(app)], capture_output=True, text=True)
    if result.returncode:
        if 'not signed at all' in result.stderr:
            return None
        raise ValueError(result.stderr.strip())
    return result.stderr


def check_local_signing(app):
    details = signature(app)
    # This installer is intentionally for local unsigned/ad-hoc Emacs builds.
    # Do not silently replace a Developer ID identity or weaken hardened runtime.
    flags = re.search(r'flags=0x([0-9a-fA-F]+)', details or '')
    hardened = bool(flags and int(flags.group(1), 16) & 0x10000)
    if details and ('Signature=adhoc' not in details or hardened):
        raise ValueError('This installer supports unsigned/ad-hoc Emacs only. '
                         'Use the private host for a Developer ID or hardened-runtime app.')
    return details


def verify(app, deep=False):
    run('/usr/bin/codesign', '--verify', '--strict', *(['--deep'] if deep else []), app)


def check_runtime(runtime, module, app):
    arch = platform.machine()
    binaries = [app / 'Contents/MacOS/Emacs', module,
                runtime / 'Contents/Frameworks' / FRAMEWORK / 'Chromium Embedded Framework']
    for name in HELPERS:
        binaries.append(runtime / 'Contents/Frameworks' / name / 'Contents/MacOS' / name[:-4])
    for binary in binaries:
        if not binary.is_file():
            raise ValueError(f'Missing build artifact: {binary}; run scripts/build.sh first')
        if arch not in run('/usr/bin/lipo', '-archs', binary).stdout.split():
            raise ValueError(f'{binary} does not support this installer architecture: {arch}')
    # CEF binary distributions carry a linker signature, not a sealed framework
    # bundle. Seal the copied framework during staging; verify built Helpers now.
    for name in HELPERS:
        verify(runtime / 'Contents/Frameworks' / name, deep=True)
    verify(module)


def target_fingerprint(app):
    return tuple(hashlib.sha256((app / part).read_bytes()).hexdigest()
                 for part in ['Contents/MacOS/Emacs', 'Contents/Info.plist'])


def replace_app(staged, target, backup):
    """Keep the original bundle intact and restore it if the second rename fails."""
    if backup.exists():
        raise ValueError(f'Backup already exists: {backup}')
    try:
        target.rename(backup)
        staged.rename(target)
    except BaseException:
        if backup.exists() and not target.exists():
            backup.rename(target)
        raise


def install(args):
    requested = args.app.expanduser().absolute()
    app = requested.resolve()
    info = bundle_info(app)
    for part in ['Contents/Info.plist', 'Contents/MacOS/Emacs', 'Contents/Resources', 'Contents/Frameworks']:
        if not (app / part).resolve().is_relative_to(app):
            raise ValueError(f'{part} resolves outside the app bundle')
    original = target_fingerprint(app)
    source = args.restore.expanduser().resolve() if args.restore else None
    signed = None
    if source:
        source_info = bundle_info(source)
        if source_info.get('CFBundleIdentifier') != info.get('CFBundleIdentifier'):
            raise ValueError('Backup and target have different bundle identifiers')
        if source == app or app in source.parents or source in app.parents:
            raise ValueError('Backup must be separate from the target app')
        if signature(source):
            verify(source, deep=True)
    else:
        signed = check_local_signing(app)
        check_runtime(args.runtime, args.module, app)
        frameworks = app / 'Contents/Frameworks'
        if frameworks.is_symlink():
            raise ValueError('Contents/Frameworks must be a real directory inside the app')
        existing = [name for name in [*COMPONENTS, *LEGACY_HELPERS] if os.path.lexists(frameworks / name)]
        if existing and not any((app / marker).is_file() for marker in [MARKER, LEGACY_MARKER]):
            raise ValueError(f'Unmanaged CEF components already exist: {existing}')
    print(f'Target: {app}')
    if requested != app:
        print(f'Application link: {requested} -> {app}')
    print(f'Bundle ID: {info.get("CFBundleIdentifier")} (preserved)')
    print(f'Action: restore {source}' if source else
          'Action: embed CEF + five Helpers; add missing Bluetooth usage description; '
          'preserve other Info.plist values; re-sign locally')
    pids = running_pids(app)
    if args.dry_run:
        print(f'Running PIDs: {pids or "none"}; installation requires this app to be stopped')
        print('Dry run complete. No application files changed.')
        return
    require_stopped(app)
    # Prepare and validate on the target filesystem before touching the original.
    with tempfile.TemporaryDirectory(prefix='.emacs-chromel-install-', dir=app.parent) as directory:
        staged = Path(directory) / app.name
        run('/usr/bin/ditto', source or app, staged)
        if not source:
            for part in ['Contents/Info.plist', 'Contents/MacOS/Emacs', 'Contents/Resources', 'Contents/Frameworks']:
                if not (staged / part).resolve().is_relative_to(staged):
                    raise ValueError(f'Staged {part} resolves outside the copied app')
            frameworks = staged / 'Contents/Frameworks'
            frameworks.mkdir(parents=True, exist_ok=True)
            # Upgrade the old Web installation only in the backed-up staging copy.
            if (staged / LEGACY_MARKER).is_file():
                for name in LEGACY_HELPERS:
                    destination = frameworks / name
                    if destination.is_symlink() or destination.is_file():
                        destination.unlink()
                    elif destination.exists():
                        shutil.rmtree(destination)
                (staged / LEGACY_MARKER).unlink()
            for name in COMPONENTS:
                destination = frameworks / name
                if destination.is_symlink() or destination.is_file():
                    destination.unlink()
                elif destination.exists():
                    shutil.rmtree(destination)
                run('/usr/bin/ditto', args.runtime / 'Contents/Frameworks' / name, destination)
            run('/usr/bin/codesign', '--force', '--sign', '-', frameworks / FRAMEWORK)
            marker = staged / MARKER
            if marker.is_symlink():
                raise ValueError('Runtime marker must not be a symlink')
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(json.dumps({'schema': 1, 'project': str(ROOT),
                                         'runtime': str(args.runtime),
                                         'installed': datetime.now().isoformat()}, indent=2) + '\n')
            # TCC terminates the entire host if Chromium probes Bluetooth for
            # passkeys without a purpose string. Write it before signing.
            expected_info = with_bluetooth_usage(info)
            plist_path = staged / 'Contents/Info.plist'
            if expected_info != info:
                plist_path.write_bytes(plistlib.dumps(expected_info))
            command = ['/usr/bin/codesign', '--force', '--sign', '-']
            if signed:
                command.append('--preserve-metadata=identifier,entitlements,requirements,flags,runtime')
            run(*command, staged)
            verify(staged, deep=True)
            if plistlib.loads(plist_path.read_bytes()) != expected_info:
                raise ValueError('Installation unexpectedly changed Info.plist beyond the Bluetooth usage description')
        # Recheck after copying/signing, in case Emacs was started or updated.
        require_stopped(app)
        if target_fingerprint(app) != original:
            raise ValueError('Target changed during installation; no replacement performed')
        backup_root = app.parent / '.emacs-chromel-backups'
        backup_root.mkdir(exist_ok=True)
        backup_dir = Path(tempfile.mkdtemp(prefix=datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=backup_root))
        backup = backup_dir / app.name
        replace_app(staged, app, backup)
    print(f'Installed: {app}')
    print(f'Backup: {backup}')
    if not source:
        print('Start Emacs normally. Configure load-path and (require \'chromel) in your init file.')
    print('Restore by running this script with the same target and --restore BACKUP_PATH.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', nargs='?', type=Path, default=Path(os.environ.get('EMACS_APP', '/Applications/Emacs.app')))
    parser.add_argument('--runtime', type=Path, default=ROOT / 'build/ChromelRuntime.app')
    parser.add_argument('--module', type=Path, default=ROOT / 'build/chromel-module.dylib')
    parser.add_argument('--dry-run', action='store_true', help='Validate and report without modifying the app')
    parser.add_argument('--restore', type=Path, metavar='BACKUP', help='Restore a previously backed-up app; keep a backup of the current one')
    args = parser.parse_args()
    args.runtime = args.runtime.expanduser().resolve()
    args.module = args.module.expanduser().resolve()
    try:
        install(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) and error.stderr else str(error)
        parser.exit(1, f'Install failed: {detail}\n')


if __name__ == '__main__':
    main()
