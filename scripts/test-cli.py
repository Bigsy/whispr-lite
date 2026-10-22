#!/usr/bin/env python3
"""Synthetic launch validation for the app and bench binaries: invalid arguments must exit
before normal app setup, model loading or private-file use."""

from pathlib import Path
import fcntl
import hashlib
import json
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
# SwiftPM's debug link follows the current target triple, including SDK changes.
# A hard-coded triple can silently exercise an executable left by an older build.
APP = ROOT / '.build/debug/WhisprLite'
CLEANUP = ROOT / '.build/debug/WhisprLiteCleanup'


def run(binary, *arguments):
    return subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=10)


class AppCLITests(unittest.TestCase):
    def test_invalid_probe_arguments_exit_with_usage_status(self):
        cases = [
            (['--smoke-test', '--settings'], 'takes no arguments'),
            (['--settings', '--settings'], 'takes no arguments'),
            (['--ui-preview'], 'Unknown launch option'),
            (['--benchmark-window'], 'Unknown launch option'),
            (['--unknown'], 'Unknown launch option'),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = run(APP, *arguments)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, '')


class CleanupCLITests(unittest.TestCase):
    def test_closed_app_progress_pipe_cannot_kill_the_native_helper(self):
        process = subprocess.Popen([str(CLEANUP), '--unknown'], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        process.stderr.close()
        process.wait(timeout=5)
        self.assertEqual(process.returncode, 2)
        process.stdout.close()

    def test_invalid_arguments_never_create_the_service_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'untouched'
            for arguments in [[], ['install', '--port', '0'], ['prepare', '--rounds', '11'],
                              ['status', '--typo'], ['prepare', '--directory'], ['run', '--port', '70000']]:
                result = run(CLEANUP, *arguments, '--directory', str(directory))
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertFalse(directory.exists())

    def test_native_helper_cancels_hashing_and_releases_its_operation_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            kit, directory = root / 'kit', root / 'Cleanup'
            (kit / 'Resources').mkdir(parents=True)
            directory.mkdir()
            lock = json.loads((ROOT / 'Resources/cleanup-stack.json').read_text())
            lock['artifacts']['model'] = dict(file='synthetic.gguf', bytes=2_000_000_000,
                                             sha256=hashlib.sha256(b'synthetic').hexdigest())
            (kit / 'Resources/cleanup-stack.json').write_text(json.dumps(lock))
            # Sparse synthetic bytes: no real model, network request or service is used.
            with (directory / 'synthetic.gguf').open('wb') as file:
                file.truncate(2_000_000_000)
            process = subprocess.Popen([str(CLEANUP), 'prepare', '--kit', str(kit),
                                        '--directory', str(directory), '--progress'],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.assertIn('Checking synthetic.gguf', process.stderr.readline())
                process.terminate()
                output, errors = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 143, errors)
                self.assertEqual(output, '')
                self.assertNotIn('data race detected', errors)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)
            with (directory / '.setup.lock').open('rb') as lock_file:
                fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)



if __name__ == '__main__':
    unittest.main()
