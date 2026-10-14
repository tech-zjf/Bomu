#!/usr/bin/env python3
"""Report exactly which window cycles and continuous-playback intervals completed."""
import json
from pathlib import Path
import sys


def cpu_percent(start, end):
    return 100 * (end['cpuSeconds'] - start['cpuSeconds']) / (end['uptime'] - start['uptime'])


def uninterrupted(visibility):
    return (visibility and visibility.get('endedAtSeconds') is not None and visibility.get('changes')
            and all(change['isVisible'] for change in visibility['changes']))


def main():
    root = Path(sys.argv[1])
    report = json.loads((root / 'window-lifecycle.json').read_text())
    if report['schemaVersion'] not in {1, 2, 3, 4} or not report['completed']:
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
    if scenario in {'single-window', 'media-suite'}:
        actions = 'Each cycle: acknowledged pause/resume through PlayerModel and a new video frame after resume. '
        actions += 'Window geometry is unchanged by the driver; no automatic fullscreen or display migration.'
    elif scenario == 'display-transitions':
        actions = 'Each cycle: resize + display migration + acknowledged pause/resume through PlayerModel '
        actions += '+ native fullscreen entry/exit + new video frame after exit.'
    else:
        raise SystemExit(f'Unknown window scenario: {scenario}')
    requested_display = report.get('requestedInitialDisplayID')
    if scenario in {'single-window', 'media-suite'} and requested_display is not None:
        checkpoints = [row['checkpoint'] for row in report['rounds']] + report['soak']
        observed_displays = {item['displayID'] for item in checkpoints + report.get('mediaSamples', [])}
        if observed_displays != {requested_display}:
            raise SystemExit('The stationary benchmark did not remain on its requested initial display.')
    if report['schemaVersion'] >= 4:
        probe = report.get('occlusionProbe') or {}
        visibility = probe.get('visibility') or {}
        changes = visibility.get('changes', [])
        if (not probe.get('completed') or probe.get('notificationCount', 0) < 2
                or visibility.get('endedAtSeconds') is None or not changes
                or not changes[0]['isVisible'] or not changes[-1]['isVisible']
                or all(change['isVisible'] for change in changes)
                or probe.get('restored', {}).get('videoFrameCount', 0) <= probe.get('hidden', {}).get('videoFrameCount', 0)):
            raise SystemExit('The minimize/restore probe lacks native notifications or frame recovery.')
        actions += ' The same window was then minimized/restored once; native callbacks retained the hidden interval and new video frames resumed.'
    if scenario == 'media-suite':
        samples = report.get('mediaSamples', [])
        if (len(samples) != 30 or any(not item['passed'] for item in samples)
                or len({item['sample']['file'] for item in samples}) != 30
                or len({item['windowNumber'] for item in samples}) != 1
                or len({item['displayID'] for item in samples}) != 1
                or not uninterrupted(report.get('mediaVisibility'))):
            raise SystemExit('The media suite lacks 30 passing cases in one continuously visible window.')
    rounds, soak = report['rounds'], report['soak']
    lines = ['# Window lifecycle benchmark', '', report['measurement'], '',
             f'Completed {scenario} cycles: {len(rounds)}/{report["requestedCycles"]}.', actions,
             visibility_description, '',
             '| Display | Built in | Points | Backing scale | Maximum fps |',
             '| --- | --- | --- | ---: | ---: |']
    for screen in report['screens']:
        lines.append(f'| {screen["name"]} | {screen["isBuiltIn"]} | '
                     f'{screen["widthPoints"]:g} × {screen["heightPoints"]:g} | '
                     f'{screen["backingScale"]:g} | {screen["maximumFramesPerSecond"]} |')
    if scenario == 'media-suite':
        lines += ['', '| Media | Coverage | Expected / observed |', '| --- | --- | --- |']
        for item in report['mediaSamples']:
            sample = item['sample']
            lines.append(f'| {sample["file"]} | {sample["coverage"]} | {sample["expected"]["outcome"]} / passed |')
        lines += ['', 'Audio was muted: decoded sample rate, channel count and active audio output were checked; '
                  'this does not verify listening quality. Media properties were checked against the decoded/probed fixture manifest.']
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
                  f'Footprint: {footprints[0]:.1f} → {footprints[-1]:.1f} MiB; '
                  f'observed range {min(footprints):.1f}–{max(footprints):.1f} MiB.',
                  f'Mean frame-submission error: {total / count:.3f} ms; '
                  f'frames more than 2 ms early: {early}.']
    stopped = report['stopped']
    lines += ['', f'Stopped CPU: {cpu_percent(stopped["process"][0], stopped["process"][-1]):.2f}%; '
              'new frames, draws and snapshots: 0.',
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
