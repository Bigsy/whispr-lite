#!/usr/bin/env python3
"""Synthetic CLI validation: rejects bad arguments before model or private-file use."""

from pathlib import Path
import subprocess
import tempfile
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

    def test_missing_vad_model_reports_benchmark_error(self):
        with tempfile.TemporaryDirectory() as cache:
            result = subprocess.run([str(BINARY), '--vad-trim-prototype', cache, cache,
                                     cache, str(Path(cache) / 'report.json')],
                                    capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Silero VAD is not cached', result.stderr)
        self.assertIn('Add --allow-model-downloads', result.stderr)


if __name__ == '__main__':
    unittest.main()
