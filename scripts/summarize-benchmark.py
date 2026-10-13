#!/usr/bin/env python3
"""Summarize explicit playback measurements without treating missing evidence as zero."""
import json
import math
from pathlib import Path
import statistics
import sys


def main():
    root = Path(sys.argv[1])
    report = json.loads((root / 'playback-baseline.json').read_text())
    if report['schemaVersion'] != 6:
        raise SystemExit('Unsupported measurement schema. Run the current benchmark script.')
    if not report['completed']:
        raise SystemExit('Benchmark did not finish. Inspect process.log and the partial JSON.')
    lines = ['# Playback benchmark', '', report['measurement'], '',
             '| Sample | Runs | Median ms | P95 ms | Decoder |', '| --- | ---: | ---: | ---: | --- |']
    for sample in sorted({row['sample'] for row in report['firstFrames']}):
        rows = [row for row in report['firstFrames'] if row['sample'] == sample]
        values = sorted(row['milliseconds'] for row in rows)
        decoders = ', '.join(sorted({row.get('decoder', 'unavailable') for row in rows}))
        lines.append(f'| {sample} | {len(values)} | {statistics.median(values):.1f} | '
                     f'{values[math.ceil(len(values) * 0.95) - 1]:.1f} | {decoders} |')
    lines += ['', 'CPU is process CPU time / elapsed time; 100% equals one logical core.', '',
              '| Phase | CPU % | Footprint end MiB | New video frames | Draws | Snapshots | Visible samples |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: |']
    for phase in report['activity']:
        start, end = phase['process'][0], phase['process'][-1]
        cpu = 100 * (end['cpuSeconds'] - start['cpuSeconds']) / (end['uptime'] - start['uptime'])
        before, after = phase['before'], phase['after']
        changes = [after[key] - before[key] for key in ('videoFrameCount', 'drawCount', 'snapshotCount')]
        visible = sum(row['windowVisible'] for row in phase['process'])
        lines.append(f'| {phase["phase"]} | {cpu:.2f} | {end["physicalFootprintBytes"] / 2**20:.1f} | '
                     f'{changes[0]} | {changes[1]} | {changes[2]} | {visible}/{len(phase["process"])} |')
    lines += ['', '| Completed switches | Footprint MiB |', '| ---: | ---: |']
    for row in report['switches']:
        lines.append(f'| {row["completed"]} | {row["process"]["physicalFootprintBytes"] / 2**20:.1f} |')
    lines += ['', 'Frame submission minus the mpv target time; not screen/speaker latency.', '',
              '| Phase | Timed frames | Mean error ms | Frames more than 2 ms early |',
              '| --- | ---: | ---: | ---: |']
    for phase in report['activity']:
        if phase['phase'] not in {'playing-1080p', 'sync-fixture-60fps'}:
            continue
        before, after = phase['before'].get('frameTiming'), phase['after'].get('frameTiming')
        if not after:
            raise SystemExit('Missing frame timing evidence')
        count = after['sampleCount'] - (before['sampleCount'] if before else 0)
        total = after['averageErrorMilliseconds'] * after['sampleCount']
        if before:
            total -= before['averageErrorMilliseconds'] * before['sampleCount']
        early = after['earlyFrameCount'] - (before['earlyFrameCount'] if before else 0)
        lines.append(f'| {phase["phase"]} | {count} | {total / count:.3f} | {early} |')
    lines += ['', f'Completed separate resize operations: {report["completedResizes"]}.', '',
              'Partly occluded playback is not a continuously visible playback CPU baseline.', '',
              'GPU power, physical first-pixel latency, first audible sample and long-run leakage are not measured.', '']
    (root / 'summary.md').write_text('\n'.join(lines))
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
