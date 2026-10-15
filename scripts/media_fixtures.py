#!/usr/bin/env python3
"""Shared integrity checks for local test and benchmark media (Python 3.9+)."""
import argparse
import hashlib
import json
from pathlib import Path
import posixpath
import re
import tarfile


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def verify_manifest(directory):
    directory = Path(directory)
    manifest = json.loads((directory / 'manifest.json').read_text())
    samples = manifest.get('samples')
    if not isinstance(samples, list) or not samples:
        raise ValueError(f'Fixture manifest has no samples: {directory}')
    names = set()
    for sample in samples:
        if not isinstance(sample, dict):
            raise ValueError(f'Invalid fixture sample: {directory}')
        name, expected = sample.get('file'), sample.get('sha256')
        if not isinstance(name, str) or not name or Path(name).name != name or name in names:
            raise ValueError(f'Invalid or duplicate fixture filename: {name!r}')
        if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError(f'Invalid fixture SHA-256: {name}')
        if sha256_file(directory / name) != expected:
            raise ValueError(f'Fixture hash mismatch: {directory / name}. Regenerate its media.')
        names.add(name)
    return manifest


def verify_package(manifest_path, repository_root):
    """Verify a recorded media-suite archive without extracting untrusted paths."""
    manifest_path = Path(manifest_path)
    repository_root = Path(repository_root)
    manifest = json.loads(manifest_path.read_text())
    package = manifest.get('package')
    samples = manifest.get('samples')
    if not isinstance(package, dict) or not isinstance(samples, list) or not samples:
        raise ValueError(f'Invalid media package manifest: {manifest_path}')

    package_name = package.get('path')
    if not isinstance(package_name, str) or not package_name:
        raise ValueError('Invalid media package path')
    package_relative_path = Path(package_name)
    if package_relative_path.is_absolute() or '..' in package_relative_path.parts:
        raise ValueError('Media package path must stay within the repository')
    repository_root = repository_root.resolve()
    archive_path = repository_root / package_relative_path
    resolved_archive_path = archive_path.resolve(strict=True)
    if not resolved_archive_path.is_relative_to(repository_root):
        raise ValueError('Media package path resolves outside the repository')
    archive_path = resolved_archive_path
    expected_size = package.get('bytes')
    expected_hash = package.get('sha256')
    if not isinstance(expected_size, int) or expected_size < 1:
        raise ValueError('Invalid media package size')
    if not isinstance(expected_hash, str) or not re.fullmatch(r'[0-9a-f]{64}', expected_hash):
        raise ValueError('Invalid media package SHA-256')
    if archive_path.stat().st_size != expected_size or sha256_file(archive_path) != expected_hash:
        raise ValueError(f'Media package identity mismatch: {archive_path}')

    expected_samples = {}
    for sample in samples:
        if not isinstance(sample, dict):
            raise ValueError('Invalid media package sample record')
        name, digest = sample.get('file'), sample.get('sha256')
        if (not isinstance(name, str) or not name or posixpath.basename(name) != name
                or name in expected_samples or sample.get('license') != 'CC0-1.0'
                or not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest)):
            raise ValueError(f'Invalid media package sample: {sample!r}')
        expected_samples[name] = digest

    required = {f'media-suite/{name}' for name in expected_samples}
    required |= {'media-suite/manifest.json', 'media-suite/LICENSE.txt', 'media-suite/README.txt'}
    actual_samples = {}
    try:
        with tarfile.open(archive_path, 'r:gz') as archive:
            members = archive.getmembers()
            names = set()
            for member in members:
                name = member.name
                if (not name or name.startswith('/') or '\\' in name
                        or any(part in {'.', '..'} for part in name.split('/'))
                        or name in names or not (member.isfile() or member.isdir())):
                    raise ValueError(f'Unsafe or duplicate media package entry: {name!r}')
                names.add(name)
            if names not in (required, required | {'media-suite'}):
                raise ValueError('Media package entries do not match the manifest')

            for member in members:
                if not member.isfile():
                    continue
                name = member.name.removeprefix('media-suite/')
                stream = archive.extractfile(member)
                if stream is None:
                    raise ValueError(f'Cannot read media package entry: {member.name}')
                if name in expected_samples:
                    digest = hashlib.sha256()
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(chunk)
                    actual_samples[name] = digest.hexdigest()
                elif name == 'manifest.json':
                    embedded = json.load(stream)
                    embedded_samples = embedded.get('samples') if isinstance(embedded, dict) else None
                    if not isinstance(embedded_samples, list):
                        raise ValueError('Embedded media manifest has no samples')
                    if any(not isinstance(item, dict) for item in embedded_samples):
                        raise ValueError('Embedded media manifest contains an invalid sample')
                    embedded_hashes = {item.get('file'): item.get('sha256') for item in embedded_samples}
                    if len(embedded_hashes) != len(embedded_samples) or embedded_hashes != expected_samples:
                        raise ValueError('Embedded media manifest differs from the recorded manifest')
                elif name == 'LICENSE.txt':
                    text = stream.read().decode('utf-8')
                    if 'CC0-1.0' not in text or 'creativecommons.org/publicdomain/zero/1.0/' not in text:
                        raise ValueError('Media package does not contain its CC0-1.0 license')
                elif name == 'README.txt':
                    if 'manifest.json' not in stream.read().decode('utf-8'):
                        raise ValueError('Media package README does not reference its manifest')
    except (tarfile.TarError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f'Invalid media package archive: {archive_path}') from error

    if actual_samples != expected_samples:
        raise ValueError('Media package sample hashes do not match the recorded manifest')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', type=Path, nargs='*')
    parser.add_argument('--package-manifest', type=Path,
                        help='verify a packaged media suite using its recorded package identity')
    parser.add_argument('--repository-root', type=Path, default=Path.cwd())
    args = parser.parse_args()
    if not args.directories and not args.package_manifest:
        parser.error('provide fixture directories or --package-manifest')
    try:
        for directory in args.directories:
            manifest = verify_manifest(directory)
            print(f'Verified {len(manifest["samples"])} media fixtures: {directory}')
        if args.package_manifest:
            manifest = verify_package(args.package_manifest, args.repository_root)
            print(f'Verified media package: {manifest["package"]["path"]}')
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
