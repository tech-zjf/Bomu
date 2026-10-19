#!/usr/bin/env python3
"""Report exactly which window cycles and continuous-playback intervals completed."""
import json
import math
from pathlib import Path
import sys


def cpu_percent(start, end):
    return 100 * (end['cpuSeconds'] - start['cpuSeconds']) / (end['uptime'] - start['uptime'])


def raw_counter_span(samples, key):
    values = [sample.get(key) for sample in samples]
    if len(values) < 2 or any(value is None for value in values):
        return 'n/a'
    if any(current < previous for previous, current in zip(values, values[1:])):
        return 'reset'
    elapsed = samples[-1]['uptime'] - samples[0]['uptime']
    if elapsed <= 0:
        return 'n/a'
    delta = values[-1] - values[0]
    return f'{delta} over {elapsed:.1f} s ({delta / elapsed:.2f} raw units/s)'


def gpu_render_interval_span(before, after):
    start = before.get('gpuRenderTiming')
    end = after.get('gpuRenderTiming')
    if not end:
        return 'missing'
    availability = end.get('availability')
    if availability is None:
        availability = 'supported' if end.get('supported') else 'unsupported or unavailable'
    if availability != 'supported':
        return availability.replace('-', ' ')
    start_availability = start.get('availability') if start else None
    if start_availability is None and start:
        start_availability = 'supported' if start.get('supported') else 'unsupported or unavailable'
    if not start or start_availability != 'supported':
        return 'missing baseline'
    start_samples = start.get('sampleCount')
    end_samples = end.get('sampleCount')
    start_interval = start.get('intervalNanoseconds')
    end_interval = end.get('intervalNanoseconds')
    if not all(isinstance(value, (int, float)) for value in
               (start_samples, end_samples, start_interval, end_interval)):
        return 'incomplete'
    if end_samples < start_samples or end_interval < start_interval:
        return 'counter reset'
    pending = end.get('pendingQueryCount')
    dropped = end.get('droppedSampleCount')
    return (f'{(end_interval - start_interval) / 1_000_000:.3f} ms across '
            f'{end_samples - start_samples} completed intervals; '
            f'{pending if isinstance(pending, int) else "n/a"} pending / '
            f'{dropped if isinstance(dropped, int) else "n/a"} dropped')


def uninterrupted(visibility):
    return (visibility and visibility.get('endedAtSeconds') is not None and visibility.get('changes')
            and all(change['isVisible'] for change in visibility['changes']))


def validate_b11(report):
    samples = report['mediaSamples']
    if any(sample['sample']['expected'].get('outcome') != 'play'
           or not sample['sample']['expected'].get('video')
           or not sample['sample']['expected'].get('audio') for sample in samples):
        raise SystemExit('B11 requires 60 audiovisual cases, not rejection or audio-only cases.')
    switches = report.get('fileSwitches', [])
    rounds = report['rounds']
    if (report['requestedCycles'] != 100 or len(switches) != 100 or len(rounds) != 100
            or [row.get('cycle') for row in rounds] != list(range(1, 101))):
        raise SystemExit('B11 requires 100 completed file switches and pause/resume cycles.')
    request_ids = [row.get('requestID') for row in switches]
    if (any(not isinstance(value, int) or isinstance(value, bool) or value <= 0 for value in request_ids)
            or len(set(request_ids)) != 100):
        raise SystemExit('B11 file switches must identify 100 distinct playback requests.')
    for index, row in enumerate(switches):
        if row.get('index') != index + 1 or row.get('file') != samples[index % 60]['sample']['file']:
            raise SystemExit('B11 file-switch order differs from its media matrix.')
    soak = report['soak']
    if len(soak) < 2:
        raise SystemExit('B11 requires a measured 1,800-second playback interval.')
    requested = report.get('requestedSoakSeconds', 0)
    elapsed = soak[-1]['process']['uptime'] - soak[0]['process']['uptime']
    advance = soak[-1]['positionSeconds'] - soak[0]['positionSeconds']
    visibility = report['soakVisibility']
    observed = visibility['endedAtSeconds'] - visibility['startedAtSeconds']
    if (not all(isinstance(value, (int, float)) and math.isfinite(value)
                for value in (requested, elapsed, advance, observed))
            or requested < 1800 or elapsed < 1800 or observed < 1800 or advance < 1798):
        raise SystemExit('B11 requires a measured 1,800-second playback interval with advancing media time.')
    if any(report['shutdown'].get(key) is not False
           for key in ('coreAlive', 'renderContextAlive', 'graphicsContextAlive')):
        raise SystemExit('B11 native resources were not confirmed released.')


def main():
    root = Path(sys.argv[1])
    report = json.loads((root / 'window-lifecycle.json').read_text())
    if report['schemaVersion'] not in {1, 2, 3, 4, 5, 6, 7, 8, 9} or not report['completed']:
        raise SystemExit('Window benchmark is incomplete. Inspect its partial JSON and process.log.')
    if report['schemaVersion'] >= 3:
        visibility = report.get('soakVisibility')
        if not uninterrupted(visibility):
            raise SystemExit('Continuous playback lacks completed, uninterrupted visibility evidence.')
        visibility_description = ('Soak visibility: AppKit occlusion transitions were observed throughout the interval; '
                                  'no reported occlusion. This does not establish full-frame physical visibility.')
    else:
        visibility_description = ('Historical visibility: periodic checkpoints only; '
                                  'short occlusions between samples were not monitored.')
    # Schema 1 predates single-window mode and always denotes display transitions.
    scenario = 'display-transitions' if report['schemaVersion'] == 1 else report['scenario']
    measurement = report['measurement']
    if report.get('minimizeRestoreProbeSkippedReason'):
        measurement = measurement.replace('one minimize/restore probe, then',
            'minimize/restore probe skipped for this run, then')
    if scenario in {'single-window', 'media-suite', 'b11-suite'}:
        actions = 'Each cycle: acknowledged pause/resume through PlayerModel and a new video frame after resume. '
        actions += 'Window geometry is unchanged by the driver; no automatic fullscreen or display migration.'
    elif scenario == 'display-transitions':
        actions = 'Each cycle: resize + display migration + acknowledged pause/resume through PlayerModel '
        actions += '+ native fullscreen entry/exit + new video frame after exit.'
    else:
        raise SystemExit(f'Unknown window scenario: {scenario}')
    requested_display = report.get('requestedInitialDisplayID')
    if scenario in {'single-window', 'media-suite', 'b11-suite'} and requested_display is not None:
        checkpoints = [row['checkpoint'] for row in report['rounds']] + report['soak']
        observed_displays = {item['displayID'] for item in checkpoints + report.get('mediaSamples', [])}
        if observed_displays != {requested_display}:
            raise SystemExit('The stationary benchmark did not remain on its requested initial display.')
    if report['schemaVersion'] >= 4:
        probe = report.get('occlusionProbe') or {}
        if report.get('minimizeRestoreProbeSkippedReason'):
            if probe:
                raise SystemExit('A skipped minimize/restore probe must not also contain probe results.')
            actions += ' Minimize/restore probe skipped: ' + report['minimizeRestoreProbeSkippedReason']
        else:
            visibility = probe.get('visibility') or {}
            changes = visibility.get('changes', [])
            if (not probe.get('completed') or probe.get('notificationCount', 0) < 2
                    or visibility.get('endedAtSeconds') is None or not changes
                    or not changes[0]['isVisible'] or not changes[-1]['isVisible']
                    or all(change['isVisible'] for change in changes)
                    or probe.get('restored', {}).get('videoFrameCount', 0) <= probe.get('hidden', {}).get('videoFrameCount', 0)):
                raise SystemExit('The minimize/restore probe lacks native notifications or frame recovery.')
            actions += ' The same window was then minimized/restored once; native callbacks retained the hidden interval and new video frames resumed.'
    if scenario in {'media-suite', 'b11-suite'}:
        expected_count = 60 if scenario == 'b11-suite' else 30
        samples = report.get('mediaSamples', [])
        if (len(samples) != expected_count or any(not item['passed'] for item in samples)
                or len({item['sample']['file'] for item in samples}) != expected_count
                or len({item['windowNumber'] for item in samples}) != 1
                or len({item['displayID'] for item in samples}) != 1
                or not uninterrupted(report.get('mediaVisibility'))):
            raise SystemExit(f'The media suite lacks {expected_count} passing cases in one continuously visible window.')
    if scenario == 'b11-suite':
        validate_b11(report)
    rounds, soak = report['rounds'], report['soak']
    lines = ['# Window lifecycle benchmark', '', measurement, '',
             f'Completed {scenario} cycles: {len(rounds)}/{report["requestedCycles"]}.', actions,
             visibility_description, '',
             '| Display | Built in | Points | Backing scale | Maximum fps |',
             '| --- | --- | --- | ---: | ---: |']
    for screen in report['screens']:
        lines.append(f'| {screen["name"]} | {screen["isBuiltIn"]} | '
                     f'{screen["widthPoints"]:g} × {screen["heightPoints"]:g} | '
                     f'{screen["backingScale"]:g} | {screen["maximumFramesPerSecond"]} |')
    if scenario in {'media-suite', 'b11-suite'}:
        lines += ['', '| Media | Coverage | Expected / observed |', '| --- | --- | --- |']
        for item in report['mediaSamples']:
            sample = item['sample']
            lines.append(f'| {sample["file"]} | {sample["coverage"]} | {sample["expected"]["outcome"]} / passed |')
        lines += ['', 'Audio was muted: decoded sample rate, channel count and active audio output were checked; '
                  'this does not verify listening quality. Media properties were checked against the decoded/probed fixture manifest.']
    if scenario == 'b11-suite':
        sleep_wake = report.get('systemSleepWake') or {}
        lines += ['', 'Completed file switches: 100/100, with distinct requests in matrix order.',
                  'The 30-minute interval uses a source-aligned flash/pulse fixture; '
                  'physical speaker/display synchronization remains unverified.',
                  f'System sleep/wake notifications: {sleep_wake.get("sleepNotifications", "not recorded")} / '
                  f'{sleep_wake.get("wakeNotifications", "not recorded")}. '
                  'Notification counts do not prove post-wake audio/video recovery. '
                  'Dedicated sleep/wake recovery acceptance remains open.']
    lines += ['', '| Cycle | Elapsed s | Display ID | Backing scale | Footprint MiB | Frames | Core / render creations |',
              '| ---: | ---: | ---: | ---: | ---: | ---: | --- |']
    for row in rounds:
        if row['cycle'] % 10 and row != rounds[-1]:
            continue
        item = row['checkpoint']
        native = item['playback']
        lines.append(f'| {row["cycle"]} | {item["elapsedSeconds"]:.1f} | {item["displayID"]} | '
                     f'{item["backingScale"]:g} | {item["process"]["physicalFootprintBytes"] / 2**20:.1f} | '
                     f'{native["videoFrameCount"]} | {native["coreCreationCount"]} / {native["renderContextCreationCount"]} |')
    if len(soak) > 1:
        start, end = soak[0], soak[-1]
        elapsed = end['process']['uptime'] - start['process']['uptime']
        frames = end['playback']['videoFrameCount'] - start['playback']['videoFrameCount']
        positions = end['positionSeconds'] - start['positionSeconds']
        footprints = [item['process']['physicalFootprintBytes'] / 2**20 for item in soak]
        before, after = start['playback']['frameTiming'], end['playback']['frameTiming']
        count = after['sampleCount'] - before['sampleCount']
        total = (after['averageErrorMilliseconds'] * after['sampleCount']
                 - before['averageErrorMilliseconds'] * before['sampleCount'])
        early = after['earlyFrameCount'] - before['earlyFrameCount']
        lines += ['', f'Continuous playback: {elapsed:.1f} s, position advanced {positions:.1f} s, '
                  f'{frames} new submitted frames ({frames / elapsed:.2f}/s).',
                  f'CPU: {cpu_percent(start["process"], end["process"]):.2f}% (100% = one logical core).',
                  f'OpenGL GPU render interval: {gpu_render_interval_span(start["playback"], end["playback"])}.',
                  f'OpenGL GPU query mode: {end["playback"].get("gpuRenderTiming", {}).get("mode", "unknown")}.',
                  f'Raw task-energy counter: {raw_counter_span([item["process"] for item in soak], "taskEnergyCounterRaw")}; '
                  f'raw GPU-utilisation counter: {raw_counter_span([item["process"] for item in soak], "gpuUtilisationCounterRaw")}.',
                  f'Footprint: {footprints[0]:.1f} → {footprints[-1]:.1f} MiB; '
                  f'observed range {min(footprints):.1f}–{max(footprints):.1f} MiB.',
                  f'Mean frame-submission error: {total / count:.3f} ms; '
                  f'frames more than 2 ms early: {early}.']
    stopped = report['stopped']
    lines += ['', f'Stopped CPU: {cpu_percent(stopped["process"][0], stopped["process"][-1]):.2f}%; '
              'new frames, draws and snapshots: 0.',
              f'Stopped raw task-energy counter: {raw_counter_span(stopped["process"], "taskEnergyCounterRaw")}; '
              f'raw GPU-utilisation counter: {raw_counter_span(stopped["process"], "gpuUtilisationCounterRaw")}.',
              f'Stopped OpenGL GPU render interval: {gpu_render_interval_span(stopped.get("before", {}), stopped.get("after", {}))}.',
              f'OpenGL GPU query mode: {stopped.get("after", {}).get("gpuRenderTiming", {}).get("mode", "unknown")}.',
              f'After shutdown: coreAlive={report["shutdown"]["coreAlive"]}, '
              f'renderContextAlive={report["shutdown"]["renderContextAlive"]}.', '',
              'Pause/resume exercises the production overlay; screenshots and manual interaction remain separate '
              'from the per-cycle native assertions. This is not physical A/V synchronization, calibrated color, '
              'GPU power, live-drag input or an hours-long leak test.', '']
    summary = '\n'.join(lines)
    (root / 'summary.md').write_text(summary)
    print(summary)


if __name__ == '__main__':
    main()
