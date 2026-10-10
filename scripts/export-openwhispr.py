#!/usr/bin/env python3
"""Export only installed OpenWhispr's cleanup prompt/dictionary/settings to private files."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import struct
import sys

spec = importlib.util.spec_from_file_location('chromium_settings', Path(__file__).with_name('chromium-settings.py'))
storage = importlib.util.module_from_spec(spec); spec.loader.exec_module(storage)


class Archive:
    def __init__(self, path):
        self.file = path.open('rb')
        prefix = self.file.read(16)
        length = struct.unpack_from('<I', prefix, 12)[0]
        if length > 16 * 1024 * 1024: raise ValueError('Oversized app archive header')
        self.header = json.loads(self.file.read(length))
        self.start = 8 + struct.unpack_from('<I', prefix, 4)[0]

    def read(self, path):
        entry = self.header
        for component in path.split('/'): entry = entry['files'][component]
        if entry['size'] > 16 * 1024 * 1024: raise ValueError('Oversized archive entry')
        self.file.seek(self.start + int(entry['offset']))
        data = self.file.read(entry['size'])
        if len(data) != entry['size']: raise ValueError('Incomplete archive entry')
        return data


def export(app, source, output):
    selected = ['customPrompt.cleanup', 'customCleanupPrompt', 'customDictionary', 'preferredLanguage',
                'uiLanguage', 'agentName', 'cleanupProvider', 'cleanupModel', 'cleanupCloudBaseUrl',
                'cleanupCloudMode', 'useCleanupModel']
    settings = storage.read_settings(source / 'Local Storage/leveldb', selected)
    archive = Archive(app / 'Contents/Resources/app.asar')
    version = json.loads(archive.read('package.json'))['version']
    if version != '1.8.3':
        raise ValueError('This exporter was checked against OpenWhispr 1.8.3; review changed prompt/request code first')
    locale = settings.get('uiLanguage') or 'en'
    if locale != 'en': raise ValueError('Review locale-specific prompt resolution before exporting this language')
    strings = json.loads(archive.read('src/locales/en/prompts.json'))
    registry = json.loads(archive.read('src/config/languageRegistry.json'))
    language = settings.get('preferredLanguage', '')
    instruction = next((entry.get('instruction', '') for entry in registry['languages']
                        if entry['code'] == language), '')
    if language and not instruction:
        instruction = registry.get('_genericTemplate', '').replace('{{code}}', language)
    template = settings.get('customPrompt.cleanup') or strings['cleanupPrompt']
    if settings.get('customCleanupPrompt') and not settings.get('customPrompt.cleanup'):
        raise ValueError('Legacy custom prompt found; review migration before exporting')
    prompt = template.replace('{{agentName}}', settings.get('agentName', '').strip() or 'Assistant')
    if instruction: prompt += '\n\n' + instruction
    # Immutable read of the SQLite snapshot: no journal, migrations or history queries.
    database = source / 'transcriptions.db'
    with sqlite3.connect(database.as_uri() + '?mode=ro&immutable=1', uri=True) as connection:
        columns = [row[1] for row in connection.execute('pragma table_info(custom_dictionary)')]
        words = [row[0] for row in connection.execute('select word from custom_dictionary' +
                 (' where deleted_at is null' if 'deleted_at' in columns else '') + ' order by id asc')]
    local_words = json.loads(settings.get('customDictionary', '[]'))
    if not words: words = local_words  # Mirrors startup's push-local-to-empty-DB behavior.
    if not all(isinstance(word, str) for word in words): raise ValueError('Invalid dictionary')
    dictionary = ', '.join(words)
    if max(len(prompt.encode()), len(dictionary.encode())) > 16384:
        raise ValueError('Export exceeds app private-text limit')
    output.mkdir(parents=True, exist_ok=True, mode=0o700); output.chmod(0o700)
    if any((output / name).exists() for name in ['prompt.txt', 'dictionary.txt', 'cleanup-import.json']):
        raise ValueError('Export already exists; choose a new private directory')
    metadata = dict(schema=1, source_version=version, prompt_source='custom' if settings.get('customPrompt.cleanup') else 'installed-default',
                    dictionary_entries=len(words), dictionary_source='SQLite' if words else 'localStorage',
                    cleanupInputFormat='openWhispr', cleanupDictionaryPrefix=strings['dictionarySuffix'],
                    saved_cleanup_settings={key: settings[key] for key in selected if key.startswith('cleanup') and key in settings},
                    reference_temperature=0, reference_minimum_max_tokens=4096,
                    request_parity='prompt resolution and transcript framing recovered; historical tuned service absent',
                    source_sha256={name: hashlib.sha256(archive.read(name)).hexdigest() for name in
                                   ['src/config/prompts/index.ts', 'src/locales/en/prompts.json', 'src/config/languageRegistry.json']})
    for name, value in [('prompt.txt', prompt), ('dictionary.txt', dictionary),
                        ('cleanup-import.json', json.dumps(metadata, indent=2) + '\n')]:
        path = output / name
        with path.open('x') as file: file.write(value)
        path.chmod(0o600)
    print(f'Private export complete: OpenWhispr {version}, {len(words)} dictionary entries; contents not logged')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/OpenWhispr.app'))
    parser.add_argument('--source', type=Path, default=Path.home() / 'Library/Application Support/open-whispr')
    parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent.parent / 'private/openwhispr')
    args = parser.parse_args()
    try: export(args.app.resolve(), args.source.resolve(), args.output.resolve())
    except (OSError, ValueError, KeyError, sqlite3.Error) as error:
        print(f'Export failed: {error}', file=sys.stderr); sys.exit(1)
