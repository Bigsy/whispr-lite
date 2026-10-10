#!/usr/bin/env python3
"""Validate untrusted tag/input values before passing them to build/signing tools."""
import importlib.util
import os
from pathlib import Path

spec = importlib.util.spec_from_file_location('packaging', Path(__file__).with_name('package-release.py'))
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


def plan(ref, requested_version='', requested_channel='preview'):
    tagged = ref.startswith('refs/tags/')
    value = ref.removeprefix('refs/tags/v') if tagged else requested_version
    if tagged and not ref.startswith('refs/tags/v'):
        raise ValueError('Release tags must start with v')
    numeric = packaging.version(value)
    channel = ('preview' if '-' in value else 'notarized') if tagged else requested_channel
    if channel not in ('preview', 'notarized'):
        raise ValueError('Invalid release channel')
    return dict(RELEASE_VERSION=value, APP_VERSION=numeric, RELEASE_CHANNEL=channel)


if __name__ == '__main__':
    try:
        values = plan(os.environ['GITHUB_REF'], os.environ.get('REQUESTED_VERSION', ''),
                      os.environ.get('REQUESTED_CHANNEL') or 'preview')
        build = os.environ['GITHUB_RUN_NUMBER']
        if not build.isdecimal(): raise ValueError('Invalid build number')
        values['APP_BUILD_NUMBER'] = build
        with open(os.environ['GITHUB_ENV'], 'a') as environment:
            for key, value in values.items(): environment.write(f'{key}={value}\n')
        print(f"Preparing {values['RELEASE_VERSION']} ({values['RELEASE_CHANNEL']})")
    except (ValueError, KeyError):
        raise SystemExit('Invalid release configuration; use a vMAJOR.MINOR.PATCH[-beta.N] tag or explicit version/channel')
