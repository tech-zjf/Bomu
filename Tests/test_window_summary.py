"""An interrupted or unfinished visibility interval cannot become a passing summary."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('window_summary',
    Path(__file__).resolve().parents[1] / 'scripts/summarize-window-benchmark.py')
window_summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window_summary)


class WindowSummaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.report = {
            'schemaVersion': 3, 'completed': True, 'scenario': 'single-window',
            'measurement': 'test', 'requestedCycles': 0, 'screens': [], 'rounds': [], 'soak': [],
            'soakVisibility': {'startedAtSeconds': 0, 'endedAtSeconds': 10,
                               'changes': [{'elapsedSeconds': 0, 'isVisible': True}]},
            'stopped': {'process': [{'cpuSeconds': 1, 'uptime': 1, 'taskEnergyCounterRaw': 10,
                                     'gpuUtilisationCounterRaw': 4},
                                    {'cpuSeconds': 1, 'uptime': 6, 'taskEnergyCounterRaw': 25,
                                     'gpuUtilisationCounterRaw': 14}],
                        'before': {'gpuRenderTiming': {'availability': 'supported', 'mode': 'elapsed', 'sampleCount': 20,
                                                        'intervalNanoseconds': 1_000_000}},
                        'after': {'gpuRenderTiming': {'availability': 'supported', 'mode': 'elapsed', 'sampleCount': 20,
                                                       'intervalNanoseconds': 1_000_000,
                                                       'pendingQueryCount': 0, 'droppedSampleCount': 0}}},
            'shutdown': {'coreAlive': False, 'renderContextAlive': False},
        }

    def summarize(self):
        (self.directory / 'window-lifecycle.json').write_text(json.dumps(self.report))
        with patch.object(window_summary.sys, 'argv', ['summary', str(self.directory)]):
            with contextlib.redirect_stdout(io.StringIO()):
                window_summary.main()
        return (self.directory / 'summary.md').read_text()

    def add_soak_samples(self):
        timing = lambda count, average: {
            'sampleCount': count, 'averageErrorMilliseconds': average, 'earlyFrameCount': 0}
        self.report['soak'] = [
            {'positionSeconds': 0, 'displayID': 1, 'backingScale': 2,
             'process': {'uptime': 1, 'cpuSeconds': 1, 'physicalFootprintBytes': 2**20,
                         'taskEnergyCounterRaw': 100, 'gpuUtilisationCounterRaw': 40},
             'playback': {'videoFrameCount': 0, 'frameTiming': timing(0, 0),
                          'gpuRenderTiming': {'availability': 'supported', 'mode': 'elapsed', 'sampleCount': 10,
                                              'intervalNanoseconds': 2_000_000}}},
            {'positionSeconds': 10, 'displayID': 1, 'backingScale': 2,
             'process': {'uptime': 11, 'cpuSeconds': 1.5, 'physicalFootprintBytes': 2**20,
                         'taskEnergyCounterRaw': 250, 'gpuUtilisationCounterRaw': 90},
             'playback': {'videoFrameCount': 300, 'frameTiming': timing(300, 2),
                          'gpuRenderTiming': {'availability': 'supported', 'mode': 'elapsed', 'sampleCount': 310,
                                              'intervalNanoseconds': 20_000_000,
                                              'pendingQueryCount': 0, 'droppedSampleCount': 1}}},
        ]

    def test_brief_occlusion_cannot_pass_after_visibility_recovers(self):
        self.report['soakVisibility']['changes'] += [
            {'elapsedSeconds': 4, 'isVisible': False}, {'elapsedSeconds': 5, 'isVisible': True}]
        with self.assertRaisesRegex(SystemExit, 'visibility evidence'):
            self.summarize()
        self.assertFalse((self.directory / 'summary.md').exists())

    def test_unfinished_observation_cannot_pass(self):
        del self.report['soakVisibility']['endedAtSeconds']
        with self.assertRaisesRegex(SystemExit, 'visibility evidence'):
            self.summarize()

    def test_finished_observation_reports_its_measurement_limit(self):
        summary = self.summarize()
        self.assertIn('no reported occlusion', summary)
        self.assertIn('does not establish full-frame physical visibility', summary)
        self.assertIn('Stopped raw task-energy counter: 15 over 5.0 s (3.00 raw units/s)', summary)
        self.assertIn('raw GPU-utilisation counter: 10 over 5.0 s (2.00 raw units/s)', summary)
        self.assertIn('Stopped OpenGL GPU render interval: 0.000 ms across 0 completed intervals', summary)
        self.assertIn('OpenGL GPU query mode: elapsed', summary)

    def test_counter_span_preserves_unavailable_and_reset_states(self):
        samples = [{'uptime': 1, 'counter': 8}, {'uptime': 2, 'counter': None}]
        self.assertEqual(window_summary.raw_counter_span(samples, 'counter'), 'n/a')
        samples[1]['counter'] = 2
        self.assertEqual(window_summary.raw_counter_span(samples, 'counter'), 'reset')

    def test_soak_summary_reports_raw_counter_spans_without_relabeling_units(self):
        self.add_soak_samples()
        summary = self.summarize()
        self.assertIn('Raw task-energy counter: 150 over 10.0 s (15.00 raw units/s)', summary)
        self.assertIn('raw GPU-utilisation counter: 50 over 10.0 s (5.00 raw units/s)', summary)
        self.assertIn('OpenGL GPU render interval: 18.000 ms across 300 completed intervals', summary)

    def test_soak_counter_gap_or_reset_remains_explicit(self):
        self.add_soak_samples()
        self.report['soak'][1]['process']['taskEnergyCounterRaw'] = None
        self.report['soak'][1]['process']['gpuUtilisationCounterRaw'] = 2
        summary = self.summarize()
        self.assertIn('Raw task-energy counter: n/a', summary)
        self.assertIn('raw GPU-utilisation counter: reset', summary)

    def test_legacy_report_does_not_claim_event_observation(self):
        self.report['schemaVersion'] = 2
        del self.report['soakVisibility']
        summary = self.summarize()
        self.assertIn('short occlusions between samples were not monitored', summary)

    def add_native_probe(self):
        self.report['schemaVersion'] = 4
        self.report['occlusionProbe'] = {
            'completed': True, 'notificationCount': 2,
            'visibility': {'startedAtSeconds': 0, 'endedAtSeconds': 2, 'changes': [
                {'elapsedSeconds': 0, 'isVisible': True},
                {'elapsedSeconds': 0.5, 'isVisible': False},
                {'elapsedSeconds': 1.5, 'isVisible': True}]},
            'hidden': {'videoFrameCount': 20}, 'restored': {'videoFrameCount': 21},
        }

    def test_native_probe_requires_callback_and_frame_recovery(self):
        self.add_native_probe()
        self.report['occlusionProbe']['notificationCount'] = 0
        with self.assertRaisesRegex(SystemExit, 'native notifications or frame recovery'):
            self.summarize()
        self.report['occlusionProbe']['notificationCount'] = 2
        self.report['occlusionProbe']['restored']['videoFrameCount'] = 20
        with self.assertRaisesRegex(SystemExit, 'native notifications or frame recovery'):
            self.summarize()

    def test_probe_interruption_is_separate_from_uninterrupted_soak(self):
        self.add_native_probe()
        self.assertIn('new video frames resumed', self.summarize())

    def test_current_schema_is_accepted_with_native_probe_evidence(self):
        self.add_native_probe()
        self.report['schemaVersion'] = 9
        summary = self.summarize()
        self.assertIn('Completed single-window cycles', summary)
        self.assertIn('OpenGL GPU query mode: elapsed', summary)

    def test_partial_media_suite_cannot_pass(self):
        self.add_native_probe()
        self.report['scenario'] = 'media-suite'
        self.report['mediaSamples'] = []
        with self.assertRaisesRegex(SystemExit, '30 passing cases'):
            self.summarize()

    def test_media_suite_rejects_window_display_and_visibility_changes(self):
        self.add_native_probe()
        self.report['scenario'] = 'media-suite'
        self.report['mediaVisibility'] = self.report['soakVisibility']
        self.report['mediaSamples'] = [
            {'sample': {'file': str(index), 'coverage': 'test', 'expected': {'outcome': 'play'}},
             'windowNumber': 1, 'displayID': 1, 'passed': True} for index in range(30)]
        self.assertIn('Audio was muted', self.summarize())
        self.report['requestedInitialDisplayID'] = 1
        self.assertIn('Audio was muted', self.summarize())
        self.report['requestedInitialDisplayID'] = 2
        with self.assertRaisesRegex(SystemExit, 'requested initial display'):
            self.summarize()
        self.report['requestedInitialDisplayID'] = 1
        self.report['mediaSamples'][-1]['windowNumber'] = 2
        with self.assertRaisesRegex(SystemExit, 'one continuously visible window'):
            self.summarize()
        self.report['mediaSamples'][-1]['windowNumber'] = 1
        self.report['mediaVisibility']['changes'].append({'elapsedSeconds': 5, 'isVisible': False})
        self.report['mediaVisibility']['changes'].append({'elapsedSeconds': 6, 'isVisible': True})
        with self.assertRaisesRegex(SystemExit, 'visibility evidence'):
            self.summarize()


if __name__ == '__main__':
    unittest.main()
