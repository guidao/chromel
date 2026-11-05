"""Failure-path tests for replacing an existing Emacs application."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from bundle_privacy import BLUETOOTH_USAGE_DESCRIPTION, with_bluetooth_usage

spec = importlib.util.spec_from_file_location('install_app', Path(__file__).resolve().parents[1] / 'scripts/install-app.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallerTests(unittest.TestCase):
    def test_runtime_and_cached_private_host_get_bluetooth_declaration(self):
        scripts = Path(__file__).resolve().parents[1] / 'scripts'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'scripts').mkdir()
            for name in ['prepare-host.py', 'package.py']:
                shutil.copy2(scripts / name, root / 'scripts' / name)
            source = root / 'Emacs.app'
            (source / 'Contents/MacOS').mkdir(parents=True)
            (source / 'Contents/MacOS/Emacs').write_bytes(b'original executable')
            original = {'CFBundleIdentifier': 'org.gnu.Emacs', 'NSCameraUsageDescription': 'Keep me'}
            (source / 'Contents/Info.plist').write_bytes(plistlib.dumps(original))
            cef = root / 'cef'
            framework = cef / 'Release' / installer.FRAMEWORK
            framework.mkdir(parents=True)
            (framework / 'Chromium Embedded Framework').write_bytes(b'framework')
            build = root / 'build'
            build.mkdir()
            for name in ['chromel-helper', 'chromel-smoke', 'chromel-module.dylib']:
                (build / name).write_bytes(b'build artifact')
            signed_hosts = []

            def run(command, **kwargs):
                if command[0] == 'ditto':
                    shutil.copytree(command[1], command[2], dirs_exist_ok=True)
                elif command[0] == 'codesign':
                    target = Path(command[-1])
                    if target.name in ['EmacsChromel.app', 'ChromelRuntime.app']:
                        info = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
                        self.assertEqual(info['NSBluetoothAlwaysUsageDescription'], BLUETOOTH_USAGE_DESCRIPTION)
                        signed_hosts.append(target.name)
                else:
                    self.fail(f'Unexpected command: {command}')
                return subprocess.CompletedProcess(command, 0)

            with patch('subprocess.run', side_effect=run), \
                 patch.dict(os.environ, {'EMACS_APP': str(source)}):
                with patch.object(sys, 'argv', ['package.py', str(cef), str(build)]):
                    runpy.run_path(str(root / 'scripts/package.py'), run_name='__main__')
                prepare = str(root / 'scripts/prepare-host.py')
                runpy.run_path(prepare, run_name='__main__')
                host_plist = build / 'EmacsChromel.app/Contents/Info.plist'
                info = plistlib.loads(host_plist.read_bytes())
                self.assertEqual(info['NSCameraUsageDescription'], 'Keep me')
                # Simulate a previously cached host made by the old script.
                del info['NSBluetoothAlwaysUsageDescription']
                host_plist.write_bytes(plistlib.dumps(info))
                marker = build / 'host.json'
                stamp = json.loads(marker.read_text())
                del stamp['bluetooth_usage_description']
                marker.write_text(json.dumps(stamp))
                runpy.run_path(prepare, run_name='__main__')
                self.assertEqual(plistlib.loads(host_plist.read_bytes())['NSBluetoothAlwaysUsageDescription'],
                                 BLUETOOTH_USAGE_DESCRIPTION)
                runpy.run_path(prepare, run_name='__main__')
            self.assertEqual(signed_hosts, ['ChromelRuntime.app', 'EmacsChromel.app', 'EmacsChromel.app'])
            self.assertEqual(plistlib.loads((source / 'Contents/Info.plist').read_bytes()), original)

    def test_bluetooth_description_preserves_existing_configuration(self):
        for value in [None, '', '  ', 42, 'Custom Bluetooth explanation']:
            with self.subTest(value=value):
                original = {'CFBundleIdentifier': 'org.gnu.Emacs',
                            'NSCameraUsageDescription': 'Existing camera explanation',
                            'CustomSetting': {'enabled': True}}
                if value is not None:
                    original['NSBluetoothAlwaysUsageDescription'] = value
                updated = with_bluetooth_usage(original)
                expected = value if value == 'Custom Bluetooth explanation' else BLUETOOTH_USAGE_DESCRIPTION
                self.assertEqual(updated, {**original, 'NSBluetoothAlwaysUsageDescription': expected})
                self.assertEqual(with_bluetooth_usage(updated), updated)
                self.assertEqual(original.get('NSBluetoothAlwaysUsageDescription'), value)

    def test_install_declares_bluetooth_before_signing_and_restore_is_exact(self):
        for purpose, legacy in [(None, False), ('Existing Bluetooth explanation', False), (None, True)]:
            with self.subTest(purpose=purpose, legacy=legacy), tempfile.TemporaryDirectory() as directory:
                parent = Path(directory)
                app = parent / 'Emacs.app'
                (app / 'Contents/MacOS').mkdir(parents=True)
                (app / 'Contents/MacOS/Emacs').write_bytes(b'original executable')
                original = {'CFBundleExecutable': 'Emacs', 'CFBundleIdentifier': 'org.gnu.Emacs',
                            'CFBundleName': 'My Emacs', 'NSCameraUsageDescription': 'Keep camera text'}
                if purpose:
                    original['NSBluetoothAlwaysUsageDescription'] = purpose
                original_bytes = plistlib.dumps(original, fmt=plistlib.FMT_BINARY)
                (app / 'Contents/Info.plist').write_bytes(original_bytes)
                if legacy:
                    (app / installer.LEGACY_MARKER).parent.mkdir(parents=True)
                    (app / installer.LEGACY_MARKER).write_text('{"schema": 1}')
                    for name in [installer.FRAMEWORK, *installer.LEGACY_HELPERS]:
                        (app / 'Contents/Frameworks' / name).mkdir(parents=True)
                runtime = parent / 'Runtime.app'
                for name in installer.COMPONENTS:
                    (runtime / 'Contents/Frameworks' / name).mkdir(parents=True)
                args = SimpleNamespace(app=app, runtime=runtime, module=parent / 'module',
                                       restore=None, dry_run=False)
                signed_hosts = []

                def run(*command):
                    if command[0] == '/usr/bin/ditto':
                        shutil.copytree(command[1], command[2], dirs_exist_ok=True)
                    elif command[0] == '/usr/bin/codesign':
                        target = Path(command[-1])
                        if target.name == 'Emacs.app':
                            data = plistlib.loads((target / 'Contents/Info.plist').read_bytes())
                            self.assertEqual(data, with_bluetooth_usage(original))
                            signed_hosts.append(target)
                    else:
                        self.fail(f'Unexpected command: {command}')
                    return subprocess.CompletedProcess(command, 0, stdout='')

                with patch.object(installer, 'run', side_effect=run), \
                     patch.object(installer, 'running_pids', return_value=[]), \
                     patch.object(installer, 'signature', return_value='Signature=adhoc'), \
                     patch.object(installer, 'check_runtime'), patch.object(installer, 'verify'):
                    installer.install(args)
                    self.assertEqual(len(signed_hosts), 1)
                    self.assertEqual(plistlib.loads((app / 'Contents/Info.plist').read_bytes()),
                                     with_bluetooth_usage(original))
                    backup = next((parent / '.emacs-chromel-backups').glob('*/Emacs.app'))
                    self.assertTrue((app / installer.MARKER).is_file())
                    if legacy:
                        self.assertFalse((app / installer.LEGACY_MARKER).exists())
                        self.assertTrue((backup / installer.LEGACY_MARKER).is_file())
                        for name in installer.LEGACY_HELPERS:
                            self.assertFalse((app / 'Contents/Frameworks' / name).exists())
                            self.assertTrue((backup / 'Contents/Frameworks' / name).is_dir())
                    self.assertEqual((backup / 'Contents/Info.plist').read_bytes(), original_bytes)
                    if purpose:
                        self.assertEqual((app / 'Contents/Info.plist').read_bytes(), original_bytes)
                    args.restore = backup
                    installer.install(args)
                    self.assertEqual((app / 'Contents/Info.plist').read_bytes(), original_bytes)
                    self.assertEqual((app / 'Contents/MacOS/Emacs').read_bytes(), b'original executable')
                    if legacy:
                        self.assertTrue((app / installer.LEGACY_MARKER).is_file())

    def test_failed_replacement_restores_original(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            target, staged, backup = [parent / name for name in ['Emacs.app', 'new.app', 'backup.app']]
            for path, text in [(target, 'original'), (staged, 'new')]:
                path.mkdir()
                (path / 'sentinel').write_text(text)
            rename = Path.rename

            def fail_install(path, destination):
                if path == staged:
                    raise OSError('simulated failed replacement')
                return rename(path, destination)

            with patch.object(Path, 'rename', fail_install):
                with self.assertRaisesRegex(OSError, 'simulated'):
                    installer.replace_app(staged, target, backup)
            self.assertEqual((target / 'sentinel').read_text(), 'original')
            self.assertEqual((staged / 'sentinel').read_text(), 'new')
            self.assertFalse(backup.exists())

    def test_existing_backup_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            backup = parent / 'backup.app'
            backup.mkdir()
            with self.assertRaisesRegex(ValueError, 'already exists'):
                installer.replace_app(parent / 'new.app', parent / 'Emacs.app', backup)
            self.assertTrue(backup.exists())

    def test_process_detection_matches_executable_not_arguments(self):
        app = Path('/Applications/My Emacs.app')
        output = ' 123 /Applications/My Emacs.app/Contents/MacOS/Emacs\n 456 /Applications/Other.app/Contents/MacOS/Emacs\n 789 /usr/bin/python3\n'
        with patch.object(installer, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=output)):
            self.assertEqual(installer.running_pids(app), [123])
            with self.assertRaisesRegex(ValueError, 'Quit this Emacs first'):
                installer.require_stopped(app)

    def test_does_not_silently_remove_developer_identity_or_hardening(self):
        for details in ['Signature size=123\nAuthority=Developer ID Application: Example',
                        'Signature=adhoc\nflags=0x10002(adhoc,runtime)']:
            with patch.object(installer, 'signature', return_value=details):
                with self.assertRaisesRegex(ValueError, 'unsigned/ad-hoc Emacs only'):
                    installer.check_local_signing(Path('/Applications/Emacs.app'))


if __name__ == '__main__':
    unittest.main()
