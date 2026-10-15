import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))

from dependencies import copy_locked_archive_libraries


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


if __name__ == '__main__':
    unittest.main()
