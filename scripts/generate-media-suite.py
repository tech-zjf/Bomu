#!/usr/bin/env python3
"""Build A04's 30 licensed local media cases, then probe and decode the actual files.

The generated patterns and tones are dedicated to CC0-1.0. No external footage,
fonts or recordings are used. Python 3.9+; FFmpeg/ffprobe must be on PATH.
"""
import argparse
from dataclasses import dataclass
from fractions import Fraction
import json
from pathlib import Path
import shutil
import subprocess
import sys

from media_fixtures import sha256_file, verify_manifest


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Recipe:
    file: str
    coverage: str
    size: str = '960x540'
    rate: str = '30'
    video: str = 'libx264'
    pixel_format: str = 'yuv420p'
    profile: str = 'high'
    audio: str = 'aac'
    sample_rate: int = 48000
    channels: int = 2
    filter: str = ''
    rotate: bool = False
    variable_rate: bool = False
    dual_audio: bool = False
    full_range: bool = False
    special: str = ''


RECIPES = [
    Recipe('01-baseline-480p.mp4', 'H.264 Constrained Baseline / 480p', size='854x480', profile='baseline'),
    Recipe('02-main-720p25.mp4', 'H.264 Main / 720p / 25 fps', size='1280x720', rate='25', profile='main'),
    Recipe('03-high-1080p30.mp4', 'H.264 High / 1080p / 30 fps', size='1920x1080'),
    Recipe('04-high-1080p60.mp4', 'H.264 High / 1080p / 60 fps', size='1920x1080', rate='60'),
    Recipe('05-high-4k24.mp4', 'H.264 High / 4K / 24 fps', size='3840x2160', rate='24'),
    Recipe('06-portrait.mp4', '9:16 portrait', size='720x1280'),
    Recipe('07-square.mp4', '1:1 square', size='720x720'),
    Recipe('08-中文 宽银幕.mp4', '21:9 ultrawide / Unicode and space in filename', size='1470x630', rate='24'),
    Recipe('09-anamorphic.mp4', '720×576 with 64:45 sample aspect ratio', size='720x576', rate='25', filter='setsar=64/45'),
    Recipe('10-rotation.mp4', '90° display matrix', size='640x360', rotate=True),
    Recipe('11-variable-rate.mp4', 'Variable frame intervals: 30 then 15 fps', variable_rate=True),
    Recipe('12-fractional-rate.mp4', '30000/1001 fractional frame rate', rate='30000/1001'),
    Recipe('13-hevc-main.mp4', 'HEVC Main 8-bit / MP4', size='1280x720', video='libx265', profile='main'),
    Recipe('14-hevc-main10.mp4', 'HEVC Main10 SDR / 1080p', size='1920x1080', video='libx265', pixel_format='yuv420p10le', profile='main10'),
    Recipe('15-hevc-main10-4k.mp4', 'HEVC Main10 SDR / 4K', size='3840x2160', video='libx265', pixel_format='yuv420p10le', profile='main10'),
    Recipe('16-invalid.mp4', 'Invalid container / subsequent valid file must recover', special='invalid'),
    Recipe('17-h264-flac.mkv', 'Matroska / H.264 + FLAC', audio='flac'),
    Recipe('18-hevc-main10.mkv', 'Matroska / HEVC Main10 + AAC', video='libx265', pixel_format='yuv420p10le', profile='main10'),
    Recipe('19-h264-pcm.mov', 'QuickTime / H.264 + PCM16', audio='pcm_s16le'),
    Recipe('20-h264-aac.ts', 'MPEG-TS / H.264 + AAC'),
    Recipe('21-vp9-opus.webm', 'WebM / VP9 + Opus', video='libvpx-vp9', profile='', audio='libopus'),
    Recipe('22-full-range.mp4', 'Explicit full-range SDR', full_range=True),
    Recipe('23-silent.mp4', 'Video without an audio track', audio=''),
    Recipe('24-audio-aac.m4a', 'Audio-only AAC / stereo / 44.1 kHz', video='', sample_rate=44100),
    Recipe('25-audio-mono.mp3', 'Audio-only MP3 / mono / 44.1 kHz', video='', audio='libmp3lame', sample_rate=44100, channels=1),
    Recipe('26-audio-flac.flac', 'Audio-only lossless FLAC / stereo / 48 kHz', video='', audio='flac'),
    Recipe('27-audio-pcm24.wav', 'Audio-only PCM24 / stereo / 96 kHz', video='', audio='pcm_s24le', sample_rate=96000),
    Recipe('28-two-audio-tracks.mkv', 'Two distinct AAC tracks / default-track decoding', dual_audio=True),
    Recipe('29-sync.mov', 'Decoded flash/pulse alignment / 1080p60', special='sync'),
    Recipe('30-truncated.mp4', 'MP4 truncated to its 32-byte header / recovery', special='truncated'),
]


def command(arguments):
    subprocess.run(arguments, check=True, stdout=subprocess.DEVNULL)


def generate(recipe, path):
    arguments = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-filter_threads', '2']
    if recipe.video:
        arguments += ['-f', 'lavfi', '-i', f'testsrc2=size={recipe.size}:rate={recipe.rate}']
    if recipe.audio:
        arguments += ['-f', 'lavfi', '-i', f'sine=frequency=440:sample_rate={recipe.sample_rate}']
    if recipe.dual_audio:
        arguments += ['-f', 'lavfi', '-i', f'sine=frequency=880:sample_rate={recipe.sample_rate}']
    if recipe.video:
        arguments += ['-map', '0:v:0', '-c:v', recipe.video, '-threads:v', '2']
        if recipe.video in {'libx264', 'libx265'}:
            arguments += ['-preset', 'veryfast', '-crf', '24', '-profile:v', recipe.profile]
        if recipe.video == 'libx265':
            arguments += ['-x265-params', 'log-level=error:pools=1:frame-threads=1', '-tag:v', 'hvc1']
        if recipe.video == 'libvpx-vp9':
            arguments += ['-deadline', 'realtime', '-cpu-used', '6', '-crf', '35', '-b:v', '0']
        filters = ['eq=saturation=0.45:brightness=-0.12']
        if recipe.filter:
            filters.append(recipe.filter)
        if recipe.variable_rate:
            filters.append("select='if(lt(t,3),1,not(mod(n,2)))'")
            arguments += ['-fps_mode', 'vfr']
        if recipe.full_range:
            filters.append('scale=in_range=tv:out_range=pc')
        arguments += ['-vf', ','.join(filters), '-pix_fmt', recipe.pixel_format,
                      '-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709',
                      '-color_range', 'pc' if recipe.full_range else 'tv']
    if recipe.audio:
        audio_input = 1 if recipe.video else 0
        arguments += ['-map', f'{audio_input}:a:0']
        if recipe.dual_audio:
            arguments += ['-map', '2:a:0', '-disposition:a:0', 'default', '-disposition:a:1', '0']
        arguments += ['-c:a', recipe.audio, '-ar', str(recipe.sample_rate), '-ac', str(recipe.channels)]
    if path.suffix in {'.mp4', '.mov', '.m4a'}:
        arguments += ['-movflags', '+faststart']
    arguments += ['-t', '6', str(path)]
    command(arguments)
    commands = [arguments[:-1] + [path.name]]
    if recipe.rotate:
        temporary = path.with_suffix('.rotating.mp4')
        rotation = ['ffmpeg', '-v', 'error', '-y', '-display_rotation:v:0', '90', '-i', str(path),
                    '-map', '0', '-c', 'copy', str(temporary)]
        command(rotation)
        temporary.replace(path)
        commands.append(['ffmpeg', '-v', 'error', '-y', '-display_rotation:v:0', '90', '-i', path.name,
                         '-map', '0', '-c', 'copy', temporary.name])
        commands.append(['mv', temporary.name, path.name])
    return commands


def inspect(path):
    result = subprocess.run(['ffprobe', '-v', 'error', '-show_streams', '-show_format',
                             '-of', 'json', str(path)], capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f'Cannot probe {path.name}: {result.stderr.strip()}')
    probe = json.loads(result.stdout)
    probe['format']['filename'] = path.name
    return probe


def validate_recipe(recipe, probe):
    """Reject misgenerated fixtures before their properties become native-test expectations."""
    video = [s for s in probe['streams'] if s['codec_type'] == 'video']
    audio = [s for s in probe['streams'] if s['codec_type'] == 'audio']
    if len(video) != int(bool(recipe.video)) or len(audio) != (2 if recipe.dual_audio else int(bool(recipe.audio))):
        raise ValueError(f'{recipe.file}: unexpected stream count')
    if video:
        stream = video[0]
        width, height = map(int, recipe.size.split('x'))
        codec = {'libx264': 'h264', 'libx265': 'hevc', 'libvpx-vp9': 'vp9'}[recipe.video]
        if (stream['width'], stream['height'], stream['codec_name']) != (width, height, codec):
            raise ValueError(f'{recipe.file}: unexpected video codec or size')
        if stream['pix_fmt'] not in ({'yuvj420p'} if recipe.full_range else {recipe.pixel_format}):
            raise ValueError(f'{recipe.file}: unexpected pixel format {stream["pix_fmt"]}')
        profiles = {'baseline': 'Constrained Baseline', 'main': 'Main', 'high': 'High', 'main10': 'Main 10'}
        if recipe.profile and stream['profile'] != profiles[recipe.profile]:
            raise ValueError(f'{recipe.file}: unexpected profile {stream["profile"]}')
        if not recipe.variable_rate and abs(float(Fraction(stream['avg_frame_rate'])) - float(Fraction(recipe.rate))) > 0.01:
            raise ValueError(f'{recipe.file}: unexpected frame rate')
        if recipe.filter.startswith('setsar=') and stream['sample_aspect_ratio'] != '64:45':
            raise ValueError(f'{recipe.file}: anamorphic aspect metadata is missing')
        if recipe.rotate and not any(abs(item.get('rotation', 0)) == 90 for item in stream.get('side_data_list', [])):
            raise ValueError(f'{recipe.file}: rotation metadata is missing')
        if recipe.full_range and stream.get('color_range') != 'pc':
            raise ValueError(f'{recipe.file}: full-range metadata is missing')
    codecs = {'libmp3lame': 'mp3', 'libopus': 'opus'}
    for stream in audio:
        if (stream['codec_name'], int(stream['sample_rate']), stream['channels']) != (
                codecs.get(recipe.audio, recipe.audio), recipe.sample_rate, recipe.channels):
            raise ValueError(f'{recipe.file}: unexpected audio format')
    duration = float(probe['format']['duration'])
    if not 5.8 <= duration <= 6.3:
        raise ValueError(f'{recipe.file}: unexpected duration {duration}')


def expected_properties(probe):
    video = next((s for s in probe['streams'] if s['codec_type'] == 'video'), None)
    audio = next((s for s in probe['streams'] if s['codec_type'] == 'audio'), None)
    expected = {'outcome': 'play', 'durationSeconds': float(probe['format']['duration'])}
    if video:
        expected['video'] = {'width': video['width'], 'height': video['height']}
    if audio:
        expected['audio'] = {'sampleRate': int(audio['sample_rate']), 'channels': audio['channels']}
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.build/media-suite')
    args = parser.parse_args()
    directory = args.output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    # A failed regeneration must not leave an old success manifest beside new files.
    (directory / 'manifest.json').unlink(missing_ok=True)
    sync_root = ROOT / '.build/sync-fixture'
    if not (sync_root / 'manifest.json').exists():
        subprocess.run([sys.executable, str(ROOT / 'scripts/generate-sync-fixture.py')], check=True)
    sync = verify_manifest(sync_root)['samples'][0]
    samples = []
    for recipe in RECIPES:
        path = directory / recipe.file
        sample = {'file': recipe.file, 'coverage': recipe.coverage, 'license': 'CC0-1.0',
                  'source': 'Bomu-generated geometric pattern and mathematical tones; no external media'}
        if recipe.special in {'invalid', 'truncated'}:
            if recipe.special == 'invalid':
                path.write_bytes(b'Bomu deliberately invalid media fixture.\n')
                sample['source'] = 'Bomu-generated plain text with an MP4 suffix'
            else:
                source = directory / RECIPES[0].file
                path.write_bytes(source.read_bytes()[:32])
                sample['source'] = 'First 32 bytes of the generated baseline MP4; no media payload'
                sample['derivedFromSHA256'] = sha256_file(source)
            try:
                inspect(path)
            except ValueError:
                sample['expected'] = {'outcome': 'reject'}
            else:
                raise ValueError(f'{path.name}: invalid fixture unexpectedly probes successfully')
        else:
            if recipe.special == 'sync':
                shutil.copyfile(sync_root / sync['file'], path)
                sample.update(source=sync['source'], alignment=sync['alignment'],
                              derivedFromSHA256=sync['sha256'])
            else:
                sample['commands'] = generate(recipe, path)
            probe = inspect(path)
            if not recipe.special:
                validate_recipe(recipe, probe)
            command(['ffmpeg', '-v', 'error', '-xerror', '-err_detect', 'explode', '-threads', '2',
                     '-i', str(path), '-map', '0:v?', '-map', '0:a?', '-f', 'null', '-'])
            if recipe.variable_rate:
                packets = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                    '-show_entries', 'packet=pts_time', '-of', 'json', str(path)]))['packets']
                timestamps = sorted(float(p['pts_time']) for p in packets)
                intervals = sorted({round(b - a, 4) for a, b in zip(timestamps, timestamps[1:])})
                if len(intervals) != 2 or abs(intervals[0] - 1/30) > 0.001 or abs(intervals[1] - 1/15) > 0.001:
                    raise ValueError(f'{path.name}: not the requested variable-rate stream: {intervals}')
                sample['decodedFrameIntervalsSeconds'] = intervals
            sample.update(probe=probe, expected=expected_properties(probe), decodeCheck='ffmpeg -xerror: all A/V streams decoded')
        sample['sha256'] = sha256_file(path)
        samples.append(sample)
        print(f'{len(samples):02d}/{len(RECIPES)} verified {path.name}', flush=True)
    manifest = {'schemaVersion': 2, 'suite': 'bomu-a04', 'generatorSHA256': sha256_file(__file__),
                'generator': subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
                'samples': samples}
    (directory / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    (directory / 'LICENSE.txt').write_text(
        'Bomu synthetic media fixtures — CC0-1.0\n'
        'To the extent possible under law, the Bomu contributors waive all copyright and related rights '
        'to these generated patterns, tones and intentionally invalid sample files.\n'
        'https://creativecommons.org/publicdomain/zero/1.0/\n'
        'No external footage, photographs, music, speech or fonts are included.\n')
    (directory / 'README.txt').write_text(
        'Bomu A04 synthetic media suite\n30 cases: 28 playable, 2 intentionally invalid.\n'
        'See manifest.json for actual properties, source, coverage, SHA-256 and generation commands.\n'
        'Synthetic coverage does not establish real-camera compatibility, calibrated color, HDR or physical A/V sync.\n'
        '29-sync.mov contains verified source alignment only. Do not treat it as a speaker/display measurement.\n')
    verify_manifest(directory)
    print(f'Completed licensed media suite: {directory}')


if __name__ == '__main__':
    main()
