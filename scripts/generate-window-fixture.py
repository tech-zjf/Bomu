#!/usr/bin/env python3
"""Remux the licensed generated H.264 sample into one continuous 15-minute file."""
import json
from pathlib import Path
import subprocess
from media_fixtures import sha256_file, verify_manifest


def main():
    root = Path(__file__).resolve().parent.parent
    source_dir = root / '.build/benchmark-media'
    source = source_dir / 'h264-1080p.mp4'
    source_manifest = verify_manifest(source_dir)
    source_record = next(row for row in source_manifest['samples'] if row['file'] == source.name)
    destination = root / '.build/window-fixture'
    destination.mkdir(parents=True, exist_ok=True)
    output = destination / 'window-stress-1080p.mp4'
    # No seek/loop/reopen is sent to the player: its demuxer sees one continuous timeline.
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-stream_loop', '-1',
                    '-i', str(source), '-t', '900', '-map', '0:v:0', '-map', '0:a:0',
                    '-c', 'copy', '-movflags', '+faststart', str(output)], check=True)
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams',
        '-show_format', '-of', 'json', str(output)]))
    probe['format']['filename'] = output.name
    duration = float(probe['format']['duration'])
    if not 899 <= duration <= 901:
        raise SystemExit(f'Unexpected fixture duration: {duration}')
    manifest = {'schemaVersion': 1, 'generator': subprocess.check_output(
        ['ffmpeg', '-version'], text=True).splitlines()[0], 'samples': [{
            'file': output.name, 'sha256': sha256_file(output),
            'source': source_record['source'], 'license': source_record['license'],
            'sourceSHA256': source_record['sha256'],
            'derivation': 'Stream-copy repetition with continuous timestamps, limited to 900 seconds',
            'probe': probe}]}
    (destination / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print('Generated continuous 15-minute H.264 fixture for window lifecycle testing.')


if __name__ == '__main__':
    main()
