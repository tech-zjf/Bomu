"""Exercise the hitch launcher's process and configuration boundaries without Xcode/UI."""
import copy
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
LAUNCHER = ROOT / 'scripts/measure-library-hitches.sh'


def embedded_python(marker):
    # Execute the same heredoc used by bash, without sourcing the launcher's
    # top-level build/test commands. Assertions below inspect behavior, not text.
    script = LAUNCHER.read_text()
    return script.split(f"<<'{marker}'\n", 1)[1].split(f'\n{marker}', 1)[0]


def process_exists(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


@unittest.skipUnless(os.name == 'posix', 'The macOS launcher uses POSIX process groups')
class HitchProcessBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='bomu-hitch-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.wrapper = self.root / 'bounded.py'
        self.wrapper.write_text(embedded_python('BOUNDED_PY'))

    def command(self, seconds, child_code, *arguments):
        return [sys.executable, str(self.wrapper), str(seconds),
                sys.executable, '-c', child_code, *map(str, arguments)]

    def run_bounded(self, seconds, child_code, *arguments):
        return subprocess.run(self.command(seconds, child_code, *arguments),
                              capture_output=True, text=True, timeout=15)

    def await_file(self, path):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and path.read_text().strip():
                return int(path.read_text())
            time.sleep(0.02)
        self.fail('Temporary child did not publish its ready PID')

    def assert_process_ended(self, pid):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline and process_exists(pid):
            time.sleep(0.02)
        self.assertFalse(process_exists(pid), f'Owned child {pid} survived cleanup')

    def test_preserves_success_and_failure_exit_codes(self):
        for code in (0, 7):
            with self.subTest(code=code):
                result = self.run_bounded(5, f'raise SystemExit({code})')
                self.assertEqual(code, result.returncode, result.stderr)

    def test_timeout_kills_term_resistant_child_and_preserves_unrelated_process(self):
        ready = self.root / 'ready'
        sibling = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        try:
            child = '''import os, signal, sys, time
from pathlib import Path
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(30)
'''
            result = self.run_bounded(1.5, child, ready)
            self.assertEqual(124, result.returncode, result.stderr)
            self.assertIn('wall limit', result.stderr)
            self.assert_process_ended(self.await_file(ready))
            self.assertIsNone(sibling.poll(), 'Cleanup signalled an unrelated process')
        finally:
            sibling.terminate()
            sibling.wait(timeout=5)

    def test_interrupt_cleans_the_owned_child(self):
        ready = self.root / 'ready'
        child = '''import os, sys, time
from pathlib import Path
Path(sys.argv[1]).write_text(str(os.getpid()))
time.sleep(30)
'''
        wrapper = subprocess.Popen(self.command(30, child, ready),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            pid = self.await_file(ready)
            wrapper.terminate()
            _, stderr = wrapper.communicate(timeout=10)
            self.assertEqual(128 + signal.SIGTERM, wrapper.returncode, stderr)
            self.assert_process_ended(pid)
        finally:
            if wrapper.poll() is None:
                wrapper.terminate()
                wrapper.communicate(timeout=10)


class HitchLaunchConfigurationTests(unittest.TestCase):
    def check_configuration(self, configuration):
        with tempfile.TemporaryDirectory(prefix='bomu-hitch-config-') as temporary:
            path = Path(temporary) / 'run.xctestrun'
            path.write_bytes(plistlib.dumps(configuration))
            return subprocess.run([sys.executable, '-', str(path)],
                                  input=embedded_python('RUNFILE_PY'),
                                  capture_output=True, text=True, timeout=5)

    def test_accepts_only_the_observer_runner_without_target_app_launch(self):
        target = {
            'TestHostPath': '__TESTROOT__/Debug/BomuHitchUITests-Runner.app',
            'IsUITestBundle': True,
            'UseUITargetAppProvidedByTests': True,
        }
        configuration = {'BomuHitchUITests': target,
                         '__xctestrun_metadata__': {'FormatVersion': 1}}
        self.assertEqual(0, self.check_configuration(configuration).returncode)
        rejected_fields = {
            'TestHostPath': '__TESTROOT__/Debug/Bomu.app',
            'IsUITestBundle': False,
            'UseUITargetAppProvidedByTests': False,
            'UITargetAppPath': '__TESTROOT__/Debug/Bomu.app',
        }
        for field, value in rejected_fields.items():
            with self.subTest(field=field):
                invalid = copy.deepcopy(configuration)
                invalid['BomuHitchUITests'][field] = value
                self.assertNotEqual(0, self.check_configuration(invalid).returncode)
        self.assertNotEqual(0, self.check_configuration(
            {**configuration, 'OtherTests': {}}).returncode)


if __name__ == '__main__':
    unittest.main()
