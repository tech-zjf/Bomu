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
            'stopped': {'process': [{'cpuSeconds': 1, 'uptime': 1}, {'cpuSeconds': 1, 'uptime': 6}]},
            'shutdown': {'coreAlive': False, 'renderContextAlive': False},
        }

    def summarize(self):
        (self.directory / 'window-lifecycle.json').write_text(json.dumps(self.report))
        with patch.object(window_summary.sys, 'argv', ['summary', str(self.directory)]):
            with contextlib.redirect_stdout(io.StringIO()):
                window_summary.main()
        return (self.directory / 'summary.md').read_text()

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

    def test_legacy_report_does_not_claim_event_observation(self):
        self.report['schemaVersion'] = 2
        del self.report['soakVisibility']
        summary = self.summarize()
        self.assertIn('short occlusions between samples were not monitored', summary)


if __name__ == '__main__':
    unittest.main()
