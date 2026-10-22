#!/usr/bin/env python3
"""Release regression checks: synthetic inputs, no certificates, network or login items."""
import importlib.util
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import shutil
import types
import unittest
from unittest.mock import patch


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


packaging = module('packaging', 'package-release.py')
local_http = module('local_http', 'local_http.py')


class ReleaseTests(unittest.TestCase):
    def test_disk_image_holds_the_app_beside_an_applications_link_and_detaches(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'Whispr Lite.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/MacOS/WhisprLite').write_text('synthetic')
            image = Path(temporary) / 'synthetic.dmg'
            packaging.make_dmg(app, image)
            with packaging.mounted(image) as volume:
                self.assertEqual(sorted(path.name for path in volume.iterdir() if not path.name.startswith('.')),
                                 ['Applications', 'Whispr Lite.app'])
                self.assertEqual(os.readlink(volume / 'Applications'), '/Applications')
                self.assertEqual((volume / 'Whispr Lite.app/Contents/MacOS/WhisprLite').read_text(), 'synthetic')
            self.assertFalse(volume.exists())

    def test_cleanup_setup_kit_runs_without_a_checkout(self):
        root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory() as temporary:
            kit, models = Path(temporary) / 'WhisprLite-Cleanup-Setup', Path(temporary) / 'Cleanup'
            for name in packaging.setup_files():
                (kit / name).parent.mkdir(parents=True, exist_ok=True)
                (kit / name).write_bytes((root / name).read_bytes())
            helper = kit / 'Whispr Lite Cleanup'
            shutil.copy2(root / '.build/debug/WhisprLiteCleanup', helper)
            for arguments in (['--help'], ['status', '--directory', str(models)]):
                result = subprocess.run([str(helper), *arguments], capture_output=True, text=True,
                                        env={**os.environ, 'PATH': '/nonexistent'})
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('"status":"installed"', result.stdout)
            self.assertFalse(models.exists())
            self.assertFalse(any(name.endswith('.py') for name in packaging.setup_files()))

    def test_packaging_errors_name_the_failed_step_and_stream_hashes(self):
        self.assertEqual(packaging.failure_message(ValueError('Synthetic version mismatch')),
                         'Synthetic version mismatch')
        failed = subprocess.CalledProcessError(7, ['/usr/bin/codesign', '--verify'],
                                               stderr='first line\nlast synthetic failure')
        self.assertEqual(packaging.failure_message(failed),
                         'codesign exited with status 7:\nfirst line\nlast synthetic failure')
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / 'synthetic-archive.zip'
            content = b'synthetic release bytes' * 20_000
            file.write_bytes(content)
            self.assertEqual(packaging.digest(file), hashlib.sha256(content).hexdigest())

    def test_local_http_ignores_configured_proxies(self):
        from urllib.request import ProxyHandler
        self.assertFalse(any(isinstance(handler, ProxyHandler) for handler in local_http.LOCAL.handlers))

    def test_version_injection_is_rejected(self):
        for value in ['1.2.3\nSIGN_IDENTITY=-', '$(whoami)', '../1.2.3', '1.2', 'v1.2.3', '1.2.3-other']:
            with self.assertRaises(ValueError): packaging.version(value)

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
