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
    if report['schemaVersion'] != 9:
        raise SystemExit('Unsupported measurement schema. Run the current benchmark script.')
    if not report['completed']:
        raise SystemExit('Benchmark did not finish. Inspect process.log and the partial JSON.')
    lines = ['# Playback benchmark', '', report['measurement'], '',
             '| Sample | Runs | Median ms | P95 ms | Task-energy raw Δ | GPU-utilisation raw Δ | Decoder |',
             '| --- | ---: | ---: | ---: | ---: | ---: | --- |']
    for sample in sorted({row['sample'] for row in report['firstFrames']}):
        rows = [row for row in report['firstFrames'] if row['sample'] == sample]
        values = sorted(row['milliseconds'] for row in rows)
        decoders = ', '.join(sorted({row.get('decoder', 'unavailable') for row in rows}))
        energy = counter_summary(rows, 'taskEnergyCounterDelta')
        gpu = counter_summary(rows, 'gpuUtilisationCounterDelta')
        lines.append(f'| {sample} | {len(values)} | {statistics.median(values):.1f} | '
                     f'{values[math.ceil(len(values) * 0.95) - 1]:.1f} | {energy} | {gpu} | {decoders} |')
    lines += ['', 'CPU is process CPU time / elapsed time; 100% equals one logical core.', '',
              '| Phase | CPU % | Footprint end MiB | Task-energy raw span | GPU-utilisation raw span | New video frames | Draws | Snapshots | Visible samples |',
              '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |']
    for phase in report['activity']:
        start, end = phase['process'][0], phase['process'][-1]
        cpu = 100 * (end['cpuSeconds'] - start['cpuSeconds']) / (end['uptime'] - start['uptime'])
        before, after = phase['before'], phase['after']
        changes = [after[key] - before[key] for key in ('videoFrameCount', 'drawCount', 'snapshotCount')]
        visible = sum(row['windowVisible'] for row in phase['process'])
        energy = counter_series_summary(phase['process'], 'taskEnergyCounterRaw')
        gpu = counter_series_summary(phase['process'], 'gpuUtilisationCounterRaw')
        lines.append(f'| {phase["phase"]} | {cpu:.2f} | {end["physicalFootprintBytes"] / 2**20:.1f} | '
                     f'{energy} | {gpu} | {changes[0]} | {changes[1]} | {changes[2]} | '
                     f'{visible}/{len(phase["process"])} |')
    lines += ['', '| Phase | OpenGL GPU timing | Query mode | Interval Δ ms | Completed samples | Pending / dropped at end |',
              '| --- | --- | --- | ---: | ---: | --- |']
    for phase in report['activity']:
        label, interval, samples, pending = gpu_render_summary(phase['before'], phase['after'])
        mode = phase['after'].get('gpuRenderTiming', {}).get('mode', 'unknown')
        lines.append(f'| {phase["phase"]} | {label} | {mode} | {interval} | {samples} | {pending} |')
    lines += ['', '| Completed switches | Footprint MiB |', '| ---: | ---: |']
    for row in report['switches']:
        footprint = row.get('process', {}).get('physicalFootprintBytes')
        footprint_text = f'{footprint / 2**20:.1f}' if isinstance(footprint, (int, float)) else 'n/a'
        lines.append(f'| {row["completed"]} | {footprint_text} |')
    lines += ['', replacement_footprint_summary(report['switches']),
              'Replacement footprint checkpoints are a short-run trend indicator, not a leak verdict.', '']
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
              'Task energy and GPU utilisation values are raw OS counters with undocumented units; they are comparable only as same-host deltas. '
              'They are not watts or joules, do not isolate the entire GPU, and do not prove physical first-pixel, first-audio, or long-run power.',
              'OpenGL GPU timing measures the GPU execution interval around mpv render calls using the reported query mode. It excludes VideoToolbox decoding, other GPU clients, and display scanout; unsupported or missing measurements remain unavailable.', '']
    (root / 'summary.md').write_text('\n'.join(lines))
    print('\n'.join(lines))


def counter_summary(rows, key):
    values = [row.get(key) for row in rows if row.get(key) is not None]
    if not values:
        return f'n/a (0/{len(rows)})'
    return f'{statistics.median(values):.0f} median ({len(values)}/{len(rows)})'


def counter_series_summary(rows, key):
    values = [row.get(key) for row in rows]
    available = sum(value is not None for value in values)
    if available != len(values) or len(values) < 2:
        return f'n/a ({available}/{len(values)})'
    if any(end < start for start, end in zip(values, values[1:])):
        return 'reset'
    return str(values[-1] - values[0])


def gpu_render_summary(before, after):
    start = before.get('gpuRenderTiming')
    end = after.get('gpuRenderTiming')
    if not end:
        return 'missing', 'n/a', 'n/a', 'n/a'
    availability = end.get('availability')
    if availability is None:
        availability = 'supported' if end.get('supported') else 'unsupported or unavailable'
    if availability != 'supported':
        return availability.replace('-', ' '), 'n/a', 'n/a', 'n/a'
    start_availability = start.get('availability') if start else None
    if start_availability is None and start:
        start_availability = 'supported' if start.get('supported') else 'unsupported or unavailable'
    if not start or start_availability != 'supported':
        return 'missing baseline', 'n/a', 'n/a', 'n/a'
    start_samples = start.get('sampleCount')
    end_samples = end.get('sampleCount')
    start_interval = start.get('intervalNanoseconds')
    end_interval = end.get('intervalNanoseconds')
    if not all(isinstance(value, (int, float)) for value in
               (start_samples, end_samples, start_interval, end_interval)):
        return 'incomplete', 'n/a', 'n/a', 'n/a'
    if end_samples < start_samples or end_interval < start_interval:
        return 'counter reset', 'reset', 'reset', 'n/a'
    pending = end.get('pendingQueryCount')
    dropped = end.get('droppedSampleCount')
    pending_text = f'{pending} / {dropped}' if isinstance(pending, int) and isinstance(dropped, int) else 'n/a'
    return ('supported', f'{(end_interval - start_interval) / 1_000_000:.3f}',
            str(end_samples - start_samples), pending_text)


def replacement_footprint_summary(switches):
    raw_values = [row.get('process', {}).get('physicalFootprintBytes') for row in switches]
    valid = lambda value: isinstance(value, (int, float)) and value >= 0
    values = [value / 2**20 for value in raw_values if valid(value)]
    if not values:
        return f'Replacement footprint trend: n/a (0/{len(switches)} checkpoints).'
    window_size = max(1, len(raw_values) // 3)
    first_window = [value / 2**20 for value in raw_values[:window_size] if valid(value)]
    last_window = [value / 2**20 for value in raw_values[-window_size:] if valid(value)]
    if not first_window or not last_window:
        return (f'Replacement footprint trend: incomplete ({len(values)}/{len(switches)} checkpoints); '
                'first/last checkpoint-window median n/a.')
    first = statistics.median(first_window)
    last = statistics.median(last_window)
    change = last - first
    return (f'Replacement footprint trend: {len(values)}/{len(switches)} checkpoints; '
            f'range {min(values):.1f}–{max(values):.1f} MiB; '
            f'first/last checkpoint-window median {first:.1f} → {last:.1f} MiB '
            f'({change:+.1f} MiB).')


if __name__ == '__main__':
    main()
