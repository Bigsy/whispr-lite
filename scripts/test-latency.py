#!/usr/bin/env python3
"""Guard the distinction between visible-text measurements and dispatch timings."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('latency', Path(__file__).with_name('summarize-latency.py'))
latency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(latency)


class LatencyTests(unittest.TestCase):
    def source(self):
        source = {key: 'synthetic' for key in latency.METADATA}
        source.update(schema=1, capture_mode='on-demand', observation_method='video', observations=[])
        for index in range(30):
            source['observations'].append(dict(destination='TextEdit', destination_version='synthetic',
                condition='cold' if index < 5 else 'warm', release_to_visible_ms=100 + index,
                capture_ms=5, asr_ms=30, cleanup_ms=50, insertion_ms=15))
        return source

    def test_groups_cold_and_warm_without_recording_extra_content(self):
        source = self.source()
        source['observations'][0]['transcript'] = 'must never enter the report'
        result = latency.summarize(source)
        self.assertEqual([group['timings']['asr_ms']['n'] for group in result['groups']], [5, 25])
        self.assertEqual(result['overall']['release_to_visible_ms']['p50_ms'], 114.5)
        self.assertEqual(result['overall']['release_to_visible_ms']['p95_ms'], 128)
        self.assertNotIn('must never', str(result))

    def test_rejects_dispatch_only_incomplete_and_nonfinite_observations(self):
        for invalid in ('dispatch', 'short', 'nan'):
            source = self.source()
            if invalid == 'dispatch': source['observation_method'] = 'paste-dispatch'
            if invalid == 'short': source['observations'].pop()
            if invalid == 'nan': source['observations'][0]['release_to_visible_ms'] = float('nan')
            with self.assertRaises(ValueError): latency.summarize(source)


if __name__ == '__main__':
    unittest.main()
