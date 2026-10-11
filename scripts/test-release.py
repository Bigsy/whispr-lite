#!/usr/bin/env python3
"""Release regression checks: synthetic inputs, no certificates, network or login items."""
import importlib.util
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


packaging = module('packaging', 'package-release.py')
planning = module('planning', 'release-plan.py')
local_http = module('local_http', 'local_http.py')


class ReleaseTests(unittest.TestCase):
    def test_local_http_ignores_configured_proxies(self):
        from urllib.request import ProxyHandler
        self.assertFalse(any(isinstance(handler, ProxyHandler) for handler in local_http.LOCAL.handlers))

    def test_stable_tags_require_notarization_and_prereleases_allow_previews(self):
        self.assertEqual(planning.plan('refs/tags/v1.2.3')['RELEASE_CHANNEL'], 'notarized')
        result = planning.plan('refs/tags/v1.2.3-beta.2')
        self.assertEqual(result['RELEASE_CHANNEL'], 'preview')
        self.assertEqual(result['APP_VERSION'], '1.2.3')
        self.assertEqual(planning.plan('refs/heads/main', '1.2.3', 'notarized')['RELEASE_CHANNEL'], 'notarized')

    def test_tag_and_version_injection_and_invalid_channels_are_rejected(self):
        for value in ['1.2.3\nSIGN_IDENTITY=-', '$(whoami)', '../1.2.3', '1.2', 'v1.2.3', '1.2.3-other']:
            with self.assertRaises(ValueError): packaging.version(value)
        with self.assertRaises(ValueError): planning.plan('refs/tags/1.2.3')
        with self.assertRaises(ValueError): planning.plan('refs/heads/main', '1.2.3', 'unknown')

    def test_mismatched_bundle_version_is_rejected_before_packaging(self):
        import plistlib
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            info = root / 'dist/Whispr Lite.app/Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.1.0')))
            with patch.object(packaging, 'ROOT', root), patch.object(packaging, 'command') as command:
                with self.assertRaisesRegex(ValueError, 'APP_VERSION'):
                    packaging.package('0.2.0', 'preview', root / 'output')
                command.assert_not_called()

    def test_notarized_channel_rejects_development_signature_without_submitting(self):
        import plistlib
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            info = root / 'dist/Whispr Lite.app/Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='0.1.0')))
            def command(*arguments):
                return 'arm64' if arguments[0] == '/usr/bin/lipo' else ''
            def archive(app, destination): destination.write_bytes(b'synthetic archive')
            with patch.object(packaging, 'ROOT', root), patch.object(packaging, 'command', side_effect=command), \
                 patch.object(packaging, 'zip_app', side_effect=archive), \
                 patch.object(packaging.subprocess, 'run', return_value=types.SimpleNamespace(stderr='Authority=Apple Development: Synthetic\nflags=runtime')):
                with self.assertRaisesRegex(ValueError, 'Developer ID'):
                    packaging.package('0.1.0', 'notarized', root / 'output')
            self.assertEqual(list((root / 'output').iterdir()), [])


if __name__ == '__main__': unittest.main()
