#!/usr/bin/env python3
"""Bootstrap, verify and embed the exact development runtime in Dependencies.lock.json."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

import ffmpeg_overlay

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'Config/Dependencies.lock.json').read_text())
LIBRARIES = ROOT / '.build/dependencies/lib'
PACKAGE_RESOLVED = ROOT / 'Bomu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'


def verify(path, expected):
    actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else 'missing'
    if actual != expected:
        raise SystemExit(f'Missing or changed dependency: {path}\nExpected {expected}; found {actual}.\n'
                         'Run python3 scripts/dependencies.py bootstrap.')


def copy_locked_archive_libraries(archive_path, destination, *, expected_names, selected_hashes):
    """Copy selected flat dylibs from a verified ZIP without extracting untrusted paths."""
    archive_path = Path(archive_path)
    destination = Path(destination)
    expected_names = set(expected_names)
    selected_names = set(selected_hashes)
    if not selected_names <= expected_names:
        raise ValueError('Selected dependency names are not present in the locked archive contents.')

    with zipfile.ZipFile(archive_path) as archive:
        members = archive.infolist()
        names = [member.filename for member in members]
        if len(names) != len(set(names)):
            raise ValueError('Dependency archive contains duplicate paths.')
        if set(names) != expected_names:
            raise ValueError('Dependency archive contents do not match the locked runtime file set.')
        if any('/' in name or '\\' in name or name in {'.', '..'} for name in names):
            raise ValueError('Dependency archive must contain flat library filenames only.')
        if any(member.is_dir() for member in members):
            raise ValueError('Dependency archive must not contain directory entries.')

        destination.mkdir(parents=True, exist_ok=True)
        for name in sorted(selected_names):
            member = archive.getinfo(name)
            output = destination / name
            digest = hashlib.sha256()
            try:
                with archive.open(member) as source, output.open('wb') as target:
                    while chunk := source.read(1024 * 1024):
                        digest.update(chunk)
                        target.write(chunk)
                if digest.hexdigest() != selected_hashes[name]:
                    raise ValueError(f'Locked binary hash mismatch for {name}.')
            except Exception:
                output.unlink(missing_ok=True)
                raise


def check(directory=LIBRARIES):
    unexpected = {p.name for p in directory.glob('*.dylib')} - set(LOCK['libraries'])
    if unexpected:
        raise SystemExit(f'Unexpected libraries in the dependency cache: {sorted(unexpected)}')
    for name, item in LOCK['libraries'].items():
        verify(directory / name, item['sha256'])
    for name, checksum in LOCK['headers'].items():
        verify(ROOT / name, checksum)
    for name, package in LOCK.get('swiftPackages', {}).items():
        if not PACKAGE_RESOLVED.is_file():
            raise SystemExit(f'Missing Swift package lock: {PACKAGE_RESOLVED}')
        resolved = json.loads(PACKAGE_RESOLVED.read_text())
        pin = next((item for item in resolved.get('pins', [])
                    if item.get('identity', '').casefold() == name.casefold()), None)
        state = (pin or {}).get('state', {})
        if (pin is None or state.get('version') != package['version']
                or state.get('revision') != package['revision']
                or pin.get('location') != package['url']):
            raise SystemExit(f"Swift package lock mismatch for {name}; resolve the exact version in Config/Dependencies.lock.json.")


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
    runtime_artifact = LOCK['verifiedRuntimeArtifact']
    runtime_archive = ROOT / '.build/downloads' / 'iina-deps-fat.zip'
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        partial = archive.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', source['url'], '-o', str(partial)], check=True)
        verify(partial, source['sha256'])
        partial.replace(archive)
    verify(archive, source['sha256'])
    if not runtime_archive.exists():
        partial = runtime_archive.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2',
                        runtime_artifact['url'], '-o', str(partial)], check=True)
        verify(partial, runtime_artifact['sha256'])
        partial.replace(runtime_archive)
    verify(runtime_archive, runtime_artifact['sha256'])
    LIBRARIES.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bomu-deps-', dir=LIBRARIES.parent) as directory:
        work = Path(directory)
        mount = work / 'mount'
        mount.mkdir()
        staging = work / 'lib'
        staging.mkdir()
        replacement_names = set(runtime_artifact['overriddenLibraries'])
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(archive)], check=True)
        try:
            frameworks = mount / 'IINA.app/Contents/Frameworks'
            for name, item in LOCK['libraries'].items():
                if name in replacement_names:
                    expected = runtime_artifact['replacedDMGHashes'][name]
                else:
                    expected = overlay['baseSHA256'] if name == overlay['library'] else item['sha256']
                verify(frameworks / name, expected)
                if name not in replacement_names:
                    shutil.copy2(frameworks / name, staging / name)
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True)
        copy_locked_archive_libraries(
            runtime_archive,
            staging,
            expected_names=LOCK['libraries'],
            selected_hashes={name: LOCK['libraries'][name]['sha256'] for name in replacement_names},
        )
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
        audit = subprocess.run([sys.executable, str(ROOT / 'scripts/license_audit.py'), 'check'])
        if audit.returncode != 0:
            raise SystemExit('Release build stopped because the dependency license/provenance audit is incomplete.')
        if not LOCK.get('distributionReady', False):
            raise SystemExit('Release build stopped because Dependencies.lock.json does not declare distributionReady.')
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
