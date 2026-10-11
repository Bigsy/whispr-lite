"""Shared, read-only local cleanup benchmark configuration. Never logs private text."""

from dataclasses import dataclass
from contextlib import contextmanager
from functools import lru_cache
from importlib.util import module_from_spec, spec_from_file_location
import json
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

from local_http import LOCAL


ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'Resources/cleanup-stack.json').read_text())
DEFAULT_PROMPT = (ROOT / 'Resources/cleanup-prompt.txt').read_text().removesuffix('\n')
MAX_PRIVATE_BYTES = 16_384
SERVICE_PORT = LOCK['port']
ISOLATED_PORT = SERVICE_PORT + 1
ALIAS = LOCK['alias']
CONTEXT_TOKENS = 4096
REQUEST_BYTES = MAX_PRIVATE_BYTES
SYNTHETIC_DICTIONARY = '\nCustom dictionary:\nClojure, mapv, Parakeet, Gemma, Whispr Lite'


@lru_cache(maxsize=1)
def service():
    spec = spec_from_file_location('cleanup_service_bench', ROOT / 'scripts/cleanup-service.py')
    result = module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def loopback_url(value):
    parsed = urlparse(value)
    if (parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1')
            or parsed.username or parsed.password or parsed.path not in ('', '/')
            or parsed.query or parsed.fragment):
        raise ValueError('Loopback HTTP base URL required')
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError('Loopback HTTP base URL required') from error
    if port is None:
        raise ValueError('Loopback HTTP base URL requires a port')
    return value.rstrip('/')


class LocalHTTP:
    def __init__(self, endpoint):
        self.endpoint = loopback_url(endpoint)

    def get(self, path, timeout=2):
        with LOCAL.open(self.endpoint + path, timeout=timeout) as response:
            return json.load(response)

    def post(self, path, body, timeout=30):
        request = urllib.request.Request(self.endpoint + path, data=json.dumps(body).encode(),
                                         headers={'Content-Type': 'application/json'})
        with LOCAL.open(request, timeout=timeout) as response:
            return json.load(response)


@lru_cache(maxsize=1)
def _verified_arguments():
    pinned = service()
    return tuple(pinned.arguments(pinned.DEFAULT_DIRECTORY, ISOLATED_PORT))


@dataclass(frozen=True)
class IsolatedServer:
    endpoint: str
    process: subprocess.Popen


@contextmanager
def isolated_server(*, extra=(), spec_type=None, model=None, alias=None, drafter=None, binary=None):
    """Run one verified, proxy-free loopback server; never modify the installed service."""
    pinned = service()
    command = list(_verified_arguments())  # Includes model and runtime verification once per run.
    if binary is not None and Path(binary).resolve() != Path(command[0]).resolve():
        raise ValueError('Unverified server binary')
    if model is not None:
        if not Path(model).is_file():
            raise ValueError('Candidate model file is missing')
        command[command.index('-m') + 1] = str(model)
    if alias is not None:
        command[command.index('--alias') + 1] = alias
    if spec_type == 'none':
        for flag in ('--spec-type', '-md', '--spec-draft-n-max'):
            index = command.index(flag)
            del command[index:index + 2]
        command.remove('--swa-full')
    elif spec_type not in (None, 'draft-mtp'):
        raise ValueError('Unsupported speculation type')
    if drafter is not None:
        if spec_type == 'none' or not Path(drafter).is_file():
            raise ValueError('Candidate drafter file is missing')
        command[command.index('-md') + 1] = str(drafter)
    extra = list(extra)
    if any(flag in extra for flag in ('--host', '--port', '--alias', '-m', '-md', '--cors-origins')):
        raise ValueError('Server network and model flags must use named parameters')
    command += extra
    pinned.free_port(ISOLATED_PORT)
    process = subprocess.Popen(command, env=pinned.runtime_environment(),
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    endpoint = f'http://127.0.0.1:{ISOLATED_PORT}'
    http = LocalHTTP(endpoint)
    deadline = time.monotonic() + 90
    try:
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError('Temporary server exited')
            try:
                http.get('/health', timeout=.5)
                if (alias or ALIAS) in [item['id'] for item in http.get('/v1/models', timeout=.5)['data']]:
                    break
            except (OSError, ValueError, KeyError, urllib.error.URLError):
                pass
            time.sleep(.5)
        else:
            raise RuntimeError('Temporary server not ready')
        yield IsolatedServer(endpoint, process)
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


@dataclass(frozen=True)
class SavedCleanup:
    preferences: dict
    prompt: str
    dictionary: str

    @property
    def endpoint(self):
        return self.preferences.get('cleanupEndpoint', f"http://127.0.0.1:{LOCK['port']}")

    @property
    def input_format(self):
        return self.preferences.get('cleanupInputFormat', 'plain')

    @property
    def dictionary_prefix(self):
        return self.preferences.get('cleanupDictionaryPrefix', '\nCustom dictionary:\n')


def _private_text(directory, name, fallback):
    path = directory / name
    if path.is_symlink():
        raise ValueError('Private cleanup file is not a regular file')
    if not path.exists():
        return fallback
    if not path.is_file() or path.stat().st_size > MAX_PRIVATE_BYTES:
        raise ValueError('Private cleanup file is invalid or oversized')
    return path.read_text(encoding='utf-8')


def load_saved_cleanup(directory):
    """Mirror SettingsStore's defaults and private text handling without changing files."""
    directory = Path(directory)
    settings = directory / 'preferences.json'
    preferences = json.loads(settings.read_text()) if settings.exists() else {}
    if preferences.get('version', 1) != 1:
        raise ValueError('Unsupported cleanup settings version')
    return SavedCleanup(preferences, _private_text(directory, 'prompt.txt', DEFAULT_PROMPT),
                        _private_text(directory, 'dictionary.txt', ''))
