#!/usr/bin/env python3
"""Synthetic launch validation; invalid probes must exit before normal app setup."""

from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / '.build/arm64-apple-macosx/debug/WhisprLite'


class AppCLITests(unittest.TestCase):
    def test_invalid_probe_arguments_exit_with_usage_status(self):
        cases = [
            (['--ui-preview'], 'output directory'),
            (['--asr-check'], 'model cache path'),
            (['--asr-check', '/tmp', 'invalid'], 'Unknown speech model'),
            (['--readiness-report'], 'output path'),
            (['--batch-flow-check'], 'five arguments'),
            (['--capture-flow-check'], 'requires WAV'),
            (['--capture-flow-check', 'a', 'b', 'c', 'd', 'e', '0'], '1...31 repetitions'),
            (['--smoke-test', '--settings'], 'takes no arguments'),
            (['--unknown'], 'Unknown launch option'),
        ]
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(BINARY), *arguments], capture_output=True,
                                        text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main()
