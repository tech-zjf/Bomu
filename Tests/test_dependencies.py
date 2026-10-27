import hashlib
from contextlib import ExitStack
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

import dependencies
from dependencies import copy_locked_archive_libraries, publish_runtime


class LockedDependencyArchiveTests(unittest.TestCase):
    def test_copies_only_locked_libraries_and_checks_their_hashes(self):
        contents = {
            'libone.dylib': b'first library',
            'libtwo.dylib': b'second library',
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'runtime.zip'
            destination = root / 'staging'
            with zipfile.ZipFile(archive, 'w') as output:
                for name, data in contents.items():
                    output.writestr(name, data)

            copy_locked_archive_libraries(
                archive,
                destination,
                expected_names=contents,
                selected_hashes={'libtwo.dylib': hashlib.sha256(contents['libtwo.dylib']).hexdigest()},
            )

            self.assertEqual((destination / 'libtwo.dylib').read_bytes(), contents['libtwo.dylib'])
            self.assertFalse((destination / 'libone.dylib').exists())

    def test_rejects_path_entries_before_writing_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'runtime.zip'
            destination = root / 'staging'
            with zipfile.ZipFile(archive, 'w') as output:
                output.writestr('../libone.dylib', b'library')

            with self.assertRaisesRegex(ValueError, 'flat library filenames'):
                copy_locked_archive_libraries(
                    archive,
                    destination,
                    expected_names={'../libone.dylib'},
                    selected_hashes={'../libone.dylib': hashlib.sha256(b'library').hexdigest()},
                )

            self.assertEqual(list(destination.glob('*')), [])

    def test_removes_a_partial_file_when_locked_hash_does_not_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'runtime.zip'
            destination = root / 'staging'
            with zipfile.ZipFile(archive, 'w') as output:
                output.writestr('libone.dylib', b'actual library')

            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                copy_locked_archive_libraries(
                    archive,
                    destination,
                    expected_names={'libone.dylib'},
                    selected_hashes={'libone.dylib': hashlib.sha256(b'wrong library').hexdigest()},
                )

            self.assertFalse((destination / 'libone.dylib').exists())


class RuntimePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='bomu-runtime-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.current = self.root / 'lib'
        self.staging = self.root / 'staging'
        self.current.mkdir()
        self.staging.mkdir()
        (self.current / 'runtime').write_bytes(b'previous complete runtime')
        (self.staging / 'runtime').write_bytes(b'new verified runtime')

    def test_success_publishes_verified_set_and_cleans_backup(self):
        publish_runtime(self.staging, self.current)
        self.assertEqual(b'new verified runtime', (self.current / 'runtime').read_bytes())
        self.assertFalse(self.staging.exists())
        self.assertEqual([], list(self.root.glob('runtime-backup-*')))

    def test_exception_or_interruption_during_either_rename_preserves_old_set(self):
        original = Path.replace
        for failure in (ValueError, KeyboardInterrupt, SystemExit):
            for fail_source in (self.current, self.staging):
                with self.subTest(failure=failure.__name__, phase=fail_source.name):
                    def replace(path, target):
                        if path == fail_source:
                            raise failure('injected publication failure')
                        return original(path, target)
                    with patch.object(Path, 'replace', replace):
                        with self.assertRaises(failure):
                            publish_runtime(self.staging, self.current)
                    self.assertEqual(b'previous complete runtime',
                                     (self.current / 'runtime').read_bytes())
                    self.assertTrue(self.staging.exists())
                    self.assertEqual([], list(self.root.glob('runtime-backup-*')))

    def test_failed_rollback_keeps_previous_bytes_outside_staging_cleanup(self):
        original = Path.replace
        def replace(path, target):
            if path == self.current:
                return original(path, target)
            raise OSError('injected publish and rollback failure')
        with patch.object(Path, 'replace', replace):
            with self.assertRaises(OSError):
                publish_runtime(self.staging, self.current)
        backups = list(self.root.glob('runtime-backup-*/lib/runtime'))
        self.assertEqual(1, len(backups))
        self.assertEqual(b'previous complete runtime', backups[0].read_bytes())
        self.assertFalse(backups[0].is_relative_to(self.staging))


class BootstrapOverlayTests(unittest.TestCase):
    def exercise(self, mode):
        digest = lambda value: hashlib.sha256(value).hexdigest()
        with tempfile.TemporaryDirectory(prefix='bomu-bootstrap-test-') as temporary:
            root = Path(temporary)
            cache = root / '.build/dependencies/lib'
            cache.mkdir(parents=True)
            (cache / 'previous').write_bytes(b'previous runtime')
            downloads = root / '.build/downloads'
            downloads.mkdir()
            (downloads / 'IINA.vtest.dmg').write_bytes(b'dmg')
            runtime_zip = downloads / 'iina-deps-fat.zip'
            mpv, avformat = 'libmpv.2.dylib', 'libavformat.63.dylib'
            with zipfile.ZipFile(runtime_zip, 'w') as archive:
                archive.writestr(mpv, b'zip mpv')
                archive.writestr(avformat, b'base format')
            patchfile = root / 'fix.patch'
            patchfile.write_bytes(b'ffmpeg patch')
            ff = dict(version='test', url='unused', sha256='source',
                      normalizeBuildUUID='content-sha256-v1', patch='fix.patch',
                      patchSHA256=digest(b'ffmpeg patch'), configure=[],
                      baseSHA256=digest(b'base format'), library=avformat,
                      librarySHA256=digest(b'new format'))
            overlay = dict(library=mpv, baseSHA256=digest(b'zip mpv'),
                           librarySHA256=digest(b'new mpv'))
            if mode == 'bad-base':
                overlay['baseSHA256'] = digest(b'different base')
            lock = dict(source=dict(version='test', url='unused', sha256=digest(b'dmg')),
                        ffmpegOverlay=ff, mpvOverlay=overlay,
                        verifiedRuntimeArtifact=dict(url='unused', sha256=digest(runtime_zip.read_bytes()),
                            overriddenLibraries=[mpv], replacedDMGHashes={mpv: digest(b'dmg mpv')}),
                        libraries={mpv: {'sha256': digest(b'new mpv')},
                                   avformat: {'sha256': digest(b'new format')}})
            def mount(command, **_kwargs):
                if command[:2] == ['hdiutil', 'attach']:
                    path = Path(command[command.index('-mountpoint') + 1]) / 'IINA.app/Contents/Frameworks'
                    path.mkdir(parents=True)
                    (path / mpv).write_bytes(b'dmg mpv')
                    (path / avformat).write_bytes(b'base format')
                return subprocess.CompletedProcess(command, 0)
            def build_format(output):
                library = output / avformat
                library.write_bytes(b'new format')
                return library
            def build_mpv(output, libraries):
                self.assertEqual(b'new format', (libraries / avformat).read_bytes())
                self.assertEqual(b'zip mpv', (libraries / mpv).read_bytes())
                if mode == 'compile-error':
                    raise RuntimeError('compiler failed')
                library = output / mpv
                library.write_bytes(b'wrong' if mode == 'bad-output' else b'new mpv')
                return library
            def check(libraries):
                for name, item in lock['libraries'].items():
                    dependencies.verify(libraries / name, item['sha256'])
            with ExitStack() as stack:
                stack.enter_context(patch.multiple(dependencies, ROOT=root, LIBRARIES=cache, LOCK=lock))
                stack.enter_context(patch.multiple(dependencies.ffmpeg_overlay, SOURCE_VERSION='test',
                    SOURCE_URL='unused', SOURCE_SHA256='source', PATCH=patchfile, CONFIGURE=[]))
                stack.enter_context(patch.object(dependencies.subprocess, 'run', side_effect=mount))
                stack.enter_context(patch.object(dependencies.ffmpeg_overlay, 'build_library', side_effect=build_format))
                stack.enter_context(patch.object(dependencies.mpv_overlay, 'build_library', side_effect=build_mpv))
                stack.enter_context(patch.object(dependencies.mpv_overlay, 'verify_definition'))
                stack.enter_context(patch.object(dependencies, 'check', side_effect=check))
                if mode == 'success':
                    dependencies.bootstrap()
                    self.assertEqual(b'new mpv', (cache / mpv).read_bytes())
                    self.assertEqual(b'new format', (cache / avformat).read_bytes())
                    self.assertFalse((cache / 'previous').exists())
                else:
                    with self.assertRaises((RuntimeError, ValueError, SystemExit)):
                        dependencies.bootstrap()
                    self.assertEqual([cache / 'previous'], list(cache.iterdir()))
                    self.assertEqual(b'previous runtime', (cache / 'previous').read_bytes())

    def test_zip_base_and_final_overlay_have_distinct_hashes(self):
        self.exercise('success')

    def test_bad_base_failed_build_or_wrong_output_preserves_runtime(self):
        for mode in ('bad-base', 'compile-error', 'bad-output'):
            with self.subTest(mode=mode):
                self.exercise(mode)


if __name__ == '__main__':
    unittest.main()
