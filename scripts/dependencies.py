#!/usr/bin/env python3
"""Bootstrap, verify and embed the exact development runtime in Dependencies.lock.json."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'Config/Dependencies.lock.json').read_text())
LIBRARIES = ROOT / '.build/dependencies/lib'


def verify(path, expected):
    if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Missing or changed dependency: {path}\nRun python3 scripts/dependencies.py bootstrap.')


def check():
    unexpected = {p.name for p in LIBRARIES.glob('*.dylib')} - set(LOCK['libraries'])
    if unexpected:
        raise SystemExit(f'Unexpected libraries in the dependency cache: {sorted(unexpected)}')
    for name, item in LOCK['libraries'].items():
        verify(LIBRARIES / name, item['sha256'])
    for name, checksum in LOCK['headers'].items():
        verify(ROOT / name, checksum)


def bootstrap():
    source = LOCK['source']
    archive = ROOT / '.build/downloads' / f"IINA.v{source['version']}.dmg"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        partial = archive.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', source['url'], '-o', str(partial)], check=True)
        verify(partial, source['sha256'])
        partial.replace(archive)
    verify(archive, source['sha256'])
    LIBRARIES.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bomu-deps-', dir=ROOT / '.build') as directory:
        mount = Path(directory)
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(archive)], check=True)
        try:
            frameworks = mount / 'IINA.app/Contents/Frameworks'
            for name, item in LOCK['libraries'].items():
                verify(frameworks / name, item['sha256'])
                shutil.copy2(frameworks / name, LIBRARIES / name)
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
    check()
    print('Verified development runtime: mpv 0.41.0 / FFmpeg 9.0.1')


def embed(destination):
    if os.environ.get('CONFIGURATION') == 'Release':
        raise SystemExit('This dependency lock is for development only. Complete the distribution dependency/license workflow before Release.')
    check()
    destination.mkdir(parents=True, exist_ok=True)
    for name in LOCK['libraries']:
        output = destination / name
        shutil.copy2(LIBRARIES / name, output)
        # Local ad-hoc signatures belong to the copied build products, never the verified cache.
        subprocess.run(['codesign', '--force', '--sign', '-', str(output)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['bootstrap', 'check', 'embed'])
    parser.add_argument('destination', nargs='?', type=Path)
    args = parser.parse_args()
    if args.action == 'bootstrap':
        bootstrap()
    elif args.action == 'check':
        check()
    else:
        if args.destination is None:
            parser.error('embed requires a destination')
        embed(args.destination)


if __name__ == '__main__':
    main()
