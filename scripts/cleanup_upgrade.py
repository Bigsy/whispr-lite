"""Check for, and switch to, a newer llama.cpp build for the cleanup service.

llama.cpp changes flags, speeds and occasionally output between builds, so nothing is
assumed compatible. A candidate must verify against GitHub's published digest and start
with the service's exact flags. It is then compared with the running service on synthetic
realistic dictations, using the saved cleanup prompt and the app's request shape. The
result lists any differing outputs; switching only happens on an explicit apply, and the
replaced build is kept for rollback.

Commands are dispatched from cleanup-service.py: status, upgrade-check, upgrade-apply,
upgrade-rollback. Progress goes to stderr as "progress: ..." lines; the final result is a
single JSON object on stdout.
"""
from contextlib import contextmanager, redirect_stdout
import json
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

import cleanup_bench as bench

GITHUB_API = 'https://api.github.com/repos/ggml-org/llama.cpp'
DOWNLOAD_PREFIX = 'https://github.com/ggml-org/llama.cpp/releases/download/'
# The llama_server block accepted for this Mac, used while it is newer than the repo's pin.
LOCAL_LOCK = 'cleanup-stack.local.json'
# The block an apply or rollback replaced, so the change can be undone.
PREVIOUS_LOCK = 'cleanup-stack.previous.json'
# The last checked candidate, consumed by apply.
CANDIDATE = 'upgrade-candidate.json'
CANDIDATE_PORT = bench.ISOLATED_PORT


def progress(message):
    print(f'progress: {message}', file=sys.stderr, flush=True)


class TolerantStream:
    """stderr that ignores a closed pipe, so quitting the app never interrupts an install."""

    def __init__(self, stream):
        self.stream = stream

    def write(self, text):
        try:
            return self.stream.write(text)
        except OSError:
            return len(text)

    def flush(self):
        try:
            self.stream.flush()
        except OSError:
            pass


def build_number(tag):
    match = re.fullmatch(r'b(\d+)', tag or '')
    return int(match[1]) if match else -1


def os_version(value):
    return tuple(int(part) for part in re.findall(r'\d+', value)[:3])


def read_block(path):
    block = json.loads(path.read_text())
    if not isinstance(block.get('release'), dict) or build_number(block['release'].get('tag')) < 0:
        raise RuntimeError(f'{path.name} is not a llama-server pin')
    return block


def write_private(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.chmod(0o600)
    temporary.replace(path)


def effective_lock(base, directory):
    """The repo's pin, or the upgrade accepted on this Mac while it is the newer build."""
    local = Path(directory) / LOCAL_LOCK
    if not local.is_file():
        return base
    block = read_block(local)
    if build_number(block['release']['tag']) <= build_number(base['llama_server']['release']['tag']):
        return base
    return {**base, 'llama_server': block}


@contextmanager
def using_lock(service, lock):
    """cleanup-service.py reads its module-level LOCK; swap it for one candidate."""
    previous = service.LOCK
    service.LOCK = lock
    try:
        yield
    finally:
        service.LOCK = previous


def github(path):
    request = urllib.request.Request(GITHUB_API + path, headers={'Accept': 'application/vnd.github+json'})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def newest_release(releases):
    """Newest build with a macOS arm64 archive and a published SHA-256 digest."""
    for release in sorted(releases, key=lambda item: build_number(item.get('tag_name')), reverse=True):
        tag = release.get('tag_name')
        if build_number(tag) < 0:
            continue
        name = f'llama-{tag}-bin-macos-arm64.tar.gz'
        for asset in release.get('assets', []):
            digest = str(asset.get('digest') or '')
            url = str(asset.get('browser_download_url') or '')
            if (asset.get('name') == name and re.fullmatch(r'sha256:[0-9a-f]{64}', digest)
                    and url == f'{DOWNLOAD_PREFIX}{tag}/{name}' and isinstance(asset.get('size'), int)):
                return {'tag': tag, 'published': release.get('published_at'), 'file': name,
                        'bytes': asset['size'], 'sha256': digest.removeprefix('sha256:'), 'url': url}
    return None


def minimum_macos(binary):
    """LC_BUILD_VERSION's minimum OS from a thin arm64 Mach-O, or 'unknown'."""
    data = Path(binary).read_bytes()[:65536]
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        return 'unknown'
    offset = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        if offset + 16 > len(data):
            break
        command, size = struct.unpack_from('<II', data, offset)
        if command == 0x32:  # LC_BUILD_VERSION: cmd, cmdsize, platform, minos, ...
            minos = struct.unpack_from('<I', data, offset + 12)[0]
            major, minor, patch = minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF
            return f'{major}.{minor}' + (f'.{patch}' if patch else '')
        if size < 8:
            break
        offset += size
    return 'unknown'


def candidate_block(service, runtime, release, revision):
    """A llama_server pin built from an extracted release, in the lock's own format."""
    files = {path.relative_to(runtime).as_posix(): service.digest(path)
             for path in sorted(runtime.rglob('*')) if path.is_file()}
    if 'llama-server' not in files:
        raise RuntimeError('Release has no llama-server')
    minimum = minimum_macos(runtime / 'llama-server')
    if minimum != 'unknown' and os_version(minimum) > os_version(platform.mac_ver()[0]):
        raise RuntimeError(f"{release['tag']} needs macOS {minimum} or later")
    output = subprocess.run([str(runtime / 'llama-server'), '--version'], capture_output=True, text=True,
                            env=service.runtime_environment(), timeout=30)
    match = re.search(r'version: (\S+) \(build (\d+), commit ([0-9a-f]+)\)', output.stdout + output.stderr)
    if not match or f'b{match[2]}' != release['tag'] or not revision.startswith(match[3]):
        raise RuntimeError('Release version does not match its tag')
    return {'path': 'llama-server', 'version': match[1], 'commit': match[3], 'sha256': files['llama-server'],
            'revision': revision, 'minimum_macos': minimum,
            'release': {key: release[key] for key in ('file', 'bytes', 'sha256', 'url', 'tag')}
                       | {'directory': f"llama-{release['tag']}"},
            'files_sha256': files}


def prepare_candidate(service, directory, release):
    """Download, verify and extract a release; return its pin. Never touches the service."""
    binaries = directory / 'Binaries'
    binaries.mkdir(parents=True, exist_ok=True, mode=0o700)
    archive = binaries / release['file']
    progress(f"Downloading {release['tag']}…")
    service.fetch_verified(archive, release['url'], release, release=True)
    revision = github(f"/commits/{release['tag']}")['sha']
    runtime = binaries / f"llama-{release['tag']}"
    with tempfile.TemporaryDirectory(prefix='.release-stage-', dir=binaries) as temporary:
        stage = Path(temporary)
        service.extract_runtime(archive, stage)
        staged = stage / f"llama-{release['tag']}"
        if staged.is_symlink() or not staged.is_dir():
            raise RuntimeError('Release archive has an unexpected layout')
        block = candidate_block(service, staged, release, revision)
        if runtime.exists():
            with using_lock(service, {**service.LOCK, 'llama_server': block}):
                service.verify_runtime(runtime)
        else:
            staged.rename(runtime)
    return block


@contextmanager
def candidate_server(service, directory, block):
    """Run a candidate build on a spare port with the service's exact flags."""
    lock = {**service.LOCK, 'llama_server': block}
    with using_lock(service, lock):
        binary = service.binary(directory, CANDIDATE_PORT)  # Verifies files, version and every flag.
        command = [binary, *service.server_arguments(directory, CANDIDATE_PORT)]
        service.free_port(CANDIDATE_PORT)
    process = subprocess.Popen(command, env=service.runtime_environment(),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    endpoint = f'http://127.0.0.1:{CANDIDATE_PORT}'
    try:
        wait_ready(endpoint, process)
        yield endpoint
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


def wait_ready(endpoint, process=None, timeout=90):
    http = bench.LocalHTTP(endpoint)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError('Candidate llama-server exited during startup')
        try:
            if bench.ALIAS in [item['id'] for item in http.get('/v1/models', timeout=.5)['data']]:
                return
        except (OSError, ValueError, KeyError, urllib.error.URLError):
            pass
        time.sleep(.5)
    raise RuntimeError('llama-server did not become ready')


def compare(endpoints, settings_directory, rounds):
    """Interleave the app's cleanup request across builds; return timings and outputs."""
    saved = bench.load_saved_cleanup(settings_directory)
    vocabulary = bench.DictionaryCorrections(saved.dictionary).vocabulary
    system = saved.prompt + (saved.dictionary_prefix + vocabulary if vocabulary else '')
    fixtures = bench.load_fixtures('cleanup-fixtures-realistic.json')
    clients = {name: bench.LocalHTTP(endpoint) for name, endpoint in endpoints.items()}
    # The app skips per-request template/tokenize calls once the framing's size is known.
    fixed = {name: bench.fixed_prefix(http, system, saved.input_format)[1] for name, http in clients.items()}
    timings = {name: [] for name in clients}
    outputs = {name: {} for name in clients}
    total = (rounds + 1) * len(fixtures)
    for round_index in range(rounds + 1):  # Round 0 is warmup.
        order = list(clients) if round_index % 2 == 0 else list(reversed(clients))
        for fixture_index, fixture in enumerate(fixtures):
            chat = bench.messages(system, fixture['raw'], saved.input_format)
            for name in order:
                body, _ = bench.app_request(clients[name], bench.ALIAS, chat, fixture['raw'],
                                            fixed_tokens=fixed[name])
                start = time.monotonic()
                result = clients[name].post('/v1/chat/completions', body, timeout=30)
                elapsed = (time.monotonic() - start) * 1000
                text = result['choices'][0]['message']['content'].strip()
                previous = outputs[name].setdefault(fixture['id'], text)
                if previous != text:
                    raise RuntimeError(f'{name} output changed between repetitions')
                if round_index:
                    timings[name].append(elapsed)
            progress(f'Comparing outputs: {round_index * len(fixtures) + fixture_index + 1} of {total}')
    differences = [{'fixture': fixture['id'], 'input': fixture['raw'],
                    'current': outputs['current'][fixture['id']],
                    'candidate': outputs['candidate'][fixture['id']]}
                   for fixture in fixtures
                   if outputs['current'][fixture['id']] != outputs['candidate'][fixture['id']]]
    return timings, differences, len(fixtures), (saved.prompt, saved.dictionary)


def describe(block):
    return {'tag': block['release']['tag'], 'version': block['version']}


def prune(directory, keep):
    """Remove downloaded builds other than the given tags; a rollback needs only one."""
    binaries = Path(directory) / 'Binaries'
    for path in sorted(binaries.iterdir()) if binaries.is_dir() else ():
        match = re.fullmatch(r'llama-(b\d+)(-bin-macos-arm64\.tar\.gz(\.partial)?)?', path.name)
        if not match or match[1] in keep or path.is_symlink():
            continue
        if path.is_dir():
            shutil.rmtree(path)
        else:
            path.unlink()


def status(service, directory):
    previous = Path(directory) / PREVIOUS_LOCK
    return {'schema': 1, 'status': 'installed', 'current': describe(service.LOCK['llama_server']),
            'previous': describe(read_block(previous)) if previous.is_file() else None}


def check(service, directory, port, settings_directory, rounds):
    current = service.LOCK['llama_server']
    progress('Checking GitHub for llama.cpp builds…')
    release = newest_release(github('/releases?per_page=20'))
    if release is None:
        raise RuntimeError('No llama.cpp build with a verified macOS arm64 archive was found')
    if build_number(release['tag']) <= build_number(current['release']['tag']):
        return {'schema': 1, 'status': 'up-to-date', 'current': describe(current),
                'newest': release['tag'], 'machine': bench.machine_info()}
    endpoint = f'http://127.0.0.1:{port}'
    try:
        wait_ready(endpoint, timeout=15)
    except RuntimeError:
        raise RuntimeError('The cleanup service is not running, so there is nothing to compare with') from None
    block = prepare_candidate(service, directory, release)
    progress(f"Starting {release['tag']} beside the running service…")
    with candidate_server(service, directory, block) as candidate:
        timings, differences, fixtures, private = compare(
            {'current': endpoint, 'candidate': candidate}, settings_directory, rounds)
    write_private(Path(directory) / CANDIDATE, block)
    previous = Path(directory) / PREVIOUS_LOCK
    prune(directory, {current['release']['tag'], release['tag'],
                      *([read_block(previous)['release']['tag']] if previous.is_file() else [])})
    def figures(values):
        figure = bench.summary(values)
        return {'median_ms': round(figure['median'], 1), 'p90_ms': round(figure['p90'], 1)}
    result = {'schema': 1, 'status': 'candidate', 'machine': bench.machine_info(),
              'current': describe(current) | figures(timings['current']),
              'candidate': describe(block) | figures(timings['candidate']) | {'published': release['published']},
              'fixtures': fixtures, 'rounds': rounds, 'identical': not differences, 'differences': differences}
    encoded = json.dumps(result)
    if any(value and len(value) >= 16 and json.dumps(value)[1:-1] in encoded for value in private):
        raise RuntimeError('Comparison result contained private cleanup text')
    return result


def switch(service, directory, port, block):
    """Install with a pin, recording what it replaced; restore the files if install fails.

    The accepted pin is always recorded locally: effective_lock ignores it once the
    repository's own pin is the same build or newer."""
    directory = Path(directory)
    local, previous = directory / LOCAL_LOCK, directory / PREVIOUS_LOCK
    replaced = service.LOCK['llama_server']
    saved = {path: path.read_bytes() if path.exists() else None for path in (local, previous)}
    progress(f"Restarting cleanup with {block['release']['tag']}…")
    try:
        write_private(previous, replaced)
        write_private(local, block)
        with using_lock(service, {**service.LOCK, 'llama_server': block}):
            service.install(directory, port)
    except BaseException:
        for path, content in saved.items():
            if content is None:
                path.unlink(missing_ok=True)
            else:
                write_private(path, json.loads(content))  # Written by write_private originally.
        raise
    candidate = directory / CANDIDATE
    prune(directory, {block['release']['tag'], replaced['release']['tag'],
                      *([read_block(candidate)['release']['tag']] if candidate.is_file() else [])})
    return {'schema': 1, 'status': 'switched', 'current': describe(block), 'previous': describe(replaced)}


def apply(service, directory, port):
    candidate = Path(directory) / CANDIDATE
    if not candidate.is_file():
        raise RuntimeError('No checked candidate; run Check for update first')
    block = read_block(candidate)
    if build_number(block['release']['tag']) <= build_number(service.LOCK['llama_server']['release']['tag']):
        candidate.unlink()
        raise RuntimeError('The checked build is no newer than the one installed; check again')
    result = switch(service, directory, port, block)
    candidate.unlink(missing_ok=True)
    return result


def rollback(service, directory, port):
    previous = Path(directory) / PREVIOUS_LOCK
    if not previous.is_file():
        raise RuntimeError('No previous cleanup build to roll back to')
    return switch(service, directory, port, read_block(previous))


def dispatch(service, command, directory, port, settings_directory, rounds):
    """Run one command. Anything the service prints goes to stderr; stdout carries only
    the JSON result."""
    sys.stderr = TolerantStream(sys.stderr)
    with redirect_stdout(sys.stderr):
        if command == 'status':
            return status(service, directory)
        if command == 'upgrade-check':
            return check(service, directory, port, settings_directory, rounds)
        if command == 'upgrade-apply':
            return apply(service, directory, port)
        if command == 'upgrade-rollback':
            return rollback(service, directory, port)
    raise ValueError(f'Unknown upgrade command {command}')
