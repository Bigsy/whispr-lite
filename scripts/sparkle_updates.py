"""Configure opt-in Sparkle builds and generate signed GitHub release appcasts."""
import base64
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
DEFAULT_ACCOUNT = 'com.hedworth.whispr-lite'
SPARKLE_NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def validate_configuration(info):
    key, feed = info.get('SUPublicEDKey'), info.get('SUFeedURL')
    if not key and not feed:
        return False
    if not key or not feed:
        raise ValueError('App updates require both SPARKLE_PUBLIC_ED_KEY and SPARKLE_FEED_URL')
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise ValueError('SPARKLE_PUBLIC_ED_KEY must be a base64-encoded 32-byte public key')
    url = urlsplit(feed)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password
            or url.query or url.fragment or not url.path.endswith('.xml')):
        raise ValueError('SPARKLE_FEED_URL must be an HTTPS XML feed URL without credentials, query or fragment')
    if not re.fullmatch(r'[1-9][0-9]*', str(info.get('CFBundleVersion', ''))):
        raise ValueError('App updates require a positive, increasing APP_BUILD_NUMBER')
    return True


def configure(plist, environment):
    info = plistlib.loads(plist.read_bytes())
    for setting, variable in [('SUPublicEDKey', 'SPARKLE_PUBLIC_ED_KEY'), ('SUFeedURL', 'SPARKLE_FEED_URL')]:
        if environment.get(variable):
            info[setting] = environment[variable]
    validate_configuration(info)
    plist.write_bytes(plistlib.dumps(info))


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True, text=True).stdout.strip()


def verify_signing_key(info, account):
    # Read only the public key. Never export the private key or put it on a command line.
    public_key = run(TOOLS / 'generate_keys', '--account', account, '-p')
    if public_key != info['SUPublicEDKey']:
        raise ValueError('Sparkle signing key does not match the public key embedded in the app')


def generate_appcast(dmg, destination, info, release_version, account):
    """Only the app DMG is an update: never scan the separate cleanup setup ZIP."""
    with tempfile.TemporaryDirectory(prefix='whispr-appcast-') as temporary:
        archives = Path(temporary)
        shutil.copy2(dmg, archives / dmg.name)
        prefix = f'https://github.com/Bigsy/whispr-lite/releases/download/v{release_version}/'
        run(TOOLS / 'generate_appcast', '--account', account,
            '--download-url-prefix', prefix, '--maximum-deltas', '0',
            '--link', f'https://github.com/Bigsy/whispr-lite/releases/tag/v{release_version}',
            '-o', destination, archives)
    # Fail packaging if the native tool skipped the archive, or produced an unsigned/wrong item.
    items = ET.parse(destination).getroot().findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one app update in the generated appcast')
    item = items[0]
    enclosure = item.find('enclosure')
    if (enclosure is None or not enclosure.get(SPARKLE_NS + 'edSignature')
            or enclosure.get('url') != prefix + dmg.name
            or enclosure.get('length') != str(dmg.stat().st_size)
            or item.findtext(SPARKLE_NS + 'version') != str(info['CFBundleVersion'])):
        raise ValueError('Generated appcast does not match the signed release DMG and build number')
    run(TOOLS / 'sign_update', '--account', account, '--verify', destination)


if __name__ == '__main__':
    import sys
    try:
        configure(Path(sys.argv[1]), os.environ)
    except (OSError, ValueError) as error:
        sys.exit(f'Update configuration failed: {error}')
