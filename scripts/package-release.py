#!/usr/bin/env python3
"""Package an already checked app using an explicit allowlist, without local data/models."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def setup_files():
    """The standalone cleanup kit: the service, its lock and every file its runner copies."""
    spec = importlib.util.spec_from_file_location('cleanup_service', ROOT / 'scripts/cleanup-service.py')
    service = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(service)
    return ['scripts/cleanup-service.py', 'Resources/cleanup-stack.json', 'Resources/RELEASE-INSTALL.md',
            *service.RUNNER_FILES]


def version(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-(?:alpha|beta|rc)\.\d+)?', value):
        raise ValueError('Use a version such as 0.1.0 or 0.1.0-beta.1')
    return value.split('-')[0]


def command(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(256 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def failure_message(error):
    if isinstance(error, subprocess.CalledProcessError):
        tool = Path(error.cmd[0] if isinstance(error.cmd, (list, tuple)) else error.cmd).name
        tail = '\n'.join((error.stderr or '').splitlines()[-8:]).strip()
        return f'{tool} exited with status {error.returncode}' + (f':\n{tail}' if tail else '')
    if isinstance(error, ValueError):
        return str(error)
    return f'{type(error).__name__}: {error}'


def zip_app(app, destination):
    command('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(destination))


def package(release_version, channel, output, notary_profile=None):
    numeric = version(release_version)
    source = ROOT / 'dist/Whispr Lite.app'
    info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
    if info['CFBundleShortVersionString'] != numeric:
        raise ValueError('Build with APP_VERSION matching the release before packaging')
    command('/usr/bin/codesign', '--verify', '--deep', '--strict', str(source))
    if command('/usr/bin/lipo', '-archs', str(source / 'Contents/MacOS/WhisprLite')).strip() != 'arm64':
        raise ValueError('Release must contain an arm64 app')
    output.mkdir(parents=True, exist_ok=True)
    suffix = '-preview' if channel == 'preview' else ''
    app_zip = output / f'WhisprLite-{release_version}{suffix}-arm64.zip'
    setup_zip = output / f'WhisprLite-{release_version}-Cleanup-Setup.zip'
    manifest_path = output / f'WhisprLite-{release_version}{suffix}-manifest.json'
    checksums = output / f'WhisprLite-{release_version}{suffix}-SHA256SUMS.txt'
    if any(p.exists() for p in [app_zip, setup_zip, manifest_path, checksums]):
        raise ValueError('Release files already exist; choose an empty output directory')
    with tempfile.TemporaryDirectory(prefix='whispr-package-') as temporary:
        staging = Path(temporary)
        app = staging / source.name
        shutil.copytree(source, app, symlinks=True)
        candidate = staging / 'app.zip'
        zip_app(app, candidate)
        if channel == 'notarized':
            signature = subprocess.run(['/usr/bin/codesign', '-dv', '--verbose=4', str(app)],
                                       check=True, text=True, capture_output=True).stderr
            if 'Authority=Developer ID Application:' not in signature or 'runtime' not in signature:
                raise ValueError('Notarized releases require Developer ID and hardened runtime')
            auth = ['--keychain-profile', notary_profile] if notary_profile else [
                '--key', os.environ['APPLE_NOTARY_KEY_FILE'], '--key-id', os.environ['ASC_KEY_ID'],
                '--issuer', os.environ['ASC_ISSUER_ID']]
            result = json.loads(command('xcrun', 'notarytool', 'submit', str(candidate), *auth,
                                        '--wait', '--timeout', '15m', '--output-format', 'json'))
            if result.get('status') != 'Accepted':
                raise ValueError('Apple notarization was not accepted; inspect the notary submission log')
            command('xcrun', 'stapler', 'staple', str(app))
            command('xcrun', 'stapler', 'validate', str(app))
            command('/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=2', str(app))
            candidate.unlink()
            zip_app(app, candidate)
        # Test the exact archived bundle, including resource lookup and framework symlinks.
        unpacked = staging / 'unpacked'
        command('/usr/bin/ditto', '-x', '-k', str(candidate), str(unpacked))
        extracted = unpacked / source.name
        command('/usr/bin/codesign', '--verify', '--deep', '--strict', str(extracted))
        command(str(extracted / 'Contents/MacOS/WhisprLite'), '--smoke-test')
        shutil.move(candidate, app_zip)
    # A small, standalone setup kit; no source checkout or Swift build is required.
    with zipfile.ZipFile(setup_zip, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name in setup_files():
            archive.write(ROOT / name, 'WhisprLite-Cleanup-Setup/' + name)
    commit = command('git', '-C', str(ROOT), 'rev-parse', 'HEAD').strip()
    artifacts = [{ 'file': p.name, 'bytes': p.stat().st_size, 'sha256': digest(p) }
                 for p in [app_zip, setup_zip]]
    manifest_path.write_text(json.dumps(dict(schema=1, version=release_version, channel=channel,
        commit=commit, source_dirty=bool(command('git', '-C', str(ROOT), 'status', '--porcelain').strip()),
        architecture='arm64', minimum_macos=info['LSMinimumSystemVersion'],
        notarized=channel == 'notarized', cleanup_setup_requires_python='3.9+',
        model_weights_included=False, artifacts=artifacts), indent=2) + '\n')
    artifacts.append(dict(file=manifest_path.name, sha256=digest(manifest_path)))
    checksums.write_text(''.join(f"{a['sha256']}  {a['file']}\n" for a in artifacts))
    print(f'Packaged {release_version} ({channel}) in {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version', required=True)
    parser.add_argument('--channel', choices=['preview', 'notarized'], default='preview')
    parser.add_argument('--output-directory', type=Path, default=ROOT / 'dist/releases')
    parser.add_argument('--notary-profile')
    args = parser.parse_args()
    try:
        package(args.version, args.channel, args.output_directory, args.notary_profile)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f'Release packaging failed: {failure_message(error)}\n')
