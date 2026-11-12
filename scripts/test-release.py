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
import base64
import plistlib
import sparkle_updates
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


class AppUpdateTests(unittest.TestCase):
    def info(self):
        return dict(SUPublicEDKey=base64.b64encode(bytes(range(32))).decode(),
                    SUFeedURL='https://example.com/appcast.xml', CFBundleVersion='5')

    def test_unconfigured_build_is_manual_but_partial_configuration_is_rejected(self):
        self.assertFalse(sparkle_updates.validate_configuration({}))
        for missing in ['SUPublicEDKey', 'SUFeedURL']:
            info = self.info()
            del info[missing]
            with self.assertRaisesRegex(ValueError, 'both'):
                sparkle_updates.validate_configuration(info)

    def test_update_configuration_rejects_invalid_keys_urls_and_build_numbers(self):
        for field, values in {
            'SUPublicEDKey': ['not base64', base64.b64encode(b'too short').decode()],
            'SUFeedURL': ['http://example.com/appcast.xml', 'https://user:pass@example.com/appcast.xml',
                          'https://example.com/appcast.xml?token=private', 'https://example.com/releases'],
            'CFBundleVersion': ['0', '-1', '1.2', 'five'],
        }.items():
            for value in values:
                with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                    sparkle_updates.validate_configuration({**self.info(), field: value})
        self.assertTrue(sparkle_updates.validate_configuration(self.info()))

    def test_configuration_preserves_bundle_metadata_and_rejects_before_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'Info.plist'
            path.write_bytes(plistlib.dumps(dict(CFBundleVersion='5', CFBundleIdentifier='test.app')))
            original = path.read_bytes()
            with self.assertRaises(ValueError):
                sparkle_updates.configure(path, dict(SPARKLE_FEED_URL='https://example.com/appcast.xml'))
            self.assertEqual(path.read_bytes(), original)
            sparkle_updates.configure(path, dict(SPARKLE_FEED_URL=self.info()['SUFeedURL'],
                                                SPARKLE_PUBLIC_ED_KEY=self.info()['SUPublicEDKey']))
            configured = plistlib.loads(path.read_bytes())
            self.assertEqual(configured['CFBundleIdentifier'], 'test.app')
            self.assertTrue(sparkle_updates.validate_configuration(configured))

    def test_wrong_signing_key_is_rejected(self):
        with patch.object(sparkle_updates, 'run', return_value=base64.b64encode(b'x' * 32).decode()):
            with self.assertRaisesRegex(ValueError, 'does not match'):
                sparkle_updates.verify_signing_key(self.info(), 'test-account')

    def test_appcast_uses_only_the_dmg_and_verifies_feed_signature(self):
        for alteration in [None, 'unsigned', 'wrong-version', 'wrong-download', 'wrong-length']:
            with self.subTest(alteration=alteration), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                dmg = output / 'WhisprLite-0.1.0-beta.5-preview-arm64.dmg'
                dmg.write_bytes(b'synthetic disk image')
                (output / 'Cleanup-Setup.zip').write_bytes(b'never an app update')
                appcast = output / 'appcast.xml'
                def run(*arguments):
                    if Path(arguments[0]).name == 'generate_appcast':
                        archives = Path(arguments[-1])
                        self.assertEqual([p.name for p in archives.iterdir()], [dmg.name])
                        prefix = arguments[arguments.index('--download-url-prefix') + 1]
                        self.assertEqual(prefix, 'https://github.com/Bigsy/whispr-lite/releases/download/v0.1.0-beta.5/')
                        signature = '' if alteration == 'unsigned' else 'sparkle:edSignature="synthetic"'
                        version = '4' if alteration == 'wrong-version' else '5'
                        url = 'https://elsewhere.test/other.dmg' if alteration == 'wrong-download' else prefix + dmg.name
                        length = 1 if alteration == 'wrong-length' else dmg.stat().st_size
                        appcast.write_text(f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                            f'<channel><item><sparkle:version>{version}</sparkle:version>'
                            f'<enclosure url="{url}" length="{length}" {signature}/></item></channel></rss>')
                    return ''
                with patch.object(sparkle_updates, 'run', side_effect=run) as command:
                    if alteration:
                        with self.assertRaisesRegex(ValueError, 'does not match'):
                            sparkle_updates.generate_appcast(dmg, appcast, self.info(), '0.1.0-beta.5', 'test-account')
                    else:
                        sparkle_updates.generate_appcast(dmg, appcast, self.info(), '0.1.0-beta.5', 'test-account')
                        self.assertEqual(command.call_args.args,
                            (sparkle_updates.TOOLS / 'sign_update', '--account', 'test-account', '--verify', appcast))


if __name__ == '__main__': unittest.main()
