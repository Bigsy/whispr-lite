#!/usr/bin/env python3
"""Synthetic CLI validation: rejects bad arguments before model or private-file use."""

from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / '.build/arm64-apple-macosx/debug/whispr-bench'


class BenchCLITests(unittest.TestCase):
    def test_invalid_arguments_exit_with_usage_status(self):
        cases = [[], ['--parakeet-check'], ['--unknown'], ['--dictionary-check', '--typo'],
                 ['--parakeet-check', '/tmp', '/tmp', '/tmp', '--repetitions', 'abc'],
                 ['--parakeet-check', '/tmp', '/tmp', '/tmp', '--repetitions', '0'],
                 ['--parakeet-check', '/tmp', '/tmp', '/tmp', '--model', 'unknown'],
                 ['--streaming-prototype', '/tmp', '/tmp', '/tmp', '--repetitions', 'abc']]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(BINARY), *arguments], capture_output=True,
                                        text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertIn('Check failed:', result.stderr)
                self.assertNotIn('Preparing ', result.stdout)


if __name__ == '__main__':
    unittest.main()
