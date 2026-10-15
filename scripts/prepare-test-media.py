#!/usr/bin/env python3
"""Generate missing local playback fixtures and verify their manifests."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from media_fixtures import verify_manifest


ROOT = Path(__file__).resolve().parents[1]
BASIC_SAMPLES = {
    'h264-sdr.mp4', 'h265-main10-sdr.mp4', 'mixed-audio-tracks.mp4', 'corrupt.mp4'
}
B11_SAMPLES = {'50-mpeg2-pal-program-stream.mpg'}


def manifest_has_samples(manifest_path, required_samples):
    try:
        manifest = json.loads(manifest_path.read_text())
        samples = manifest.get('samples')
        if not isinstance(samples, list):
            return False
        names = {sample.get('file') for sample in samples if isinstance(sample, dict)}
        return required_samples <= names
    except (OSError, json.JSONDecodeError):
        return False


def ensure_samples(directory, required_samples, generator):
    manifest_path = directory / 'manifest.json'
    if not manifest_has_samples(manifest_path, required_samples):
        subprocess.run(generator, cwd=ROOT, check=True)
    manifest = verify_manifest(directory)
    actual_samples = {sample['file'] for sample in manifest['samples']}
    if not required_samples <= actual_samples:
        raise ValueError(f'Generated fixture set is missing required samples: {directory}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--b11', action='store_true',
                        help='also prepare the 60-sample native integration suite')
    args = parser.parse_args()

    ensure_samples(ROOT / '.build/fixtures', BASIC_SAMPLES,
                   [str(ROOT / 'scripts/generate-fixtures.sh')])
    if args.b11:
        ensure_samples(ROOT / '.build/b11-media-suite', B11_SAMPLES,
                       [sys.executable, str(ROOT / 'scripts/generate-media-suite.py'),
                        '--suite', 'b11'])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
