#!/usr/bin/env python3
"""Explicitly configure the native app from an exported cleanup profile; preserve existing private text."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import sys
from cleanup_bench import SERVICE_PORT, loopback_url


def configure(destination, source, cache, endpoint):
    endpoint = loopback_url(endpoint)
    if not cache.is_dir(): raise ValueError('ASR cache directory does not exist')
    metadata = json.loads((source / 'cleanup-import.json').read_text())
    if metadata['cleanupInputFormat'] != 'openWhispr': raise ValueError('Unrecognized imported input format')
    private = {name: (source / name).read_bytes() for name in ['prompt.txt', 'dictionary.txt']}
    if max(map(len, private.values())) > 16384 or len(metadata['cleanupDictionaryPrefix'].encode()) > 2048:
        raise ValueError('Private settings exceed the app limits')
    for name, content in private.items():
        if (destination / name).exists() and (destination / name).read_bytes() != content:
            raise ValueError(f'Existing {name} differs; review migration explicitly before replacing it')
    preferences = destination / 'preferences.json'
    value = json.loads(preferences.read_text()) if preferences.exists() else dict(version=1, backend='parakeet')
    if value.get('version') != 1: raise ValueError('Unsupported preferences version')
    value.update(asrModelDirectory=str(cache), allowASRDownloads=False, cleanupEndpoint=endpoint,
                 cleanupInputFormat='openWhispr', cleanupDictionaryPrefix=metadata['cleanupDictionaryPrefix'])
    destination.mkdir(parents=True, exist_ok=True, mode=0o700); destination.chmod(0o700)
    if preferences.exists():
        backup = destination / 'Backups' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        backup.mkdir(parents=True, mode=0o700)
        for name in ['preferences.json', 'prompt.txt', 'dictionary.txt']:
            if (destination / name).exists():
                shutil.copyfile(destination / name, backup / name); (backup / name).chmod(0o600)
    for name, content in {**private, 'preferences.json': (json.dumps(value, indent=2) + '\n').encode()}.items():
        temporary = destination / f'.{name}.tmp'
        with temporary.open('wb') as file: file.write(content)
        temporary.chmod(0o600); temporary.replace(destination / name)
    print('Native app configured: owned ASR cache and imported local cleanup; private contents not logged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--import-directory', type=Path, required=True)
    parser.add_argument('--asr-cache', type=Path, required=True)
    parser.add_argument('--endpoint', default=f'http://127.0.0.1:{SERVICE_PORT}')
    parser.add_argument('--destination', type=Path, default=Path.home() / 'Library/Application Support/WhisprLite')
    args = parser.parse_args()
    try: configure(args.destination.resolve(), args.import_directory.resolve(), args.asr_cache.resolve(), args.endpoint)
    except (OSError, ValueError, KeyError) as error:
        print(f'Configuration failed: {error}', file=sys.stderr); sys.exit(1)
