#!/usr/bin/env python3
"""Synthetic setup tests: no downloads, real login-item writes or private configuration."""
import hashlib
from contextlib import redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import queue
import socket
import struct
import subprocess
import sys
import tempfile
import tarfile
import types
import unittest
from unittest.mock import patch
import cleanup_bench as bench_common
import cleanup_upgrade as upgrade
from broker_client import BrokerClient
from cleanup_bench import DEFAULT_PROMPT, load_saved_cleanup


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


service = module('cleanup', 'cleanup-service.py')
storage = module('storage', 'chromium-settings.py')
configuration = module('configuration', 'configure-local-stack.py')
exporter = module('exporter', 'export-openwhispr.py')


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
    def test_archive_reads_entries_without_retaining_an_open_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'synthetic.asar'
            header = json.dumps({'files': {'entry.txt': {'size': 3, 'offset': '0'}}}).encode()
            path.write_bytes(struct.pack('<IIII', 0, 8 + len(header), 0, len(header)) + header + b'abc')
            archive = exporter.Archive(path)
            self.assertEqual(archive.read('entry.txt'), b'abc')
            self.assertFalse(hasattr(archive, 'file'))

    def test_broker_client_timeout_and_request_correlation(self):
        client = BrokerClient.__new__(BrokerClient)
        client.events = queue.Queue()
        client.events.put({'type': 'paused', 'request': 'old'})
        client.events.put({'type': 'paused', 'request': 'current'})
        self.assertEqual(client.wait('paused', 'current', timeout=.01)['request'], 'current')
        with self.assertRaisesRegex(RuntimeError, 'Media response deadline'):
            client.wait('resumed', timeout=.01)

    def test_benchmark_guard_redacts_exception_text(self):
        stderr = io.StringIO()
        def private_error():
            raise ValueError('synthetic private transcript')
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as exit_error:
            bench_common.run_guarded(private_error, 'Synthetic check')
        self.assertEqual(exit_error.exception.code, 1)
        self.assertIn('ValueError', stderr.getvalue())
        self.assertNotIn('synthetic private transcript', stderr.getvalue())
        stderr = io.StringIO()
        def safe_error():
            raise ValueError('Output parity failed')
        with redirect_stderr(stderr), self.assertRaises(SystemExit):
            bench_common.run_guarded(safe_error, 'Synthetic check', {'Output parity failed'})
        self.assertIn('Output parity failed', stderr.getvalue())

    def test_benchmark_report_header_and_private_content_guard(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'report.json'
            report = bench_common.write_report(destination,
                {'private_contents_recorded': False, 'observations': [1, 2]},
                'synthetic-test', forbidden=('synthetic private phrase',))
            self.assertEqual(report['experiment'], 'synthetic-test')
            self.assertEqual(report['percentile_method'], 'nearest-rank')
            self.assertFalse(report['private_content_recorded'])
            self.assertTrue(report['git_commit'])
            self.assertIn('created_utc', report)
            self.assertNotIn('private_contents_recorded', report)
            machine = json.loads(destination.read_text())['machine']
            self.assertTrue(machine['chip'].startswith('Apple M'))
            self.assertGreater(machine['memory_gb'], 0)
            self.assertGreater(machine['performance_cores'], 0)
            self.assertTrue(machine['macos'] and machine['macos_build'])
            self.assertIn(machine['chip'], bench_common.machine_label(machine))
            with self.assertRaisesRegex(ValueError, 'private content'):
                bench_common.write_report(destination, {'note': 'synthetic private phrase'},
                                          'synthetic-test', forbidden=('synthetic private phrase',))
            self.assertNotIn('synthetic private phrase', destination.read_text())
            self.assertEqual(bench_common.nearest_rank(list(range(1, 11)), .9), 9)
            self.assertEqual(bench_common.nearest_rank(list(range(1, 11)), .95), 10)

    def test_shared_word_scoring_cases(self):
        cases = json.loads((Path(__file__).resolve().parent.parent / 'bench/word-cases.json').read_text())
        for item in cases:
            self.assertEqual(bench_common.words(item['input']), item['words'])

    def test_app_request_framing_and_budget(self):
        class SyntheticHTTP:
            def __init__(self): self.calls = []
            def post(self, path, body):
                self.calls.append((path, body))
                return {'prompt': 'synthetic template'} if path == '/apply-template' else {'tokens': [1, 2, 3]}
        http = SyntheticHTTP()
        chat_messages = bench_common.messages('Synthetic system', 'hello', 'openWhispr')
        self.assertIn('<transcript>\nhello\n</transcript>', chat_messages[1]['content'])
        body, count = bench_common.app_request(http, bench_common.ALIAS, chat_messages, 'hello')
        self.assertEqual(count, 3)
        self.assertEqual(body['max_tokens'], 128)
        self.assertEqual(http.calls[1][1]['add_special'], True)
        http.calls.clear()
        body, count = bench_common.app_request(http, bench_common.ALIAS, chat_messages,
                                               'hello', fixed_tokens=100)
        self.assertIsNone(count)
        self.assertEqual(http.calls, [])
        self.assertEqual(body['max_tokens'], 128)
        self.assertEqual(bench_common.output_limit('x' * 2000), 1024)
        with self.assertRaisesRegex(ValueError, 'byte budget'):
            bench_common.messages('x' * 16_384, 'more')

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

    def test_login_item_is_named_after_a_working_launcher(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            models = home / 'Application Support' / 'Cleanup'; models.mkdir(parents=True)
            loaded = {}
            def command(*argv):
                if argv[0] == 'bootstrap': loaded.update(plistlib.loads(Path(argv[2]).read_bytes()))
                return types.SimpleNamespace(returncode=1, stdout='', stderr='')
            with patch.object(Path, 'home', return_value=home), patch.object(service, 'arguments', return_value=['synthetic']), \
                    patch.object(service, 'free_port'), patch.object(service, 'launchctl', side_effect=command):
                with self.assertRaisesRegex(RuntimeError, 'bootstrap'): service.install(models, 11436)
            launcher, *rest = loaded['ProgramArguments']
            self.assertEqual(Path(launcher).name, service.LAUNCHER)
            self.assertEqual(rest, ['run', '--directory', str(models), '--port', '11436'])
            # The path contains a space, as Application Support does.
            result = subprocess.run([launcher, '--help'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('install', result.stdout)
            # The runner carries what Settings needs to check and switch builds.
            result = subprocess.run([launcher, 'status', '--directory', str(models)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['current']['tag'], service.LOCK['llama_server']['release']['tag'])

    @staticmethod
    def pin(tag):
        return {'path': 'llama-server', 'version': f'synthetic-{tag}', 'commit': 'abc1234', 'sha256': '0' * 64,
                'release': {'tag': tag, 'file': f'llama-{tag}-bin-macos-arm64.tar.gz', 'directory': f'llama-{tag}'},
                'files_sha256': {}}

    def test_a_local_build_is_used_only_while_newer_than_the_repository_pin(self):
        base = service.LOCK
        build = upgrade.build_number(base['llama_server']['release']['tag'])
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.assertIs(upgrade.effective_lock(base, directory), base)
            upgrade.write_private(directory / upgrade.LOCAL_LOCK, self.pin(f'b{build}'))
            self.assertIs(upgrade.effective_lock(base, directory), base)
            upgrade.write_private(directory / upgrade.LOCAL_LOCK, self.pin(f'b{build + 1}'))
            effective = upgrade.effective_lock(base, directory)
            self.assertEqual(effective['llama_server']['release']['tag'], f'b{build + 1}')
            self.assertEqual(effective['artifacts'], base['artifacts'])
            self.assertEqual((directory / upgrade.LOCAL_LOCK).stat().st_mode & 0o777, 0o600)
            (directory / upgrade.LOCAL_LOCK).write_text('{"release": {"tag": "latest"}}')
            with self.assertRaisesRegex(RuntimeError, 'not a llama-server pin'): upgrade.effective_lock(base, directory)

    def test_newest_release_needs_the_exact_archive_and_a_published_digest(self):
        def release(tag, **asset):
            name = f'llama-{tag}-bin-macos-arm64.tar.gz'
            return {'tag_name': tag, 'published_at': 'synthetic', 'assets': [{'name': name, 'size': 10,
                    'digest': 'sha256:' + 'a' * 64, 'browser_download_url': upgrade.DOWNLOAD_PREFIX + f'{tag}/{name}'} | asset]}
        releases = [release('b12'), release('b15', digest=None), release('b14', browser_download_url='https://example.invalid/x'),
                    release('b13', size='10'), release('latest'), release('b11')]
        found = upgrade.newest_release(releases)
        self.assertEqual((found['tag'], found['sha256'], found['bytes']), ('b12', 'a' * 64, 10))
        self.assertIsNone(upgrade.newest_release([release('b9', digest='md5:abc')]))

    def test_minimum_macos_reads_the_mach_o_build_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'llama-server'
            command = struct.pack('<IIIIII', 0x32, 24, 1, (13 << 16) | (3 << 8), 0, 0)
            binary.write_bytes(struct.pack('<IiiIIIII', 0xFEEDFACF, 0, 0, 2, 1, len(command), 0, 0) + command)
            self.assertEqual(upgrade.minimum_macos(binary), '13.3')
            binary.write_bytes(b'#!/bin/sh\n')
            self.assertEqual(upgrade.minimum_macos(binary), 'unknown')
        self.assertGreater(upgrade.os_version('26.7.1'), upgrade.os_version('26.7'))

    def test_switch_keeps_one_build_to_return_to_and_restores_files_on_failure(self):
        current, newer, older = self.pin('b100'), self.pin('b200'), self.pin('b50')
        lock = {**service.LOCK, 'llama_server': current}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            binaries = directory / 'Binaries'
            for tag in ('b50', 'b100', 'b200'):
                (binaries / f'llama-{tag}').mkdir(parents=True)
                (binaries / f'llama-{tag}-bin-macos-arm64.tar.gz').write_bytes(b'x')
            (binaries / '.release-stage-keep').mkdir()
            upgrade.write_private(directory / upgrade.PREVIOUS_LOCK, older)
            installed = []
            def install(path, port):
                installed.append((service.LOCK['llama_server']['release']['tag'], path, port))
                raise RuntimeError('LaunchAgent bootstrap failed')
            with upgrade.using_lock(service, lock), patch.object(service, 'install', side_effect=install):
                with self.assertRaisesRegex(RuntimeError, 'bootstrap'), redirect_stderr(io.StringIO()):
                    upgrade.switch(service, directory, 11436, newer)
                self.assertEqual(service.LOCK, lock)
            self.assertEqual(installed, [('b200', directory, 11436)])
            self.assertFalse((directory / upgrade.LOCAL_LOCK).exists())
            self.assertEqual(upgrade.read_block(directory / upgrade.PREVIOUS_LOCK), older)
            self.assertTrue((binaries / 'llama-b50').is_dir())
            with upgrade.using_lock(service, lock), patch.object(service, 'install'), redirect_stderr(io.StringIO()):
                result = upgrade.switch(service, directory, 11436, newer)
            self.assertEqual(result['current']['tag'], 'b200')
            self.assertEqual(result['previous']['tag'], 'b100')
            self.assertEqual(upgrade.read_block(directory / upgrade.LOCAL_LOCK), newer)
            self.assertEqual(upgrade.read_block(directory / upgrade.PREVIOUS_LOCK), current)
            self.assertEqual(sorted(path.name for path in binaries.iterdir()),
                             ['.release-stage-keep', 'llama-b100', 'llama-b100-bin-macos-arm64.tar.gz',
                              'llama-b200', 'llama-b200-bin-macos-arm64.tar.gz'])

    def test_apply_needs_a_newer_checked_build_and_rollback_needs_a_previous_one(self):
        lock = {**service.LOCK, 'llama_server': self.pin('b100')}
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with upgrade.using_lock(service, lock), patch.object(service, 'install') as install:
                with self.assertRaisesRegex(RuntimeError, 'No checked candidate'):
                    upgrade.apply(service, directory, 11436)
                with self.assertRaisesRegex(RuntimeError, 'No previous'):
                    upgrade.rollback(service, directory, 11436)
                upgrade.write_private(directory / upgrade.CANDIDATE, self.pin('b100'))
                with self.assertRaisesRegex(RuntimeError, 'no newer'):
                    upgrade.apply(service, directory, 11436)
                self.assertFalse((directory / upgrade.CANDIDATE).exists())
                install.assert_not_called()

    def test_upgrade_commands_print_only_json_on_stdout(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            upgrade.write_private(directory / upgrade.PREVIOUS_LOCK, self.pin('b50'))
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('cleanup-service.py')), 'status',
                                     '--directory', str(directory)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)['previous'], {'tag': 'b50', 'version': 'synthetic-b50'})
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('cleanup-service.py')), 'upgrade-apply',
                                     '--directory', str(directory)], capture_output=True, text=True)
            self.assertEqual((result.returncode, result.stdout), (1, ''))
            self.assertIn('No checked candidate', result.stderr)

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
