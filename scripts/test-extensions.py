#!/usr/bin/env python3
"""Opt-in live Web Store test. Installs JSON Formatter in a disposable profile."""
import argparse
import http.server
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--host', type=Path, help='Existing prepared EmacsChromel.app (default: prepare the project host)')
args = parser.parse_args()
subprocess.run(['cmake', '-S', str(root), '-B', str(root / 'build')], check=True)
subprocess.run(['cmake', '--build', str(root / 'build'), '--target', 'chromel-ui-probe'], check=True)
host = args.host or Path(subprocess.check_output(['python3', str(root / 'scripts/prepare-host.py')], text=True).strip())

class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"chromel_extension_test":true,"values":[1,2,3]}'
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='chromel-extensions-test-') as temp:
        for phase in ['seed', 'restore']:
            result = Path(temp) / 'result'
            result.unlink(missing_ok=True)
            env = dict(os.environ, CHROMEL_CEF_TEST_MODE='1', CHROMEL_TEST_PROFILE=temp + '/profile',
                       CHROMEL_TEST_RESULT=str(result), CHROMEL_TEST_EXTENSION_PHASE=phase,
                       CHROMEL_TEST_URL=f'http://127.0.0.1:{server.server_port}/data.json')
            log = Path(temp) / f'{phase}.log'
            with log.open('w') as out:
                process = subprocess.Popen([str(host / 'Contents/MacOS/Emacs'), '-Q',
                    '--eval', '(setq native-comp-jit-compilation nil)', '-L', str(root),
                    '-l', str(root / 'test/gui-extensions.el'),
                    '--eval', '(setq command-line-args-left nil)', '-ApplePersistenceIgnoreState', 'YES'],
                    env=env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
                try:
                    status = process.wait(timeout=150)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    status = 124
            output = log.read_text()
            print(output, flush=True)
            outcome = result.read_text() if result.exists() else 'FAIL: no result'
            print(outcome, flush=True)
            if status or not outcome.startswith('PASS:'):
                ceflog = Path(temp) / 'profile/profile/cef.log'
                if ceflog.exists(): print(ceflog.read_text()[-4000:], flush=True)
                raise SystemExit(status or 1)
            assert 'Chromel: skipping CefShutdown' not in output, 'Unclosed extension browsers'
        print('PASS: store installation, restart, embedded effect, disable/re-enable, uninstall and clean shutdown')
finally:
    server.shutdown()
    server.server_close()
