#!/usr/bin/env python3
"""Shared integrity checks for local test and benchmark media (Python 3.9+)."""
import argparse
import hashlib
import json
from pathlib import Path
import re


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories', type=Path, nargs='+')
    args = parser.parse_args()
    try:
        for directory in args.directories:
            manifest = verify_manifest(directory)
            print(f'Verified {len(manifest["samples"])} media fixtures: {directory}')
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error


if __name__ == '__main__':
    main()
