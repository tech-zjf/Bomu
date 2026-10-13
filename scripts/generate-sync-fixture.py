#!/usr/bin/env python3
"""Generate and decode-check a deterministic flash/pulse synchronization fixture."""
from array import array
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1] / '.build/sync-fixture'
    root.mkdir(parents=True, exist_ok=True)
    path = root / 'av-sync-1080p60.mov'
    video = ('color=c=black:s=1920x1080:r=60:d=30,'
             'drawbox=x=720:y=300:w=480:h=480:color=white:t=fill:'
             "enable='gte(n,60)*lt(mod(n-60,120),6)'")
    audio = ("aevalsrc=exprs='if(gte(n,48000)*lt(mod(n-48000,96000),4800),"
             "0.2*sin(2*PI*1000*n/48000),0)':s=48000:d=30")
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', video, '-f', 'lavfi', '-i', audio,
        '-c:v', 'libx264', '-preset', 'fast', '-crf', '18', '-pix_fmt', 'yuv420p',
        '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
        '-c:a', 'pcm_s16le', '-movflags', '+faststart', str(path)], check=True)

    # Decode the encoded result rather than assuming filter expressions guarantee alignment.
    pixels = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path),
        '-map', '0:v:0', '-vf', 'crop=2:2:960:540,format=gray',
        '-f', 'rawvideo', '-pix_fmt', 'gray', '-'])
    bright = [pixels[index] > 200 for index in range(0, len(pixels), 4)]
    flashes = [index / 60 for index, value in enumerate(bright)
               if value and (index == 0 or not bright[index - 1])]
    pcm = array('h', subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(path),
        '-map', '0:a:0', '-f', 's16le', '-acodec', 'pcm_s16le', '-']))
    if sys.byteorder != 'little':
        pcm.byteswap()
    pulses = []
    last_active = -48000
    for index, amplitude in enumerate(pcm):
        if abs(amplitude) > 100:
            if index - last_active > 9600:
                pulses.append(index / 48000)
            last_active = index
    expected = list(range(1, 30, 2))
    if len(bright) != 1800 or len(pcm) != 1440000 or flashes != expected or len(pulses) != len(expected):
        raise RuntimeError('Unexpected decoded frame/sample count or pulse positions')
    maximum_offset = max(abs(sound - flash) for sound, flash in zip(pulses, flashes))
    if maximum_offset > 0.001:
        raise RuntimeError(f'Encoded fixture alignment exceeds 1 ms: {maximum_offset}')
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams',
                                               '-show_format', '-of', 'json', str(path)]))
    probe['format']['filename'] = path.name
    manifest = {
        'schemaVersion': 1,
        'generator': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
        'samples': [{
            'file': path.name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'source': 'Bomu generated black background, 480x480 white flashes and 1 kHz PCM pulses',
            'license': 'CC0-1.0', 'probe': probe,
            'alignment': {
                'flashDurationFrames': 6, 'pulseDurationSamples': 4800,
                'decodedFlashStartsSeconds': flashes, 'decodedPulseStartsSeconds': pulses,
                'maximumSourceOffsetMilliseconds': maximum_offset * 1000,
                'scope': 'Encoded media alignment only; screen and speaker latency are not measured.'
            }
        }]
    }
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Generated {path.name}: {len(flashes)} decoded flash/pulse pairs; '
          f'maximum source offset {maximum_offset * 1000:.4f} ms')


if __name__ == '__main__':
    main()
