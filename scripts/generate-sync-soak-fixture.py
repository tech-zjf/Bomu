#!/usr/bin/env python3
"""Generate a 33-minute, repeated audiovisual synchronization fixture."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / '.build/sync-soak-fixture'
DURATION_SECONDS = 1_980


def probe(path):
    return json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)
    ]))


def main():
    source_dir = ROOT / '.build/sync-fixture'
    if not (source_dir / 'manifest.json').exists():
        subprocess.run([sys.executable, str(ROOT / 'scripts/generate-sync-fixture.py')], check=True)
    source = source_dir / 'av-sync-1080p60.mov'
    OUTPUT.mkdir(parents=True, exist_ok=True)
    destination = OUTPUT / 'av-sync-33-minute.mp4'
    (OUTPUT / 'manifest.json').unlink(missing_ok=True)
    # Leave three minutes beyond the 1,800-second soak so its advancement checks cannot hit EOF.
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-stream_loop', '65', '-i', str(source),
        '-t', str(DURATION_SECONDS), '-map', '0:v:0', '-map', '0:a:0', '-c:v', 'copy',
        '-c:a', 'aac', '-b:a', '192k', '-ar', '48000', '-ac', '2', '-movflags', '+faststart',
        str(destination),
    ], check=True)
    inspected = probe(destination)
    duration = float(inspected['format']['duration'])
    streams = {stream['codec_type']: stream for stream in inspected['streams']}
    if not DURATION_SECONDS - 0.1 <= duration <= DURATION_SECONDS + 0.1:
        raise RuntimeError(f'Expected a 33-minute fixture, found {duration:.3f} seconds')
    video, audio = streams.get('video'), streams.get('audio')
    if not video or not audio or (video['width'], video['height'], video['avg_frame_rate']) != (1920, 1080, '60/1'):
        raise RuntimeError('The long synchronization fixture lost its expected 1080p60 audiovisual streams')
    # Decode around a source-loop seam to make sure repetition did not create a damaged boundary.
    subprocess.run(['ffmpeg', '-v', 'error', '-ss', '29.5', '-i', str(destination), '-t', '1.0',
                    '-f', 'null', '-'], check=True)
    inspected['format']['filename'] = destination.name
    entry = {
        'file': destination.name,
        'sha256': hashlib.sha256(destination.read_bytes()).hexdigest(),
        'source': 'Bomu-generated 30-second CC0 flash/pulse fixture repeated 66 times; video stream copied and audio encoded as AAC',
        'license': 'CC0-1.0',
        'probe': inspected,
        'durationSeconds': duration,
        'decodedLoopSeamCheck': {'startSeconds': 29.5, 'durationSeconds': 1.0, 'passed': True},
        'scope': 'Source A/V alignment was decoded and measured in the source fixture. This file supports long playback observation; it does not itself measure display-to-speaker latency.',
    }
    (OUTPUT / 'manifest.json').write_text(json.dumps({
        'schemaVersion': 1,
        'generator': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
        'samples': [entry],
    }, indent=2) + '\n')
    print(f'Generated {destination.name}: {duration:.3f}s, 1920x1080@60 with audio')


if __name__ == '__main__':
    main()
