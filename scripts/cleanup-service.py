#!/usr/bin/env python3
"""Explicit, pinned local cleanup setup. Build/test never calls install or download."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'Resources/cleanup-stack.json').read_text())
LABEL = 'com.hedworth.whispr-lite.cleanup'
DEFAULT_DIRECTORY = Path.home() / 'Library/Application Support/WhisprLite/Cleanup'
METAL_RESIDENCY_SECONDS = '86400'


def release_pin():
    release = LOCK.get('llama_server', {}).get('release')
    if not isinstance(release, dict):
        raise RuntimeError('Pinned llama-server release is missing from the lock')
    return release


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda: file.read(256 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verified(path, artifact):
    return (path.is_file() and path.stat().st_size == artifact['bytes']
            and digest(path) == artifact['sha256'])


def prepare(directory):
    release_pin()  # Reject an incomplete lock before touching the owned directory.
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    for artifact in LOCK['artifacts'].values():
        path = directory / artifact['file']
        if verified(path, artifact):
            print(f"Verified {artifact['file']}", flush=True)
            continue
        if path.exists():
            raise RuntimeError(f'{path.name} failed checksum; remove or quarantine it before retrying')
        partial = path.with_suffix('.gguf.partial')
        if partial.exists() and partial.stat().st_size > artifact['bytes']:
            raise RuntimeError(f'{partial.name} exceeds the pinned size; remove it before retrying')
        url = (f"https://huggingface.co/{LOCK['repository']}/resolve/"
               f"{LOCK['revision']}/{artifact['file']}")
        print(f"Downloading {artifact['file']} ({artifact['bytes']} bytes), resumable", flush=True)
        if not verified(partial, artifact):
            subprocess.run(['curl', '--fail', '--location', '--show-error', '--silent',
                            '--retry', '3', '--connect-timeout', '20', '--speed-time', '60',
                            '--speed-limit', '1024', '--continue-at', '-', '--output', str(partial), url], check=True)
        if not verified(partial, artifact):
            raise RuntimeError(f'{partial.name} failed size/SHA-256 verification; it was not installed')
        partial.chmod(0o600)
        partial.replace(path)
        print(f"Verified {artifact['file']}", flush=True)
    prepare_runtime(directory)


def runtime_directory(directory):
    name = release_pin()['directory']
    if not re.fullmatch(r'llama-[A-Za-z0-9.-]+', name):
        raise RuntimeError('Invalid release directory')
    if (directory / 'Binaries').is_symlink(): raise RuntimeError('Runtime parent must be an owned directory')
    return directory / 'Binaries' / name


def verify_runtime(runtime):
    if runtime.is_symlink(): raise RuntimeError('Release runtime must be an owned directory')
    for filename, expected in LOCK['llama_server']['files_sha256'].items():
        path = runtime / filename
        try: path.resolve().relative_to(runtime.resolve())
        except ValueError: raise RuntimeError('Release runtime file escaped its directory')
        if not path.is_file() or digest(path) != expected:
            raise RuntimeError(f'Release runtime file missing/changed: {filename}; run cleanup-prepare')


def extract_runtime(archive, destination):
    with tarfile.open(archive, 'r:gz') as source:
        members = source.getmembers()
        if len(members) > 500 or sum(member.size for member in members) > 200 * 1024 * 1024:
            raise RuntimeError('Release archive exceeds runtime limits')
        for member in members:
            path = Path(member.name)
            if path.is_absolute() or '..' in path.parts or not (member.isdir() or member.isfile() or member.issym()):
                raise RuntimeError('Unsafe release archive entry')
            if member.issym():
                link = Path(member.linkname)
                if link.is_absolute() or '..' in link.parts:
                    raise RuntimeError('Unsafe release archive link')
        source.extractall(destination)


def prepare_runtime(directory):
    artifact = release_pin()
    runtime = runtime_directory(directory)
    if runtime.exists():
        verify_runtime(runtime)
        print('Verified standalone llama.cpp release', flush=True)
        return
    runtime.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    archive = runtime.parent / artifact['file']
    if not verified(archive, artifact):
        if archive.exists(): raise RuntimeError('Existing release archive failed checksum; it was preserved')
        partial = archive.with_suffix('.gz.partial')
        if partial.exists() and partial.stat().st_size > artifact['bytes']:
            raise RuntimeError('Partial release archive exceeds the pinned size')
        if not verified(partial, artifact):
            subprocess.run(['curl', '--fail', '--location', '--show-error', '--silent', '--retry', '3',
                            '--connect-timeout', '20', '--speed-time', '60', '--speed-limit', '1024',
                            '--continue-at', '-', '--output', str(partial), artifact['url']], check=True)
        if not verified(partial, artifact):
            raise RuntimeError('Release download failed size/SHA-256 verification; it was not installed')
        partial.chmod(0o600); partial.replace(archive)
    with tempfile.TemporaryDirectory(prefix='.release-stage-', dir=runtime.parent) as temporary:
        stage = Path(temporary)
        extract_runtime(archive, stage)
        candidate = stage / artifact['directory']
        verify_runtime(candidate)
        if runtime.exists(): raise RuntimeError('Release runtime appeared during preparation; it was preserved')
        candidate.rename(runtime)
    print('Verified and installed standalone llama.cpp release', flush=True)


def binary(directory=DEFAULT_DIRECTORY, port=None):
    pin = LOCK['llama_server']
    release_pin()
    runtime = runtime_directory(directory)
    verify_runtime(runtime)
    path = runtime / pin['path']
    if not path.is_file() or pin['files_sha256'].get(pin['path']) != pin['sha256']:
        raise RuntimeError('Pinned llama-server is missing or changed. Run cleanup-prepare for the locked release.')
    environment = runtime_environment()
    result = subprocess.run([str(path), '--version'], capture_output=True, text=True, check=True, env=environment)
    version = result.stdout + result.stderr
    if pin['version'] not in version or pin['commit'] not in version:
        raise RuntimeError('llama-server version/commit does not match the lock')
    help_text = subprocess.run([str(path), '--help'], capture_output=True, text=True, check=True, env=environment).stdout
    flags = server_arguments(directory, port if port is not None else LOCK.get('port', 11436))
    required = [value for value in flags if value.startswith('--')]
    required += [flags[flags.index(option) + 1] for option in ('--spec-type', '--load-mode')]
    for flag in required:
        if flag not in help_text:
            raise RuntimeError(f'Incompatible llama-server: missing {flag}')
    return str(path)


def runtime_environment():
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('LLAMA_ARG_', 'DYLD_'))}
    env['GGML_METAL_RESIDENCY_KEEP_ALIVE_S'] = METAL_RESIDENCY_SECONDS
    return env


def server_arguments(directory, port):
    return ['-m', str(directory / LOCK['artifacts']['model']['file']),
            '--spec-type', 'draft-mtp', '-md', str(directory / LOCK['artifacts']['drafter']['file']),
            '--spec-draft-n-max', '6', '--swa-full', '-c', '4096', '-np', '1', '-fa', 'on',
            '--load-mode', 'mmap+mlock', '--reasoning', 'off', '--temp', '0',
            '--alias', LOCK['alias'], '--host', '127.0.0.1', '--port', str(port),
            '--no-webui', '--no-slots', '--no-context-shift',
            '--cors-origins', f'http://127.0.0.1:{port}', '--log-disable']


def arguments(directory, port):
    for artifact in LOCK['artifacts'].values():
        if not verified(directory / artifact['file'], artifact):
            raise RuntimeError(f"Missing/unverified {artifact['file']}; run cleanup-prepare first")
    flags = server_arguments(directory, port)
    return [binary(directory, port), *flags]


def free_port(port):
    with socket.socket() as probe:
        # Match the server's reuse policy: completed HTTP sockets in TIME_WAIT are
        # not another listener. A live listener still prevents this bind.
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(('127.0.0.1', port))
        except OSError as error:
            raise RuntimeError(f'Port {port} is occupied; existing services were left running. '
                               'Choose another --port.') from error


def launchctl(*args):
    return subprocess.run(['/bin/launchctl', *args], capture_output=True, text=True)


def stop_owned(plist, domain):
    if not plist.exists():
        return
    data = plistlib.loads(plist.read_bytes())
    if data.get('Label') != LABEL or data.get('WhisprLiteOwner') != LABEL:
        raise RuntimeError('Refusing to replace/remove an unrecognized LaunchAgent')
    service = f'{domain}/{LABEL}'
    state = launchctl('print', service)
    if state.returncode == 0:
        match = re.search(r'^\s*pid = (\d+)\s*$', state.stdout, flags=re.MULTILINE)
        pid = int(match[1]) if match else None
        result = launchctl('bootout', service)
        if result.returncode:
            raise RuntimeError('launchctl bootout failed; the existing agent was preserved')
        until = time.monotonic() + 20
        def alive():
            if pid is None: return False
            try: os.kill(pid, 0); return True
            except ProcessLookupError: return False
        while launchctl('print', service).returncode == 0 or alive():
            if time.monotonic() >= until:
                raise RuntimeError('Timed out waiting for launchctl teardown; retry after it settles')
            time.sleep(0.1)


def install(directory, port):
    arguments(directory, port)  # Validate before touching any login item.
    # Each launch rechecks the binary/libraries/models. Updates must not silently
    # change an accepted stack. Keep immutable runners so rollback retains
    # the previous script and lock as well as the previous plist.
    source = Path(__file__).read_bytes()
    lock_data = json.dumps(LOCK, sort_keys=True).encode()
    runtime = directory / 'Runtimes' / hashlib.sha256(source + lock_data).hexdigest()[:20]
    for relative, content in [('scripts/cleanup-service.py', source), ('Resources/cleanup-stack.json', lock_data)]:
        destination = runtime / relative
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        if destination.exists():
            if destination.read_bytes() != content: raise RuntimeError('Immutable cleanup runner changed')
        else:
            with destination.open('xb') as file: file.write(content)
            destination.chmod(0o600)
    runner = [sys.executable, str(runtime / 'scripts/cleanup-service.py'), 'run',
              '--directory', str(directory), '--port', str(port)]
    plist = Path.home() / f'Library/LaunchAgents/{LABEL}.plist'
    domain = f'gui/{os.getuid()}'
    previous = plist.read_bytes() if plist.exists() else None
    stop_owned(plist, domain)
    try:
        free_port(port)
        plist.parent.mkdir(parents=True, exist_ok=True)
        data = dict(Label=LABEL, ProgramArguments=runner, RunAtLoad=True,
                    KeepAlive=dict(SuccessfulExit=False), ThrottleInterval=10,
                    EnvironmentVariables=dict(GGML_METAL_RESIDENCY_KEEP_ALIVE_S=METAL_RESIDENCY_SECONDS),
                    StandardOutPath='/dev/null', StandardErrorPath='/dev/null', WhisprLiteOwner=LABEL)
        temporary = plist.with_suffix('.plist.tmp')
        temporary.write_bytes(plistlib.dumps(data)); temporary.chmod(0o600); temporary.replace(plist)
        if launchctl('bootstrap', domain, str(plist)).returncode:
            raise RuntimeError('LaunchAgent bootstrap failed')
        until = time.monotonic() + 90
        while time.monotonic() < until:
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=2) as response:
                    if response.status == 200:
                        print(f'Cleanup ready at http://127.0.0.1:{port}; models/preferences preserved')
                        return
            except (OSError, ValueError):
                pass
            time.sleep(0.25)
        raise RuntimeError('Cleanup did not become healthy within 90 seconds')
    except Exception:
        stop_owned(plist, domain)
        if previous is not None:
            plist.write_bytes(previous); plist.chmod(0o600)
            launchctl('bootstrap', domain, str(plist))
        else:
            plist.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['prepare', 'verify', 'run', 'install', 'uninstall'])
    parser.add_argument('--directory', type=Path, default=DEFAULT_DIRECTORY)
    parser.add_argument('--port', type=int, default=LOCK['port'])
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Port must be between 1024 and 65535')
    directory = args.directory.expanduser().resolve()
    if args.command == 'prepare':
        prepare(directory)
    elif args.command == 'uninstall':
        plist = Path.home() / f'Library/LaunchAgents/{LABEL}.plist'
        stop_owned(plist, f'gui/{os.getuid()}'); plist.unlink(missing_ok=True)
        print('Cleanup login item removed; models and preferences preserved')
    elif args.command == 'install':
        install(directory, args.port)
    elif args.command == 'verify':
        arguments(directory, args.port); print('Pinned binary, flags and both model checksums verified')
    else:
        argv = arguments(directory, args.port); free_port(args.port)
        os.execve(argv[0], argv, runtime_environment())


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(f'Cleanup setup failed: {error}', file=sys.stderr)
        sys.exit(1)
