#!/usr/bin/env python3
"""Exercise a verified seek candidate through interleaved native operations; no windows."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

from media_fixtures import sha256_file, verify_manifest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('seek_candidate', ROOT / 'scripts/verify-seek-candidate.py')
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)
TARGETS = [3.75, 1.25, 4.25, 0.25]


def assess_release(sample):
    problems = []
    if any(sample.get(key) is not False for key in ['coreAlive', 'renderAlive', 'threadAlive']):
        problems.append('Native ownership was not fully released')
    elapsed = sample.get('elapsedMS')
    if not candidate.finite_number(elapsed) or not 0 <= elapsed <= 5000:
        problems.append('Native teardown exceeded five seconds')
    return problems


def assess_lifecycle(samples):
    stages = ['case', 'before', 'restart', 'paused-seek', 'resumed'] * len(TARGETS)
    stages += ['burst-before', 'burst-paused', 'burst-resumed', 'replacement-playing',
               'replacement-stable', 'stopped', 'quiet', 'released']
    if [sample.get('stage') for sample in samples] != stages:
        return ['Incomplete or reordered lifecycle measurements']
    problems = []
    for index, target in enumerate(TARGETS):
        marker, *measurements = samples[index * 5:index * 5 + 5]
        if marker.get('name') != 'sequential-' + str(index) or marker.get('target') != target:
            problems.append('Unexpected sequential seek target')
        problems.extend(candidate.assess_measurements(measurements, target, True))
    before, paused, resumed, replacement, stable, stopped, quiet, released = samples[-8:]
    problems.extend(candidate.assess_seek_states(before, paused, resumed, 3, True))
    if paused.get('lastReplyID') != 199:
        problems.append('The final queued seek was not acknowledged')
    if paused.get('commandReplies') != 100:
        problems.append('The seek burst has outstanding command replies')
    if stable.get('commandReplies') != 101 or quiet.get('commandReplies') != 102:
        problems.append('Replacement or stop has outstanding command replies')
    states = [sample for sample in samples if 'frames' in sample]
    for sample in states:
        if type(sample.get('frames')) is not int or sample['frames'] < 0:
            return problems + ['Invalid native frame counter']
        if type(sample.get('commandErrors')) is not int or sample['commandErrors'] != 0:
            problems.append('An asynchronous native command failed')
    if any(second['frames'] < first['frames'] for first, second in zip(states, states[1:])):
        problems.append('Frame counters reset inside one native session')
    active = [sample for sample in states if sample['stage'] not in ['stopped', 'quiet']]
    if any(sample.get('matchesFile') is not True for sample in active):
        problems.append('An old file remained active after replacement')
    for sample in [replacement, stable]:
        if (sample.get('pause') is not False or sample.get('seeking') is not False
                or sample.get('eof-reached') is not False or sample.get('vo-configured') is not True):
            problems.append('Replacement did not reach stable playing state')
        position = sample.get('time-pos')
        if not candidate.finite_number(position) or not 0.5 < position < 2:
            problems.append('Replacement inherited a stale seek position')
    if not resumed['frames'] < replacement['frames'] < stable['frames']:
        problems.append('Replacement did not produce new frames')
    for sample in [stopped, quiet]:
        if sample.get('idle-active') is not True or sample.get('vo-configured') is not False:
            problems.append('Stop did not retire the video output')
    if stopped['frames'] != quiet['frames']:
        problems.append('Video frames continued after stop')
    problems.extend(assess_release(released))
    return problems


def reproduces_missing_frames(samples):
    # A crash or malformed report is not evidence that the known TS defect reproduced.
    if len(samples) < 5 or [sample.get('stage') for sample in samples[:5]] != [
            'case', 'before', 'restart', 'paused-seek', 'resumed']:
        return False
    marker, before, restart, paused, resumed = samples[:5]
    if marker.get('target') != TARGETS[0] or marker.get('name') != 'sequential-0':
        return False
    states = [before, paused, resumed]
    for sample in states:
        if type(sample.get('frames')) is not int or sample['frames'] <= 0:
            return False
        if (sample.get('matchesFile') is not True or sample.get('vo-configured') is not True
                or sample.get('seeking') is not False or sample.get('eof-reached') is not False):
            return False
        if not candidate.finite_number(sample.get('time-pos')):
            return False
    return (before.get('pause') is True and paused.get('pause') is True and resumed.get('pause') is False
            and before['frames'] == paused['frames'] == resumed['frames']
            and abs(paused['time-pos'] - TARGETS[0]) <= 0.2
            and resumed['time-pos'] > paused['time-pos'] + 0.2)


def assess_opening(samples):
    if [sample.get('stage') for sample in samples] != ['opening-queued', 'released']:
        return ['Incomplete opening/shutdown measurements']
    return assess_release(samples[-1])


def run_case(output, binary, variant, label, arguments, opening=False):
    stem = output / (variant + '-' + label)
    began = time.monotonic()
    with stem.with_suffix('.log').open('w') as log:
        try:
            process = subprocess.run([str(binary), *map(str, arguments)], stdout=subprocess.PIPE,
                                     stderr=log, text=True, timeout=30)
            raw, code = process.stdout, process.returncode
        except subprocess.TimeoutExpired as error:
            raw = error.stdout or b''
            if isinstance(raw, bytes):
                raw = raw.decode('utf-8', errors='replace')
            stem.with_suffix('.jsonl').write_text(raw)
            return dict(variant=variant, case=label, passed=False,
                        problems=['Native lifecycle process exceeded 30 seconds'])
    stem.with_suffix('.jsonl').write_text(raw)
    try:
        samples = [json.loads(line) for line in raw.splitlines()]
        problems = assess_opening(samples) if opening else assess_lifecycle(samples)
    except (ValueError, TypeError, AttributeError, KeyError):
        samples, problems = [], ['Invalid lifecycle JSON protocol']
    if code:
        problems.append('Native lifecycle process exited with code ' + str(code))
    return dict(variant=variant, case=label, passed=not problems, problems=problems,
                measurements=samples, elapsedSeconds=time.monotonic() - began,
                logSHA256=sha256_file(stem.with_suffix('.log')),
                measurementsSHA256=sha256_file(stem.with_suffix('.jsonl')))


def verified_inputs(experiment):
    report = json.loads((experiment / 'report.json').read_text())
    if report.get('schemaVersion') != 1 or report.get('experimentPassed') is not True:
        raise ValueError('A completed successful isolated experiment is required')
    if report['dependencyLockSHA256'] != sha256_file(ROOT / 'Config/Dependencies.lock.json'):
        raise ValueError('The fixed runtime lock changed since the experiment')
    if report['sourceSHA256']['Tools/SeekProbe/ffmpeg-9.0.1-ts-keyframes.patch'] != sha256_file(candidate.PATCH):
        raise ValueError('Candidate source correction changed since the experiment')
    runtimes = dict(pinned=ROOT / '.build/dependencies/lib', candidate=experiment / 'candidate/runtime')
    for name, runtime in runtimes.items():
        actual = {path.name: sha256_file(path) for path in runtime.glob('*.dylib')}
        if actual != report['runtimeSHA256'][name]:
            raise ValueError('Experiment runtime changed: ' + name)
    suite = ROOT / '.build/media-suite'
    verify_manifest(suite)
    paths = dict(short=suite / '20-h264-aac.ts', long=experiment / 'media/long.ts',
                 replacement=experiment / 'media/same-payload.mp4')
    for key, case in [('short', 'short-ts'), ('long', 'long-ts'), ('replacement', 'short-mp4')]:
        identity = next(item for item in report['media']['files'] if item['case'] == case)
        if identity['license'] != 'CC0-1.0' or sha256_file(paths[key]) != identity['sha256']:
            raise ValueError('Experiment media changed: ' + key)
    return runtimes, paths


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('experiment', type=Path, help='Completed isolated seek experiment directory')
    parser.add_argument('--output', type=Path, help='New report directory')
    args = parser.parse_args()
    subprocess.run([sys.executable, str(ROOT / 'scripts/toolchain.py')], check=True)
    subprocess.run([sys.executable, str(ROOT / 'scripts/dependencies.py'), 'check'], check=True)
    experiment = args.experiment.resolve()
    runtimes, media = verified_inputs(experiment)
    output = (args.output or experiment / ('lifecycle-' + datetime.now().strftime('%Y%m%d-%H%M%S'))).resolve()
    output.mkdir(parents=True, exist_ok=False)
    report = dict(schemaVersion=1, createdAt=datetime.now(timezone.utc).isoformat(),
        experimentReportSHA256=sha256_file(experiment / 'report.json'),
        sourceSHA256={str(path.relative_to(ROOT)): sha256_file(path)
                      for path in [candidate.PROBE, Path(__file__), ROOT / 'scripts/verify-seek-candidate.py']},
        runtimeSHA256={name: {path.name: sha256_file(path) for path in runtime.glob('*.dylib')}
                      for name, runtime in runtimes.items()},
        mediaSHA256={name: sha256_file(path) for name, path in media.items()},
        promotedToApplication=False, desktopVerified=False,
        scope='Software frames and null audio; native queue ordering and teardown, not application request IDs or physical playback',
        runs=[], passed=False)
    try:
        for variant, runtime in runtimes.items():
            binary = candidate.build_probe(output, variant, runtime)
            for label, file in [('short-ts', media['short']), ('long-ts', media['long']),
                                ('mp4-control', media['replacement'])]:
                result = run_case(output, binary, variant, label,
                                  ['--lifecycle', file, media['replacement']])
                report['runs'].append(result)
                print(variant, label, 'PASS' if result['passed'] else 'FAIL', flush=True)
            for index in range(10):
                result = run_case(output, binary, variant, 'opening-' + str(index),
                                  ['--shutdown-opening', media['short']], opening=True)
                report['runs'].append(result)
            print(variant, '10 opening/shutdown runs recorded', flush=True)
        results = {(run['variant'], run['case']): run['passed'] for run in report['runs']}
        original = next(run for run in report['runs'] if run['variant'] == 'pinned' and run['case'] == 'short-ts')
        report['originalFailureReproduced'] = reproduces_missing_frames(original.get('measurements', []))
        report['passed'] = (all(run['passed'] for run in report['runs'] if run['variant'] == 'candidate')
            and results['pinned', 'mp4-control']
            and all(results['pinned', 'opening-' + str(index)] for index in range(10))
            and report['originalFailureReproduced'])
    finally:
        (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Lifecycle evidence: ' + str(output / 'report.json'), flush=True)
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
