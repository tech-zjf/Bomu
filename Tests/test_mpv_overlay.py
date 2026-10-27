"""Input and process ownership boundaries for the real mpv overlay builder."""
import hashlib
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import mpv_overlay


class OverlayInputsTests(unittest.TestCase):
    def test_changed_builder_definition_or_output_binding_is_rejected(self):
        expected = mpv_overlay.definition()
        expected['librarySHA256'] = 'a' * 64
        mpv_overlay.verify_definition(expected, 'a' * 64)
        with self.assertRaisesRegex(ValueError, 'output hash'):
            mpv_overlay.verify_definition(expected, 'b' * 64)
        expected['inputsSHA256'] = 'c' * 64
        with self.assertRaisesRegex(ValueError, 'definition differs'):
            mpv_overlay.verify_definition(expected, 'a' * 64)

    def test_changed_cached_archive_is_rejected_without_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'source.tar.gz').write_bytes(b'changed source')
            record = dict(filename='source.tar.gz', url='https://example.invalid/source',
                          sha256=hashlib.sha256(b'original source').hexdigest())
            with patch.object(mpv_overlay.subprocess, 'run') as download:
                with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                    mpv_overlay.cached_archive(record, root)
                download.assert_not_called()
            self.assertEqual(b'changed source', (root / 'source.tar.gz').read_bytes())

    def test_wrong_download_never_becomes_verified_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = dict(filename='source.tar.gz', url='https://example.invalid/source',
                          sha256=hashlib.sha256(b'expected').hexdigest())
            def download(command, **_kwargs):
                Path(command[command.index('-o') + 1]).write_bytes(b'wrong')
            with patch.object(mpv_overlay.subprocess, 'run', side_effect=download):
                with self.assertRaises(ValueError):
                    mpv_overlay.cached_archive(record, root)
            self.assertEqual([], list(root.iterdir()))

    def test_source_archive_cannot_escape_build_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'source.tar'
            with tarfile.open(archive, 'w') as output:
                member = tarfile.TarInfo('../outside')
                member.size = 4
                output.addfile(member, io.BytesIO(b'evil'))
            with self.assertRaises(tarfile.FilterError):
                mpv_overlay.unpack(archive, root / 'source')
            self.assertFalse((root / 'outside').exists())


@unittest.skipUnless(os.name == 'posix', 'Build ownership uses POSIX process groups')
class OverlayProcessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='bomu-overlay-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def invoke(self, code, timeout=5):
        return mpv_overlay.run([sys.executable, '-c', code], cwd=self.root,
                               env=os.environ.copy(), log=self.root / 'run.log', timeout=timeout)

    def ended(self, pid):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.02)
        self.fail(f'Owned process {pid} survived cleanup')

    def test_exit_status_and_signal_handlers_are_preserved(self):
        before = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
        self.invoke('print("completed")')
        with self.assertRaises(subprocess.CalledProcessError) as failure:
            self.invoke('raise SystemExit(9)')
        self.assertEqual(9, failure.exception.returncode)
        self.assertEqual(before, {sig: signal.getsignal(sig) for sig in before})

    def test_timeout_reaps_compiler_descendant_and_keeps_unrelated_process(self):
        ready = self.root / 'child.pid'
        child_code = ('import os,signal,time;from pathlib import Path;'
                      'signal.signal(signal.SIGTERM,signal.SIG_IGN);'
                      f'Path({str(ready)!r}).write_text(str(os.getpid()));time.sleep(30)')
        leader_code = (f'import subprocess,sys,time;subprocess.Popen([sys.executable,"-c",{child_code!r}]);'
                       'time.sleep(30)')
        unrelated = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'])
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                self.invoke(leader_code, timeout=1)
            self.assertTrue(ready.is_file())
            self.ended(int(ready.read_text()))
            self.assertIsNone(unrelated.poll())
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=5)

    def test_external_termination_cleans_owned_build_process(self):
        ready = self.root / 'ready.pid'
        child = ('import os,time;from pathlib import Path;'
                 f'Path({str(ready)!r}).write_text(str(os.getpid()));time.sleep(30)')
        wrapper = ('import sys,os;sys.path.insert(0,' + repr(str(mpv_overlay.ROOT / 'scripts')) + ');'
                   'import mpv_overlay;from pathlib import Path;'
                   f'mpv_overlay.run([sys.executable,"-c",{child!r}],cwd=Path({str(self.root)!r}),'
                   f'env=os.environ.copy(),log=Path({str(self.root / "outer.log")!r}),timeout=30)')
        process = subprocess.Popen([sys.executable, '-c', wrapper])
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not ready.is_file():
                time.sleep(0.02)
            self.assertTrue(ready.is_file())
            pid = int(ready.read_text())
            process.terminate()
            self.assertEqual(143, process.wait(timeout=8))
            self.ended(pid)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
