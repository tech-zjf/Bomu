"""Raw optional power counters must remain explicit in playback summaries."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('playback_summary',
    Path(__file__).resolve().parents[1] / 'scripts/summarize-benchmark.py')
playback_summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(playback_summary)


class PlaybackSummaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.report = {
            'schemaVersion': 9, 'completed': True, 'measurement': 'test',
            'firstFrames': [
                {'sample': 'h264', 'milliseconds': 12, 'decoder': 'VideoToolbox',
                 'taskEnergyCounterDelta': 20, 'gpuUtilisationCounterDelta': 8},
                {'sample': 'h264', 'milliseconds': 10, 'decoder': 'VideoToolbox',
                 'taskEnergyCounterDelta': 40, 'gpuUtilisationCounterDelta': 12},
            ],
            'activity': [{
                'phase': 'playing-1080p',
                'process': [
                    {'uptime': 1, 'cpuSeconds': 1, 'physicalFootprintBytes': 2**20,
                     'windowVisible': True, 'taskEnergyCounterRaw': 100,
                     'gpuUtilisationCounterRaw': 50},
                    {'uptime': 3, 'cpuSeconds': 1.2, 'physicalFootprintBytes': 2**20,
                     'windowVisible': True, 'taskEnergyCounterRaw': 180,
                     'gpuUtilisationCounterRaw': 90},
                ],
                'before': {'videoFrameCount': 0, 'drawCount': 0, 'snapshotCount': 0,
                           'frameTiming': {'sampleCount': 0, 'averageErrorMilliseconds': 0,
                                           'earlyFrameCount': 0},
                           'gpuRenderTiming': {'availability': 'supported', 'mode': 'elapsed', 'sampleCount': 10,
                                               'intervalNanoseconds': 1_000_000,
                                               'pendingQueryCount': 0, 'droppedSampleCount': 2}},
                'after': {'videoFrameCount': 60, 'drawCount': 60, 'snapshotCount': 20,
                          'frameTiming': {'sampleCount': 60, 'averageErrorMilliseconds': 1,
                                          'earlyFrameCount': 0},
                          'gpuRenderTiming': {'availability': 'supported', 'mode': 'elapsed', 'sampleCount': 50,
                                              'intervalNanoseconds': 4_000_000,
                                              'pendingQueryCount': 0, 'droppedSampleCount': 2}},
            }],
            'switches': [], 'completedResizes': 0,
        }

    def summarize(self):
        (self.directory / 'playback-baseline.json').write_text(json.dumps(self.report))
        with patch.object(playback_summary.sys, 'argv', ['summary', str(self.directory)]):
            with contextlib.redirect_stdout(io.StringIO()):
                playback_summary.main()
        return (self.directory / 'summary.md').read_text()

    def test_reports_same_host_raw_counter_deltas(self):
        summary = self.summarize()
        self.assertIn('| h264 | 2 | 11.0 | 12.0 | 30 median (2/2) | 10 median (2/2) | VideoToolbox |', summary)
        self.assertIn('| playing-1080p | 10.00 | 1.0 | 80 | 40 | 60 | 60 | 20 | 2/2 |', summary)
        self.assertIn('| playing-1080p | supported | elapsed | 3.000 | 40 | 0 / 2 |', summary)
        self.assertIn('not watts or joules', summary)

    def test_unsupported_gpu_timing_is_not_reported_as_zero(self):
        for phase in self.report['activity']:
            phase['before']['gpuRenderTiming']['availability'] = 'extension-unavailable'
            phase['after']['gpuRenderTiming']['availability'] = 'extension-unavailable'
        summary = self.summarize()
        self.assertIn('| playing-1080p | extension unavailable | elapsed | n/a | n/a | n/a |', summary)

    def test_missing_counters_remain_unavailable(self):
        for row in self.report['firstFrames']:
            row.pop('taskEnergyCounterDelta')
            row.pop('gpuUtilisationCounterDelta')
        for row in self.report['activity'][0]['process']:
            row.pop('taskEnergyCounterRaw')
            row.pop('gpuUtilisationCounterRaw')
        summary = self.summarize()
        self.assertIn('| h264 | 2 | 11.0 | 12.0 | n/a (0/2) | n/a (0/2) | VideoToolbox |', summary)
        self.assertIn('| playing-1080p | 10.00 | 1.0 | n/a (0/2) | n/a (0/2) |', summary)

    def test_partial_counter_samples_are_not_reported_as_a_contiguous_span(self):
        rows = self.report['activity'][0]['process']
        rows[1]['taskEnergyCounterRaw'] = None
        summary = self.summarize()
        self.assertIn('n/a (1/2) | 40 |', summary)
        self.assertIn('30 median (2/2)', summary)

    def test_counter_reset_is_not_reported_as_negative_energy_or_utilisation(self):
        samples = self.report['activity'][0]['process']
        samples.insert(1, {
            'uptime': 2, 'cpuSeconds': 1.1, 'physicalFootprintBytes': 2**20,
            'windowVisible': True, 'taskEnergyCounterRaw': 10,
            'gpuUtilisationCounterRaw': 2,
        })
        summary = self.summarize()
        self.assertIn('| playing-1080p | 10.00 | 1.0 | reset | reset |', summary)

    def test_replacement_footprint_reports_endpoint_medians_and_range_without_a_verdict(self):
        self.report['switches'] = [
            {'completed': index * 10,
             'process': {'physicalFootprintBytes': (100 + index * 10) * 2**20}}
            for index in range(1, 11)
        ]
        summary = self.summarize()
        self.assertIn('Replacement footprint trend: 10/10 checkpoints; range 110.0–200.0 MiB; '
                      'first/last checkpoint-window median 120.0 → 190.0 MiB (+70.0 MiB).', summary)
        self.assertIn('short-run trend indicator, not a leak verdict', summary)

    def test_missing_replacement_footprint_remains_unavailable(self):
        self.report['switches'] = [{'completed': 10, 'process': {'physicalFootprintBytes': None}}]
        summary = self.summarize()
        self.assertIn('Replacement footprint trend: n/a (0/1 checkpoints).', summary)

    def test_rejects_old_or_unknown_schema(self):
        self.report['schemaVersion'] = 6
        with self.assertRaisesRegex(SystemExit, 'Unsupported measurement schema'):
            self.summarize()


if __name__ == '__main__':
    unittest.main()
