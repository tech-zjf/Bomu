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

import ffmpeg_overlay

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'Config/Dependencies.lock.json').read_text())
LIBRARIES = ROOT / '.build/dependencies/lib'


def verify(path, expected):
    actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'missing'
    if actual != expected:
        raise SystemExit(f'Missing or changed dependency: {path}\nExpected {expected}; found {actual}.\n'
                         'Run python3 scripts/dependencies.py bootstrap.')


def check(directory=LIBRARIES):
    unexpected = {p.name for p in directory.glob('*.dylib')} - set(LOCK['libraries'])
    if unexpected:
        raise SystemExit(f'Unexpected libraries in the dependency cache: {sorted(unexpected)}')
    for name, item in LOCK['libraries'].items():
        verify(directory / name, item['sha256'])
    for name, checksum in LOCK['headers'].items():
        verify(ROOT / name, checksum)


def copy_original_format_library(destination):
    """Extract the original IINA format library for before/after seek experiments."""
    source = LOCK['source']
    overlay = LOCK['ffmpegOverlay']
    archive = ROOT / '.build/downloads' / f"IINA.v{source['version']}.dmg"
    verify(archive, source['sha256'])
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bomu-baseline-', dir=ROOT / '.build') as directory:
        mount = Path(directory)
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint',
                        str(mount), str(archive)], check=True)
        try:
            original = mount / 'IINA.app/Contents/Frameworks' / overlay['library']
            verify(original, overlay['baseSHA256'])
            shutil.copy2(original, destination)
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
    verify(destination, overlay['baseSHA256'])


def bootstrap():
    source = LOCK['source']
    overlay = LOCK['ffmpegOverlay']
    if (overlay['version'] != ffmpeg_overlay.SOURCE_VERSION
            or overlay['url'] != ffmpeg_overlay.SOURCE_URL
            or overlay['sha256'] != ffmpeg_overlay.SOURCE_SHA256
            or overlay.get('normalizeBuildUUID') != 'content-sha256-v1'
            or overlay['patch'] != str(ffmpeg_overlay.PATCH.relative_to(ROOT))
            or overlay['patchSHA256'] != hashlib.sha256(ffmpeg_overlay.PATCH.read_bytes()).hexdigest()
            or overlay['configure'] != ffmpeg_overlay.CONFIGURE):
        raise SystemExit('FFmpeg overlay definition differs from its verified builder.')
    archive = ROOT / '.build/downloads' / f"IINA.v{source['version']}.dmg"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        partial = archive.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', source['url'], '-o', str(partial)], check=True)
        verify(partial, source['sha256'])
        partial.replace(archive)
    verify(archive, source['sha256'])
    LIBRARIES.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bomu-deps-', dir=LIBRARIES.parent) as directory:
        work = Path(directory)
        mount = work / 'mount'
        mount.mkdir()
        staging = work / 'lib'
        staging.mkdir()
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(archive)], check=True)
        try:
            frameworks = mount / 'IINA.app/Contents/Frameworks'
            for name, item in LOCK['libraries'].items():
                expected = overlay['baseSHA256'] if name == overlay['library'] else item['sha256']
                verify(frameworks / name, expected)
                shutil.copy2(frameworks / name, staging / name)
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
        overlay_build = work / 'ffmpeg-overlay'
        overlay_build.mkdir()
        library = ffmpeg_overlay.build_library(overlay_build)
        shutil.copy2(library, staging / overlay['library'])
        verify(staging / overlay['library'], overlay['librarySHA256'])
        check(staging)
        backup = work / 'previous-lib'
        if LIBRARIES.exists():
            LIBRARIES.replace(backup)
        try:
            staging.replace(LIBRARIES)
        except Exception:
            if backup.exists() and not LIBRARIES.exists():
                backup.replace(LIBRARIES)
            raise
    print('Verified development runtime: mpv 0.41.0 / FFmpeg 9.0.1 + pinned TS-seek overlay')


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
