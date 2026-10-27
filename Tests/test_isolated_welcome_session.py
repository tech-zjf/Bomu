"""Exercise launch/cleanup boundaries without opening an application or user database."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/isolated-welcome-session.sh'


class IsolatedWelcomeSessionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.sessions = self.root / 'sessions'
        self.sessions.mkdir()
        scripts = self.root / 'scripts'
        scripts.mkdir()
        self.script = scripts / SCRIPT.name
        shutil.copyfile(SCRIPT, self.script)
        self.env = dict(os.environ, PATH=f'{self.bin}:/usr/bin:/bin',
                        SESSION_ROOT=str(self.sessions), TEST_ROOT=str(self.root))
        self.env.pop('BOMU_ACCEPTANCE_LIBRARY_DIRECTORY', None)
        self.stub('python3', 'exit 0')
        self.stub('pgrep', '[ -f "$TEST_ROOT/running" ] && exit 0\nexit 1')
        self.stub('launchctl', 'exit 0')
        self.stub('ioreg', '''printf '%s\\n' '"IOConsoleLocked" = No' ''')
        self.stub('getconf', 'printf "%s\\n" "$SESSION_ROOT"')
        self.stub('open', 'printf "%s\\n" "$@" > "$TEST_ROOT/open-args"')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o755)

    def run_session(self):
        return subprocess.run(['/bin/bash', str(self.script)], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_launch_is_scoped_and_normal_exit_cleans_only_session(self):
        existing = self.sessions / 'unrelated'
        existing.mkdir()
        result = self.run_session()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / 'open-args').read_text().splitlines()
        self.assertEqual(args[:4], ['-n', '-W', '--env',
                         next(arg for arg in args if arg.startswith('BOMU_ACCEPTANCE_LIBRARY_DIRECTORY='))])
        session = Path(args[3].split('=', 1)[1])
        self.assertEqual(session.parent, self.sessions)
        self.assertFalse(session.exists())
        self.assertTrue(existing.exists())
        self.assertTrue(args[-1].endswith('/Build/Products/Debug/Bomu.app'))

    def test_running_app_refuses_launch_without_creating_library(self):
        (self.root / 'running').touch()
        result = self.run_session()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'open-args').exists())
        self.assertEqual(list(self.sessions.iterdir()), [])

    def test_locked_or_unknown_desktop_refuses_launch(self):
        for state in ['"IOConsoleLocked" = Yes', 'unavailable']:
            with self.subTest(state=state):
                self.stub('ioreg', f"printf '%s\\n' '{state}'")
                self.assertNotEqual(self.run_session().returncode, 0)
                self.assertFalse((self.root / 'open-args').exists())
                self.assertEqual(list(self.sessions.iterdir()), [])

    def test_large_unlocked_registry_output_does_not_trigger_pipefail(self):
        self.stub('ioreg', '''printf '%s\\n' '"IOConsoleLocked" = No'
printf '%0100000d' 0 ''')
        result = self.run_session()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / 'open-args').exists())

    def test_inherited_override_including_empty_value_is_rejected(self):
        for value in ['', '/tmp/old-session']:
            with self.subTest(value=value):
                self.env['BOMU_ACCEPTANCE_LIBRARY_DIRECTORY'] = value
                self.assertNotEqual(self.run_session().returncode, 0)
                self.assertFalse((self.root / 'open-args').exists())

    def test_launch_failure_with_live_app_retains_its_database(self):
        self.stub('open', 'touch "$TEST_ROOT/running"\nexit 1')
        result = self.run_session()
        self.assertNotEqual(result.returncode, 0)
        sessions = list(self.sessions.iterdir())
        self.assertEqual(len(sessions), 1)
        self.assertEqual((sessions[0] / '.bomu-acceptance-library').read_text(),
                         'Bomu isolated acceptance library\n')
        self.assertIn('Temporary library retained', result.stderr)

    def test_failed_process_query_retains_library(self):
        self.stub('pgrep', '[ -f "$TEST_ROOT/query-failed" ] && exit 2\nexit 1')
        self.stub('open', 'touch "$TEST_ROOT/query-failed"\nexit 1')
        result = self.run_session()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(list(self.sessions.iterdir())), 1)
        self.assertIn('Cannot determine', result.stderr)


if __name__ == '__main__':
    unittest.main()
