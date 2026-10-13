#!/usr/bin/env python3
"""Report exactly which window cycles and continuous-playback intervals completed."""
import json
from pathlib import Path
import sys


def cpu_percent(start, end):
    return 100 * (end['cpuSeconds'] - start['cpuSeconds']) / (end['uptime'] - start['uptime'])


def main():
    root = Path(sys.argv[1])
    report = json.loads((root / 'window-lifecycle.json').read_text())
    if report['schemaVersion'] not in {1, 2, 3} or not report['completed']:
        raise SystemExit('Window benchmark is incomplete. Inspect its partial JSON and process.log.')
    if report['schemaVersion'] >= 3:
        visibility = report.get('soakVisibility')
        if (not visibility or visibility.get('endedAtSeconds') is None or not visibility.get('changes')
                or any(not change['isVisible'] for change in visibility['changes'])):
            raise SystemExit('Continuous playback lacks completed, uninterrupted visibility evidence.')
        visibility_description = ('Soak visibility: AppKit occlusion transitions were observed throughout the interval; '
                                  'no reported occlusion. This does not establish full-frame physical visibility.')
    else:
        visibility_description = ('Historical visibility: periodic checkpoints only; '
                                  'short occlusions between samples were not monitored.')
    # Schema 1 predates single-window mode and always denotes display transitions.
    scenario = 'display-transitions' if report['schemaVersion'] == 1 else report['scenario']
    if scenario == 'single-window':
        actions = 'Each cycle: acknowledged pause/resume through PlayerModel and a new video frame after resume. '
        actions += 'Window geometry is unchanged by the driver; no automatic fullscreen or display migration.'
    elif scenario == 'display-transitions':
        actions = 'Each cycle: resize + display migration + acknowledged pause/resume through PlayerModel '
        actions += '+ native fullscreen entry/exit + new video frame after exit.'
    else:
        raise SystemExit(f'Unknown window scenario: {scenario}')
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
