#!/usr/bin/env python3
"""Build and compare an isolated FFmpeg TS-seek candidate. Python 3.9+.

Never replaces the application's dependency cache or claims desktop acceptance.
All media are generated locally or derived from the verified CC0 A04 fixtures.
"""
import argparse
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import time
import zlib

from media_fixtures import sha256_file, verify_manifest
from runtime_capabilities import compare_capabilities

ROOT = Path(__file__).resolve().parents[1]
SOURCE_URL = 'https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz'
SOURCE_SHA256 = 'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635'
PATCH = ROOT / 'Tools/SeekProbe/ffmpeg-9.0.1-ts-keyframes.patch'
PROBE = ROOT / 'Tools/SeekProbe/main.c'
CONFIGURE = [
    '--enable-shared', '--disable-static', '--disable-autodetect', '--disable-doc',
    '--disable-debug', '--disable-programs', '--disable-encoders', '--disable-decoders',
    '--disable-muxers', '--disable-avfilter', '--disable-avdevice', '--disable-swscale',
    '--disable-swresample', '--install-name-dir=@rpath', '--arch=arm64', '--target-os=darwin',
    '--extra-cflags=-mmacosx-version-min=14.0', '--extra-ldflags=-mmacosx-version-min=14.0',
    '--cc=xcrun clang',
]
PLAYBACK_FORMAT_CONFIGURE = [argument for argument in CONFIGURE
                             if argument not in ['--disable-muxers', '--disable-decoders']] + [
    '--enable-gpl', '--enable-bzlib', '--enable-zlib', '--enable-iconv', '--enable-securetransport',
    '--extra-libs=-liconv',
]


def run_logged(arguments, log, cwd=None, timeout=600):
    with log.open('w') as output:
        subprocess.run(list(map(str, arguments)), cwd=cwd, stdout=output,
                       stderr=subprocess.STDOUT, check=True, timeout=timeout)


def source_archive():
    archive = ROOT / '.build/downloads/ffmpeg-9.0.1.tar.xz'
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        partial = archive.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', SOURCE_URL,
                        '-o', str(partial)], check=True, timeout=180)
        if sha256_file(partial) != SOURCE_SHA256:
            raise ValueError('FFmpeg source checksum mismatch')
        partial.replace(archive)
    if sha256_file(archive) != SOURCE_SHA256:
        raise ValueError('FFmpeg source checksum mismatch')
    return archive


def build_variant(output, archive, candidate, configure=CONFIGURE):
    name = 'candidate' if candidate else 'rebuilt'
    directory = output / name
    directory.mkdir()
    with tarfile.open(archive) as source:
        # The verified vendor archive also has to remain confined to this new directory.
        for member in source.getmembers():
            destination = (directory / member.name).resolve()
            if not destination.is_relative_to(directory.resolve()) or member.issym() or member.islnk():
                raise ValueError('Unsupported FFmpeg archive member')
        source.extractall(directory)
    source = directory / 'ffmpeg-9.0.1'
    if candidate:
        run_logged(['patch', '--batch', '--fuzz=0', '-p1', '-i', PATCH], directory / 'patch.log', cwd=source)
    run_logged([source / 'configure', *configure], directory / 'configure.log', cwd=source)
    run_logged(['make', '-j4', 'libavformat/libavformat.63.dylib'], directory / 'build.log', cwd=source)
    runtime = directory / 'runtime'
    shutil.copytree(ROOT / '.build/dependencies/lib', runtime)
    # Only the format library is experimental; every other runtime remains the pinned binary.
    shutil.copy2(source / 'libavformat/libavformat.63.dylib', runtime / 'libavformat.63.dylib')
    run_logged(['codesign', '--force', '--sign', '-', runtime / 'libavformat.63.dylib'], directory / 'sign.log')
    return runtime


def build_probe(output, name, runtime):
    binary = output / ('seek-probe-' + name)
    run_logged(['xcrun', 'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', '-arch', 'arm64',
                '-mmacosx-version-min=14.0', PROBE, '-I', ROOT / 'ThirdParty/libmpv/include',
                runtime / 'libmpv.2.dylib', '-Wl,-rpath,' + str(runtime), '-o', binary],
               output / ('probe-build-' + name + '.log'))
    return binary


def compressed_mov_header(data):
    def atom(kind, payload):
        return struct.pack('>I4s', len(payload) + 8, kind) + payload

    atoms, offset = [], 0
    while offset < len(data):
        if len(data) - offset < 8:
            raise ValueError('Truncated MOV atom')
        size, kind = struct.unpack_from('>I4s', data, offset)
        if size < 8 or size > len(data) - offset:
            raise ValueError('Fixture requires bounded 32-bit MOV atoms')
        atoms.append((offset, size, kind))
        offset += size
    headers = [(offset, size) for offset, size, kind in atoms if kind == b'moov']
    if len(headers) != 1 or not any(kind == b'mdat' for _, _, kind in atoms):
        raise ValueError('Fixture requires one moov and existing media data')
    offset, size = headers[0]
    payload = data[offset + 8:offset + size]
    compressed = atom(b'cmov', atom(b'dcom', b'zlib')
                      + atom(b'cmvd', struct.pack('>I', len(payload)) + zlib.compress(payload)))
    padding = len(payload) - len(compressed)
    if padding < 8:
        raise ValueError('Compressed header cannot preserve media offsets')
    # 保持原 moov 长度与所有 mdat 偏移；只压缩头部，不改动或重新编码音视频负载。
    replacement = atom(b'moov', compressed + atom(b'free', bytes(padding - 8)))
    return data[:offset] + replacement + data[offset + size:]


def generate_media(output, include_compressed_header=False):
    suite = ROOT / '.build/media-suite'
    verify_manifest(suite)
    manifest = json.loads((suite / 'manifest.json').read_text())
    for filename in ['20-h264-aac.ts', '14-hevc-main10.mp4', '24-audio-aac.m4a', '19-h264-pcm.mov']:
        sample = next(item for item in manifest['samples'] if item['file'] == filename)
        if sample['license'] != 'CC0-1.0':
            raise ValueError('Unlicensed test input')
    media = output / 'media'
    media.mkdir()
    commands = []

    def generate(filename, arguments):
        command = ['ffmpeg', '-nostdin', '-v', 'error', '-y', *map(str, arguments), str(media / filename)]
        subprocess.run(command, check=True, capture_output=True, timeout=120)
        commands.append(command)
        return media / filename

    short_ts = suite / '20-h264-aac.ts'
    short_mp4 = generate('same-payload.mp4', ['-i', short_ts, '-map', '0', '-c', 'copy'])
    short_mkv = generate('same-payload.mkv', ['-i', short_ts, '-map', '0', '-c', 'copy'])
    # Loop the indexed MP4. Looping the failing TS would itself exercise its broken seek-to-start.
    long_mp4 = generate('long.mp4', ['-stream_loop', '23', '-i', short_mp4, '-map', '0', '-c', 'copy'])
    long_ts = generate('long.ts', ['-i', long_mp4, '-map', '0', '-c', 'copy'])
    hevc_ts = generate('hevc.ts', ['-i', suite / '14-hevc-main10.mp4', '-map', '0', '-c', 'copy'])
    audio_ts = generate('audio.ts', ['-i', suite / '24-audio-aac.m4a', '-map', '0:a:0', '-c', 'copy'])
    mpeg2_ts = generate('mpeg2.ts', ['-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=30',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '6',
        '-c:v', 'mpeg2video', '-g', '60', '-bf', '2', '-q:v', '4', '-c:a', 'aac'])
    cases = [
        ('short-ts', short_ts, 3, 'video'), ('short-mp4', short_mp4, 3, 'video'),
        ('short-mkv', short_mkv, 3, 'video'), ('long-ts', long_ts, 123, 'video'),
        ('long-mp4', long_mp4, 123, 'video'), ('hevc-ts', hevc_ts, 3, 'video'),
        ('mpeg2-ts', mpeg2_ts, 3, 'video'), ('audio-ts', audio_ts, 3, 'audio'),
    ]
    compressed_control = None
    if include_compressed_header:
        original = suite / '19-h264-pcm.mov'
        compressed = media / 'compressed-header.mov'
        compressed.write_bytes(compressed_mov_header(original.read_bytes()))
        hashes = [subprocess.check_output(['ffmpeg', '-nostdin', '-v', 'error', '-xerror',
            '-i', str(path), '-map', '0', '-f', 'hash', '-hash', 'sha256', '-'], text=True, timeout=60).strip()
            for path in [original, compressed]]
        if len(set(hashes)) != 1:
            raise ValueError('Compressed MOV changed decoded video or audio')
        compressed_control = dict(sourceSHA256=sha256_file(original), decodedAudioVideoSHA256=hashes[0])
        cases.append(('compressed-mov', compressed, 3, 'video'))
    identities = []
    for name, path, target, kind in cases:
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-xerror', '-err_detect', 'explode',
                        '-i', str(path), '-map', '0', '-f', 'null', '-'], check=True, capture_output=True, timeout=120)
        probe = subprocess.check_output(['ffprobe', '-v', 'error', '-show_entries',
            'format=start_time,duration,size:stream=index,codec_type,codec_name,profile,pix_fmt,width,height',
            '-of', 'json', str(path)], text=True)
        identities.append(dict(case=name, file=path.name, sha256=sha256_file(path),
                               license='CC0-1.0', probe=json.loads(probe)))
    pixel_hashes = [subprocess.check_output(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(path),
                    '-map', '0:v:0', '-f', 'hash', '-hash', 'sha256', '-'], text=True).strip()
                    for path in [short_ts, short_mp4, short_mkv]]
    if len(set(pixel_hashes)) != 1:
        raise ValueError('Remux controls do not contain the same decoded video')
    return cases, dict(files=identities, generationCommands=commands, decodedVideoSHA256=pixel_hashes[0],
                       compressedMOVControl=compressed_control)


def finite_number(value):
    return isinstance(value, (float, int)) and not isinstance(value, bool) and math.isfinite(value)


def assess_measurements(measurements, target, video):
    if [item.get('stage') for item in measurements] != ['before', 'restart', 'paused-seek', 'resumed']:
        return ['Incomplete or reordered native measurements']
    before, restart, paused, resumed = measurements
    problems = []
    if not finite_number(restart.get('elapsedMS')) or not 0 <= restart['elapsedMS'] <= 10000:
        problems.append('Seek restart did not finish within its deadline')
    return problems + assess_seek_states(before, paused, resumed, target, video)


def assess_seek_states(before, paused, resumed, target, video):
    problems = []
    for sample in [before, paused, resumed]:
        if type(sample.get('frames')) is not int or sample['frames'] < 0:
            return ['Invalid native frame counter']
        if sample.get('seeking') is not False or sample.get('eof-reached') is not False:
            problems.append('Playback was still seeking or had ended')
        if sample.get('vo-configured') is not video:
            problems.append('Video output differs from the requested media kind')
        if not finite_number(sample.get('audio-out-params/samplerate')) or sample['audio-out-params/samplerate'] <= 0:
            problems.append('The diagnostic null audio output is unavailable')
    if before.get('pause') is not True or paused.get('pause') is not True or resumed.get('pause') is not False:
        problems.append('Pause intent was not retained through the seek')
    if not finite_number(paused.get('time-pos')) or abs(paused['time-pos'] - target) > 0.2:
        problems.append('Paused seek missed the target by more than 0.2 seconds')
    if not finite_number(resumed.get('time-pos')) or not target + 0.2 < resumed['time-pos'] < target + 1.5:
        problems.append('Playback did not resume near the requested target')
    if video and not before['frames'] < paused['frames'] < resumed['frames']:
        problems.append('Seek or resume produced no new video frames')
    if not video and any(sample['frames'] for sample in [before, paused, resumed]):
        problems.append('Audio-only playback unexpectedly submitted video')
    return problems


def measure_case(output, name, binary, case, options=()):
    label, file, target, kind = case
    log = output / (name + '-' + label + '.log')
    began = time.monotonic()
    with log.open('w') as stderr:
        try:
            process = subprocess.run([str(binary), str(file), str(target), kind, *options],
                                     stdout=subprocess.PIPE, stderr=stderr, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            return dict(variant=name, case=label, passed=False, problems=['Probe process exceeded 30 seconds'])
    (output / (name + '-' + label + '.jsonl')).write_text(process.stdout)
    try:
        measurements = [json.loads(line) for line in process.stdout.splitlines()]
        problems = assess_measurements(measurements, target, kind == 'video')
    except (json.JSONDecodeError, TypeError, AttributeError):
        measurements, problems = [], ['Invalid native JSON protocol']
    if process.returncode:
        problems.append('Native probe exited with code ' + str(process.returncode))
    return dict(variant=name, case=label, targetSeconds=target, options=list(options),
                passed=not problems, problems=problems, measurements=measurements,
                elapsedSeconds=time.monotonic() - began, logSHA256=sha256_file(log))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, help='New experiment directory (must not already exist)')
    parser.add_argument('--profile', choices=['diagnostic', 'playback-format'], default='diagnostic',
                        help='playback-format preserves format registries and system compression/TLS support')
    args = parser.parse_args()
    configure = PLAYBACK_FORMAT_CONFIGURE if args.profile == 'playback-format' else CONFIGURE
    subprocess.run([sys.executable, str(ROOT / 'scripts/toolchain.py')], check=True)
    subprocess.run([sys.executable, str(ROOT / 'scripts/dependencies.py'), 'check'], check=True)
    output = (args.output or ROOT / '.build/seek-candidates' / datetime.now().strftime('%Y%m%d-%H%M%S')).resolve()
    output.mkdir(parents=True, exist_ok=False)
    archive = source_archive()
    report = dict(schemaVersion=1, createdAt=datetime.now(timezone.utc).isoformat(),
        promotedToApplication=False, desktopVerified=False,
        measurementScope='libmpv software render to memory; null audio output; no physical display/audio evidence',
        source=dict(url=SOURCE_URL, sha256=SOURCE_SHA256, configure=configure, profile=args.profile),
        sourceSHA256={str(path.relative_to(ROOT)): sha256_file(path)
                      for path in [PROBE, PATCH, Path(__file__), ROOT / 'scripts/runtime_capabilities.py']},
        dependencyLockSHA256=sha256_file(ROOT / 'Config/Dependencies.lock.json'),
        ffmpegFixtureGenerator=subprocess.check_output(['ffmpeg', '-version'], text=True).splitlines()[0],
        runs=[], experimentPassed=False)
    try:
        runtimes = dict(pinned=ROOT / '.build/dependencies/lib')
        for candidate in [False, True]:
            name = 'candidate' if candidate else 'rebuilt'
            print('Building isolated ' + name + ' format library', flush=True)
            runtimes[name] = build_variant(output, archive, candidate, configure)
        report['runtimeSHA256'] = {name: {path.name: sha256_file(path) for path in sorted(runtime.glob('*.dylib'))}
                                   for name, runtime in runtimes.items()}
        report['capabilities'] = {}
        for name, runtime in runtimes.items():
            raw = subprocess.check_output([sys.executable, str(ROOT / 'scripts/runtime_capabilities.py'),
                                           str(runtime)], text=True, timeout=30)
            report['capabilities'][name] = json.loads(raw)
        report['capabilityDifferences'] = {name: compare_capabilities(report['capabilities']['pinned'],
            report['capabilities'][name]) for name in ['rebuilt', 'candidate']}
        if args.profile == 'playback-format' and any(report['capabilityDifferences'].values()):
            raise ValueError('Playback format capabilities differ from the pinned runtime; inspect report.json')
        cases, report['media'] = generate_media(output, include_compressed_header=args.profile == 'playback-format')
        binaries = {name: build_probe(output, name, runtime) for name, runtime in runtimes.items()}
        for name, binary in binaries.items():
            for case in cases:
                result = measure_case(output, name, binary, case)
                report['runs'].append(result)
                print(name, case[0], 'PASS' if result['passed'] else 'FAIL', flush=True)
        for name, case, options in [
            ('pinned-full-cache', cases[0], ['cache=yes']),
            ('pinned-bounded-cache', cases[3], ['cache=yes', 'cache-secs=10',
                'demuxer-max-bytes=2MiB', 'demuxer-max-back-bytes=1MiB']),
        ]:
            report['runs'].append(measure_case(output, name, binaries['pinned'], case, options))
        results = {(item['variant'], item['case']): item['passed'] for item in report['runs']}
        report['experimentPassed'] = (
            all(results['candidate', case[0]] for case in cases)
            and all(results[variant, name] for variant in ['pinned', 'rebuilt']
                    for name in ['short-mp4', 'short-mkv', 'long-mp4']
                    + (['compressed-mov'] if args.profile == 'playback-format' else []))
            and all(not results[variant, name] for variant in ['pinned', 'rebuilt']
                    for name in ['short-ts', 'long-ts'])
            and results['pinned-full-cache', 'short-ts']
            and not results['pinned-bounded-cache', 'long-ts'])
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Isolated experiment: ' + str(output / 'report.json'))
    return 0 if report['experimentPassed'] else 1


if __name__ == '__main__':
    sys.exit(main())
