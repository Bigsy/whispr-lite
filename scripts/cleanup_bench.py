"""Shared, read-only local cleanup benchmark configuration. Never logs private text."""

from dataclasses import dataclass
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'Resources/cleanup-stack.json').read_text())
DEFAULT_PROMPT = (ROOT / 'Resources/cleanup-prompt.txt').read_text().removesuffix('\n')
MAX_PRIVATE_BYTES = 16_384


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
