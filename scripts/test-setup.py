#!/usr/bin/env python3
"""Synthetic setup tests: no downloads, real login-item writes or private configuration."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import socket
import struct
import tempfile
import tarfile
import types
import unittest
from unittest.mock import patch
import cleanup_bench as bench_common
from cleanup_bench import DEFAULT_PROMPT, load_saved_cleanup


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


service = module('cleanup', 'cleanup-service.py')
storage = module('storage', 'chromium-settings.py')
configuration = module('configuration', 'configure-local-stack.py')


def integer(value):
    data = bytearray()
    while value >= 128: data.append((value & 127) | 128); value >>= 7
    data.append(value); return bytes(data)


def batch(sequence, operations):
    data = struct.pack('<QI', sequence, len(operations))
    for kind, key, value in operations:
        data += bytes([kind]) + integer(len(key)) + key
        if kind == 1: data += integer(len(value)) + value
    return struct.pack('<IHB', 0, len(data), 1) + data


class SetupTests(unittest.TestCase):
    def test_shared_dictionary_cases(self):
        cases = json.loads((Path(__file__).resolve().parent.parent / 'bench/dictionary-cases.json').read_text())
        for item in cases:
            with self.subTest(item['id']):
                corrections = bench_common.DictionaryCorrections(item['dictionary'])
                self.assertEqual(corrections.vocabulary, item['vocabulary'])
                self.assertEqual(corrections.apply(item['input']), item['output'])

    def test_benchmark_url_accepts_only_loopback_with_port(self):
        self.assertEqual(bench_common.loopback_url('http://localhost:11436/'),
                         'http://localhost:11436')
        for value in ('http://example.com:11436', 'http://localhost',
                      'http://localhost:99999', 'http://localhost:11436/path'):
            with self.assertRaises(ValueError):
                bench_common.loopback_url(value)

    def test_isolated_bench_server_uses_verified_binary_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            candidate = Path(temporary) / 'candidate.gguf'
            candidate.write_bytes(b'synthetic model')
            calls = []
            flags = ['/verified/llama-server', '-m', '/baseline/model.gguf', '--spec-type', 'draft-mtp',
                     '-md', '/baseline/drafter.gguf', '--spec-draft-n-max', '6', '--swa-full',
                     '--alias', bench_common.ALIAS, '--host', '127.0.0.1', '--port', str(bench_common.ISOLATED_PORT)]
            fake_service = types.SimpleNamespace(DEFAULT_DIRECTORY=Path('/synthetic'),
                arguments=lambda directory, port: calls.append(('verify', port)) or flags,
                free_port=lambda port: calls.append(('free_port', port)),
                runtime_environment=lambda: {'SAFE': '1'})
            class FakeProcess:
                pid = 123
                terminated = False
                def poll(self): return None
                def terminate(self): self.terminated = True
                def wait(self, timeout=None): return 0
            process = FakeProcess()
            def response(_, path, timeout=2):
                return {'data': [{'id': 'synthetic-candidate'}]} if path == '/v1/models' else {'status': 'ok'}
            bench_common._verified_arguments.cache_clear()
            try:
                with patch.object(bench_common, 'service', return_value=fake_service), \
                     patch.object(bench_common.subprocess, 'Popen', return_value=process) as launch, \
                     patch.object(bench_common.LocalHTTP, 'get', response):
                    with bench_common.isolated_server(spec_type='none', model=candidate,
                            alias='synthetic-candidate', binary='/verified/llama-server', extra=('--cache-ram', '0')) as server:
                        self.assertEqual(server.endpoint, f'http://127.0.0.1:{bench_common.ISOLATED_PORT}')
                        command = launch.call_args.args[0]
                        self.assertEqual(command[command.index('-m') + 1], str(candidate))
                        self.assertNotIn('--spec-type', command)
                        self.assertEqual(launch.call_args.kwargs['env'], {'SAFE': '1'})
                    self.assertTrue(process.terminated)
                    self.assertEqual(calls, [('verify', bench_common.ISOLATED_PORT),
                                             ('free_port', bench_common.ISOLATED_PORT)])
                    with self.assertRaisesRegex(ValueError, 'Unverified server binary'):
                        with bench_common.isolated_server(binary='/unverified/server'):
                            pass
                    self.assertEqual(launch.call_count, 1)
            finally:
                bench_common._verified_arguments.cache_clear()

    def test_saved_cleanup_uses_app_defaults_and_preserves_private_whitespace(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            saved = load_saved_cleanup(directory)
            self.assertEqual(saved.prompt, DEFAULT_PROMPT)
            self.assertEqual(saved.dictionary, '')
            self.assertEqual(saved.endpoint, 'http://127.0.0.1:11436')
            (directory / 'preferences.json').write_text(json.dumps({
                'version': 1, 'cleanupInputFormat': 'openWhispr',
                'cleanupDictionaryPrefix': '\nSynthetic terms:\n'}))
            (directory / 'prompt.txt').write_text('  synthetic prompt\n')
            saved = load_saved_cleanup(directory)
            self.assertEqual(saved.prompt, '  synthetic prompt\n')
            self.assertEqual(saved.input_format, 'openWhispr')
            self.assertEqual(saved.dictionary_prefix, '\nSynthetic terms:\n')
            (directory / 'dictionary.txt').symlink_to(directory / 'prompt.txt')
            with self.assertRaisesRegex(ValueError, 'not a regular file'):
                load_saved_cleanup(directory)
            (directory / 'dictionary.txt').unlink()
            (directory / 'dictionary.txt').write_bytes(b'x' * 16_385)
            with self.assertRaisesRegex(ValueError, 'oversized'):
                load_saved_cleanup(directory)

    def test_report_lock_matches_pinned_cleanup_and_server_tuning(self):
        report = json.loads((Path(__file__).resolve().parent.parent / 'stack.lock.json').read_text())
        pin = service.LOCK
        runtime = report['cleanup_runtime']
        for key in ('path', 'version', 'commit', 'sha256', 'revision', 'minimum_macos'):
            self.assertEqual(runtime[key], pin['llama_server'][key], key)
        for key in ('release', 'files_sha256'):
            self.assertEqual(runtime[key], pin['llama_server'][key], key)
        for key in ('alias', 'port'):
            self.assertEqual(runtime[key], pin[key], key)
        for report_name, pin_name in (('cleanup', 'model'), ('drafter', 'drafter')):
            installed = report['installed_models'][report_name]
            for key in ('file', 'bytes', 'sha256'):
                self.assertEqual(installed[key], pin['artifacts'][pin_name][key], (report_name, key))
            self.assertEqual(installed['repository'], pin['repository'])
            self.assertEqual(installed['repository_revision'], pin['revision'])
        flags = service.server_arguments(Path('/synthetic'), pin['port'])
        tuning = runtime['tuning']
        for key, option in (('draft_type', '--spec-type'), ('draft_length', '--spec-draft-n-max'),
                            ('context', '-c'), ('parallel_slots', '-np'), ('flash_attention', '-fa'),
                            ('load_mode', '--load-mode'), ('reasoning', '--reasoning'), ('temperature', '--temp')):
            self.assertEqual(flags[flags.index(option) + 1], str(tuning[key]), key)
        self.assertEqual('--swa-full' in flags, tuning['swa_full'])
        self.assertEqual(flags[flags.index('--alias') + 1], pin['alias'])
        self.assertEqual(flags[flags.index('--port') + 1], str(pin['port']))
        self.assertEqual(int(service.METAL_RESIDENCY_SECONDS), tuning['metal_residency_seconds'])

    def test_missing_runtime_release_is_rejected_before_creating_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'owned'
            with patch.object(service, 'LOCK', dict(artifacts={}, llama_server={})):
                with self.assertRaisesRegex(RuntimeError, 'release is missing'):
                    service.prepare(directory)
            self.assertFalse(directory.exists())

    def test_pinned_dependency_used_for_verification_and_server_launch(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            runtime = directory / 'Binaries/llama-synthetic'; runtime.mkdir(parents=True)
            binary = runtime / 'server'; binary.write_bytes(b'synthetic server')
            library = runtime / 'dependency.dylib'; library.write_bytes(b'synthetic dependency')
            pin = dict(path='server', version='1.2', commit='synthetic', release=dict(directory='llama-synthetic'),
                       sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                       files_sha256={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [binary, library]})
            lock = dict(llama_server=pin, port=11436, alias='synthetic-cleanup',
                        artifacts=dict(model=dict(file='model.gguf'), drafter=dict(file='draft.gguf')))
            help_text = ' '.join(['--spec-type', 'draft-mtp', '--spec-draft-n-max', '--swa-full',
                '--load-mode', 'mmap+mlock', '--reasoning', '--temp', '--alias', '--host',
                '--port', '--no-webui', '--no-slots', '--no-context-shift', '--cors-origins', '--log-disable'])
            def command(argv, **kwargs):
                self.assertNotIn('DYLD_LIBRARY_PATH', kwargs['env'])
                self.assertNotIn('LLAMA_ARG_MODEL', kwargs['env'])
                return types.SimpleNamespace(stdout='1.2 synthetic' if '--version' in argv else help_text, stderr='')
            with patch.object(service, 'LOCK', lock), patch.dict(service.os.environ, {'DYLD_LIBRARY_PATH': '/unverified', 'LLAMA_ARG_MODEL': 'unverified'}), \
                 patch.object(service.subprocess, 'run', side_effect=command), \
                 patch.object(service, 'arguments', side_effect=lambda *args: [service.binary(directory)]), \
                 patch.object(service, 'free_port'), patch.object(service.os, 'execve') as launch, \
                 patch.object(service.sys, 'argv', ['cleanup-service.py', 'run', '--directory', str(directory)]):
                service.main()
                self.assertNotIn('DYLD_LIBRARY_PATH', launch.call_args.args[2])
                self.assertNotIn('LLAMA_ARG_MODEL', launch.call_args.args[2])
                with patch.object(service, 'digest', wraps=service.digest) as digest:
                    service.binary(directory)
                    self.assertEqual(digest.call_count, 2)
                library.write_bytes(b'changed dependency')
                with self.assertRaisesRegex(RuntimeError, 'runtime file missing/changed'):
                    service.binary(directory)

    def test_release_preparation_is_verified_reusable_and_preserves_settings_models(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            payload = b'synthetic runtime'
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
                entry = tarfile.TarInfo('llama-synthetic/server'); entry.size=len(payload); entry.mode=0o700
                archive.addfile(entry, io.BytesIO(payload))
            compressed = buffer.getvalue()
            artifact = dict(file='runtime.tar.gz',bytes=len(compressed),sha256=hashlib.sha256(compressed).hexdigest(),
                            directory='llama-synthetic',url='https://synthetic.invalid/runtime')
            lock = dict(llama_server=dict(release=artifact,files_sha256={'server':hashlib.sha256(payload).hexdigest()}))
            (directory/'model.gguf').write_bytes(b'keep model');(directory/'preferences.json').write_bytes(b'keep preferences')
            def download(argv, **kwargs):Path(argv[argv.index('--output')+1]).write_bytes(compressed)
            with patch.object(service,'LOCK',lock),patch.object(service.subprocess,'run',side_effect=download) as curl:
                service.prepare_runtime(directory);service.prepare_runtime(directory)
                self.assertEqual(curl.call_count,1)
                runtime=directory/'Binaries/llama-synthetic/server'
                self.assertEqual(runtime.read_bytes(),payload)
                runtime.write_bytes(b'changed')
                with self.assertRaisesRegex(RuntimeError,'runtime file missing/changed'):service.prepare_runtime(directory)
                self.assertEqual(curl.call_count,1)
            self.assertEqual((directory/'model.gguf').read_bytes(),b'keep model')
            self.assertEqual((directory/'preferences.json').read_bytes(),b'keep preferences')

    def test_unsafe_runtime_archive_never_extracts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);destination=root/'stage';destination.mkdir()
            for unsafe_name, link in [('../outside',None),('llama-synthetic/link','../../outside')]:
                archive_path=root/'runtime.tar.gz'
                with tarfile.open(archive_path,'w:gz') as archive:
                    safe=tarfile.TarInfo('llama-synthetic/safe');safe.size=4
                    archive.addfile(safe,io.BytesIO(b'safe'))
                    entry=tarfile.TarInfo(unsafe_name)
                    if link:entry.type=tarfile.SYMTYPE;entry.linkname=link
                    archive.addfile(entry)
                with self.assertRaisesRegex(RuntimeError,'Unsafe release archive'):service.extract_runtime(archive_path,destination)
                self.assertEqual(list(destination.iterdir()),[])
                self.assertFalse((root/'outside').exists())

    def test_bad_release_archive_never_publishes_runtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            artifact=dict(file='runtime.tar.gz',bytes=3,sha256=hashlib.sha256(b'yes').hexdigest(),
                          directory='llama-synthetic',url='https://synthetic.invalid/runtime')
            def download(argv,**kwargs):Path(argv[argv.index('--output')+1]).write_bytes(b'bad')
            with patch.object(service,'LOCK',dict(llama_server=dict(release=artifact))),patch.object(service.subprocess,'run',side_effect=download):
                with self.assertRaisesRegex(RuntimeError,'SHA-256'):service.prepare_runtime(directory)
            self.assertFalse((directory/'Binaries/llama-synthetic').exists())

    def test_teardown_waits_for_process_after_job_disappears(self):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / 'owned.plist'
            file.write_bytes(plistlib.dumps(dict(Label=service.LABEL, WhisprLiteOwner=service.LABEL)))
            replies = iter([types.SimpleNamespace(returncode=0, stdout='pid = 123\n'),
                            types.SimpleNamespace(returncode=0, stdout=''),
                            types.SimpleNamespace(returncode=1, stdout=''), types.SimpleNamespace(returncode=1, stdout='')])
            with patch.object(service, 'launchctl', side_effect=lambda *args: next(replies)), \
                 patch.object(service.os, 'kill', side_effect=[None, ProcessLookupError()]) as probe, patch.object(service.time, 'sleep') as pause:
                service.stop_owned(file, 'gui/1')
                self.assertEqual(probe.call_count, 2); pause.assert_called_once()
    def test_configure_keeps_saved_backend_hotkey_and_private_text(self):
        import json
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; source.mkdir()
            cache = root / 'cache'; cache.mkdir(); destination = root / 'settings'; destination.mkdir()
            (source / 'prompt.txt').write_text('synthetic prompt'); (source / 'dictionary.txt').write_text('synthetic dictionary')
            (source / 'cleanup-import.json').write_text(json.dumps(dict(cleanupInputFormat='openWhispr', cleanupDictionaryPrefix='\nWords: ')))
            original = dict(version=1, backend='http', hotkey=dict(keyCode=12, modifiers=99))
            (destination / 'preferences.json').write_text(json.dumps(original))
            configuration.configure(destination, source, cache, 'http://127.0.0.1:11436')
            result = json.loads((destination / 'preferences.json').read_text())
            self.assertEqual(result['backend'], 'http'); self.assertEqual(result['hotkey'], original['hotkey'])
            (destination / 'prompt.txt').write_text('keep my changed prompt')
            with self.assertRaisesRegex(ValueError, 'review migration'): configuration.configure(destination, source, cache, 'http://127.0.0.1:11436')
            self.assertEqual((destination / 'prompt.txt').read_text(), 'keep my changed prompt')

    def test_verified_download_is_atomic_and_reusable(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            payload = b'synthetic model'
            artifact = dict(file='model.gguf', bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            lock = dict(repository='synthetic', revision='pinned', artifacts=dict(model=artifact),
                        llama_server=dict(release=dict(directory='llama-synthetic')))
            def download(argv, **kwargs):
                self.assertIn('--continue-at', argv)
                Path(argv[argv.index('--output') + 1]).write_bytes(payload)
            with patch.object(service, 'LOCK', lock), patch.object(service.subprocess, 'run', side_effect=download) as curl, \
                 patch.object(service, 'prepare_runtime'):
                service.prepare(directory); service.prepare(directory)
                self.assertEqual(curl.call_count, 1)
                self.assertFalse((directory / 'model.gguf.partial').exists())
                self.assertEqual((directory / 'model.gguf').stat().st_mode & 0o777, 0o600)

    def test_complete_partial_is_hashed_once_without_redownloading(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            payload = b'synthetic completed partial'
            artifact = dict(file='model.gguf', bytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())
            path = directory / artifact['file']
            (directory / 'model.gguf.partial').write_bytes(payload)
            with patch.object(service, 'digest', wraps=service.digest) as digest, \
                 patch.object(service.subprocess, 'run') as curl:
                service.fetch_verified(path, 'https://synthetic.invalid/model', artifact)
                self.assertEqual(digest.call_count, 1)
                curl.assert_not_called()
            self.assertEqual(path.read_bytes(), payload)
            self.assertFalse((directory / 'model.gguf.partial').exists())

    def test_bad_checksum_never_becomes_an_installed_model(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            artifact = dict(file='model.gguf', bytes=3, sha256=hashlib.sha256(b'yes').hexdigest())
            lock = dict(repository='synthetic', revision='pinned', artifacts=dict(model=artifact),
                        llama_server=dict(release=dict(directory='llama-synthetic')))
            def download(argv, **kwargs): Path(argv[argv.index('--output') + 1]).write_bytes(b'bad')
            with patch.object(service, 'LOCK', lock), patch.object(service.subprocess, 'run', side_effect=download), \
                 patch.object(service, 'prepare_runtime'):
                with self.assertRaisesRegex(RuntimeError, 'SHA-256'): service.prepare(directory)
            self.assertFalse((directory / 'model.gguf').exists())

    def test_foreign_agent_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / 'foreign.plist'
            original = plistlib.dumps(dict(Label='another.service')); file.write_bytes(original)
            with patch.object(service, 'launchctl') as command:
                with self.assertRaisesRegex(RuntimeError, 'unrecognized'): service.stop_owned(file, 'gui/1')
                command.assert_not_called()
            self.assertEqual(file.read_bytes(), original)

    def test_occupied_port_preserves_existing_listener(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0)); listener.listen()
            with self.assertRaisesRegex(RuntimeError, 'occupied'): service.free_port(listener.getsockname()[1])
            self.assertNotEqual(listener.fileno(), -1)

    def test_completed_http_socket_does_not_look_like_port_conflict(self):
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(('127.0.0.1', 0)); listener.listen()
            port = listener.getsockname()[1]
            with socket.create_connection(('127.0.0.1', port)) as client:
                connection, _ = listener.accept(); connection.close(); client.recv(1)
        service.free_port(port)

    def test_failed_bootstrap_removes_only_new_owned_agent(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            models = home / 'models'; models.mkdir(); (models / 'model.gguf').write_text('keep')
            def command(*argv): return types.SimpleNamespace(returncode=1, stdout='', stderr='')
            with patch.object(Path, 'home', return_value=home), patch.object(service, 'arguments', return_value=['synthetic']), \
                    patch.object(service, 'free_port'), patch.object(service, 'launchctl', side_effect=command):
                with self.assertRaisesRegex(RuntimeError, 'bootstrap'): service.install(models, 11436)
            self.assertFalse((home / f'Library/LaunchAgents/{service.LABEL}.plist').exists())
            self.assertEqual((models / 'model.gguf').read_text(), 'keep')

    def test_log_latest_sequence_tombstones_unicode_and_whitelist(self):
        key = lambda name: b'_file://\x00\x01' + name.encode()
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / '000001.log').write_bytes(batch(10, [(1, key('prompt'), b'\x01old'),
                (1, key('credential'), b'\x01never exported'), (1, key('removed'), b'\x01old')]))
            (directory / '000002.log').write_bytes(batch(20, [(1, key('prompt'), b'\x00' + 'hello \u2603'.encode('utf-16-le')),
                (0, key('removed'), b'')]))
            self.assertEqual(storage.read_settings(directory, ['prompt', 'removed']), {'prompt': 'hello \u2603'})

    def test_snappy_overlap_and_invalid_backreference(self):
        # Six bytes: literal "ab", then overlapping copy of four bytes, distance two.
        self.assertEqual(storage.snappy(b'\x06\x04ab\x01\x02'), b'ababab')
        with self.assertRaises(ValueError): storage.snappy(b'\x04\x01\x01')
        with self.assertRaises(ValueError): list(storage.records(b'\x00\x00\x00\x00\x09\x00\x01short'))


if __name__ == '__main__': unittest.main()
