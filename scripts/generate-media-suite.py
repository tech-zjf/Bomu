#!/usr/bin/env python3
"""Build A04's 30-case or B11's 60-case licensed local media suite.

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

# The B11 acceptance matrix consists of 60 decodable samples with both video and
# audio. A04 keeps its silent, audio-only, invalid-file, and truncated-file cases.
B11_ADDITIONAL_RECIPES = [
    Recipe('31-h264-baseline-720x480.mp4', 'H.264 Baseline / 720×480 / 30000:1001',
           size='720x480', rate='30000/1001', profile='baseline'),
    Recipe('32-h264-main-720p50.mp4', 'H.264 Main / 720p / 50 fps',
           size='1280x720', rate='50', profile='main'),
    Recipe('33-h264-high-1080p24.mp4', 'H.264 High / 1080p / 24 fps',
           size='1920x1080', rate='24'),
    Recipe('34-h264-high-4k30.mp4', 'H.264 High / 4K / 30 fps',
           size='3840x2160', rate='30'),
    Recipe('35-h264-pal-anamorphic.mp4', 'H.264 / 720×576 PAL / 16:15 sample aspect ratio',
           size='720x576', rate='25', filter='setsar=16/15'),
    Recipe('36-h264-portrait-1080.mp4', 'H.264 portrait / 1080×1920', size='1080x1920'),
    Recipe('37-h264-ultrawide-1920.mp4', 'H.264 ultrawide / 1920×804 / 24 fps',
           size='1920x804', rate='24'),
    Recipe('38-h264-qhd30.mp4', 'H.264 High / 2560×1440 / 30 fps', size='2560x1440'),
    Recipe('39-h264-sd60.mp4', 'H.264 High / 854×480 / 60 fps', size='854x480', rate='60'),
    Recipe('40-h264-vga30.mp4', 'H.264 Main / 640×480 / 30 fps', size='640x480', profile='main'),
    Recipe('41-h264-fullhd50.mp4', 'H.264 High / 1080p / 50 fps', size='1920x1080', rate='50'),
    Recipe('42-h264-hd60.mp4', 'H.264 High / 720p / 60 fps', size='1280x720', rate='60'),
    Recipe('43-hevc-main-1080p60.mp4', 'HEVC Main 8-bit / 1080p / 60 fps',
           size='1920x1080', rate='60', video='libx265', profile='main'),
    Recipe('44-hevc-main10-720p30.mp4', 'HEVC Main10 SDR / 720p / 30 fps',
           size='1280x720', video='libx265', pixel_format='yuv420p10le', profile='main10'),
    Recipe('45-hevc-main10-qhd30.mp4', 'HEVC Main10 SDR / 2560×1440 / 30 fps',
           size='2560x1440', video='libx265', pixel_format='yuv420p10le', profile='main10'),
    Recipe('46-hevc-main10-fullhd25.mkv', 'Matroska / HEVC Main10 SDR / 1080p25',
           size='1920x1080', rate='25', video='libx265', pixel_format='yuv420p10le', profile='main10'),
    Recipe('47-vp9-720p60.webm', 'WebM / VP9 720p60 / Opus',
           size='1280x720', rate='60', video='libvpx-vp9', profile='', audio='libopus'),
    Recipe('48-vp9-1080p30.webm', 'WebM / VP9 1080p30 / Opus',
           size='1920x1080', video='libvpx-vp9', profile='', audio='libopus'),
    Recipe('49-mpeg4-part2-avi.avi', 'AVI / MPEG-4 Part 2 / MP3 audio',
           size='640x480', rate='25', video='mpeg4', profile='', audio='libmp3lame', sample_rate=44100),
    Recipe('50-mpeg2-pal-program-stream.mpg', 'MPEG-2 PAL program stream / MP2 audio',
           size='720x576', rate='25', video='mpeg2video', profile='', audio='mp2'),
    Recipe('51-prores-422-hd.mov', 'QuickTime / ProRes 422 / PCM16', size='1280x720', rate='25',
           video='prores_ks', pixel_format='yuv422p10le', profile='', audio='pcm_s16le'),
    Recipe('52-h264-ac3-surround.mkv', 'H.264 with AC-3 5.1-channel audio', audio='ac3', channels=6),
    Recipe('53-h264-eac3-surround.mkv', 'H.264 with E-AC-3 5.1-channel audio', audio='eac3', channels=6),
    Recipe('54-h264-flac-audio.mkv', 'H.264 with lossless FLAC audio', audio='flac'),
    Recipe('55-h264-pcm24.mov', 'QuickTime / H.264 + PCM24', audio='pcm_s24le'),
    Recipe('56-h264-pcm16.mov', 'QuickTime / H.264 + PCM16', audio='pcm_s16le'),
    Recipe('57-h264-mp3-44100.mkv', 'H.264 with MP3 stereo / 44.1 kHz',
           audio='libmp3lame', sample_rate=44100),
    Recipe('58-h264-opus.mkv', 'H.264 with Opus stereo / 48 kHz', audio='libopus'),
    Recipe('59-h264-aac-96000.mkv', 'H.264 with AAC stereo / 96 kHz', sample_rate=96000),
    Recipe('60-hevc-main10-4k30-eac3.mkv', 'HEVC Main10 4K30 / E-AC-3 5.1',
           size='3840x2160', rate='30', video='libx265', pixel_format='yuv420p10le',
           profile='main10', audio='eac3', channels=6),
    Recipe('61-h264-mono-44100.mp4', 'H.264 with AAC mono / 44.1 kHz',
           audio='aac', sample_rate=44100, channels=1),
    Recipe('62-h264-aac-5-1.mkv', 'H.264 with AAC 5.1-channel audio', channels=6),
    Recipe('63-h264-alac.mov', 'QuickTime / H.264 + ALAC lossless audio', audio='alac'),
    Recipe('64-hevc-main-720p50.mkv', 'Matroska / HEVC Main 8-bit / 720p50',
           size='1280x720', rate='50', video='libx265', profile='main'),
    Recipe('65-hevc-main10-1080p30-opus.mkv', 'HEVC Main10 1080p30 / Opus',
           size='1920x1080', video='libx265', pixel_format='yuv420p10le', profile='main10', audio='libopus'),
    Recipe('66-h264-aac-48000-51.mkv', 'H.264 with AAC 5.1 / 48 kHz', channels=6),
    Recipe('67-h264-high-960x540.mp4', 'H.264 High / 960×540 / AAC', size='960x540'),
]


def recipes_for_suite(name):
    if name == 'a04':
        return RECIPES
    if name == 'b11':
        base = [recipe for recipe in RECIPES if recipe.video and recipe.audio
                and recipe.special not in {'invalid', 'truncated'}]
        recipes = base + B11_ADDITIONAL_RECIPES
        if len(recipes) != 60 or any(not recipe.video or not recipe.audio for recipe in recipes):
            raise ValueError('B11 suite must contain exactly 60 audio/video samples')
        if len({recipe.file for recipe in recipes}) != len(recipes):
            raise ValueError('B11 suite filenames must be unique')
        return recipes
    raise ValueError(f'Unknown media suite: {name}')


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
        codec = {'libx264': 'h264', 'libx265': 'hevc', 'libvpx-vp9': 'vp9',
                 'mpeg4': 'mpeg4', 'mpeg2video': 'mpeg2video', 'prores_ks': 'prores'}[recipe.video]
        if (stream['width'], stream['height'], stream['codec_name']) != (width, height, codec):
            raise ValueError(f'{recipe.file}: unexpected video codec or size')
        if stream['pix_fmt'] not in ({'yuvj420p'} if recipe.full_range else {recipe.pixel_format}):
            raise ValueError(f'{recipe.file}: unexpected pixel format {stream["pix_fmt"]}')
        profiles = {'baseline': 'Constrained Baseline', 'main': 'Main', 'high': 'High', 'main10': 'Main 10'}
        if recipe.profile and stream['profile'] != profiles[recipe.profile]:
            raise ValueError(f'{recipe.file}: unexpected profile {stream["profile"]}')
        if not recipe.variable_rate and abs(float(Fraction(stream['avg_frame_rate'])) - float(Fraction(recipe.rate))) > 0.01:
            raise ValueError(f'{recipe.file}: unexpected frame rate')
        if recipe.filter.startswith('setsar='):
            expected_aspect_ratio = recipe.filter.removeprefix('setsar=').replace('/', ':')
            if stream['sample_aspect_ratio'] != expected_aspect_ratio:
                raise ValueError(f'{recipe.file}: expected sample aspect ratio {expected_aspect_ratio}')
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
    parser.add_argument('--suite', choices=('a04', 'b11'), default='a04')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    recipes = recipes_for_suite(args.suite)
    output = args.output or ROOT / ('.build/media-suite' if args.suite == 'a04' else '.build/b11-media-suite')
    directory = output.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    # A failed regeneration must not leave an old success manifest beside new files.
    (directory / 'manifest.json').unlink(missing_ok=True)
    sync_root = ROOT / '.build/sync-fixture'
    if not (sync_root / 'manifest.json').exists():
        subprocess.run([sys.executable, str(ROOT / 'scripts/generate-sync-fixture.py')], check=True)
    sync = verify_manifest(sync_root)['samples'][0]
    samples = []
    for recipe in recipes:
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
        print(f'{len(samples):02d}/{len(recipes)} verified {path.name}', flush=True)
    manifest = {'schemaVersion': 2, 'suite': f'bomu-{args.suite}', 'generatorSHA256': sha256_file(__file__),
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
        f'Bomu {args.suite.upper()} synthetic media suite\n{len(samples)} independently generated cases.\n'
        'See manifest.json for actual properties, source, coverage, SHA-256 and generation commands.\n'
        'Synthetic coverage does not establish real-camera compatibility, calibrated color, HDR or physical A/V sync.\n'
        '29-sync.mov contains verified source alignment only. Do not treat it as a speaker/display measurement.\n')
    verify_manifest(directory)
    print(f'Completed licensed media suite: {directory}')


if __name__ == '__main__':
    main()
