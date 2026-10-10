#!/usr/bin/env python3
"""Adapt SwiftPM-generated resource lookup for a macOS .app before the compiler reads it.
No upstream source/inference code is changed; command-line builds also retain their fallback.
"""
import os
from pathlib import Path
import shlex
import subprocess
import sys

arguments = sys.argv[1:]
sources = list(arguments)
for index, argument in enumerate(arguments):
    if argument == '-filelist' and index + 1 < len(arguments):
        sources.extend(Path(arguments[index + 1]).read_text().splitlines())
    elif argument.startswith('@') and Path(argument[1:]).is_file():
        sources.extend(shlex.split(Path(argument[1:]).read_text()))
for source in sources:
    path = Path(source.strip('"'))
    if path.name != 'resource_bundle_accessor.swift' or not path.is_file():
        continue
    original = path.read_text()
    adapted = original.replace('Bundle.main.bundleURL.appendingPathComponent(',
                               '(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent(')
    if adapted != original:
        path.write_text(adapted)
compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
os.execv(compiler, [compiler, *arguments])
