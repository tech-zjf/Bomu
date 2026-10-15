import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from media_fixtures import sha256_file, verify_manifest, verify_package


class MediaFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.sample = self.directory / 'sample.mp4'
        self.sample.write_bytes(b'fixture')
        self.manifest = {'samples': [{'file': self.sample.name,
                                     'sha256': hashlib.sha256(b'fixture').hexdigest()}]}
        self.write_manifest()

    def write_manifest(self):
        (self.directory / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_streaming_hash_handles_empty_and_multiple_chunks(self):
        for data in [b'', b'x' * (2 * 1024 * 1024 + 7)]:
            self.sample.write_bytes(data)
            self.assertEqual(sha256_file(self.sample), hashlib.sha256(data).hexdigest())

    def test_original_media_matches_its_manifest(self):
        self.assertEqual(verify_manifest(self.directory), self.manifest)

    def test_changed_media_is_rejected_without_modifying_it(self):
        self.sample.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            verify_manifest(self.directory)
        self.assertEqual(self.sample.read_bytes(), b'changed')

    def test_missing_media_is_rejected(self):
        self.sample.unlink()
        with self.assertRaises(FileNotFoundError):
            verify_manifest(self.directory)

    def test_incomplete_or_ambiguous_manifest_is_rejected(self):
        for samples in [[], [{'file': '../sample.mp4', 'sha256': 'a' * 64}],
                        [{'file': 'sample.mp4', 'sha256': 'unknown'}],
                        self.manifest['samples'] * 2]:
            with self.subTest(samples=samples):
                self.manifest['samples'] = samples
                self.write_manifest()
                with self.assertRaises(ValueError):
                    verify_manifest(self.directory)


class MediaPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive_path = self.root / 'suite.tar.gz'
        self.manifest_path = self.root / 'recorded-manifest.json'
        self.sample = b'licensed fixture'
        self.sample_hash = hashlib.sha256(self.sample).hexdigest()
        self.sample_manifest = {'samples': [{'file': 'sample.mp4', 'sha256': self.sample_hash,
                                             'license': 'CC0-1.0'}]}

    def write_archive(self, *, sample=None, extra=()):
        sample = self.sample if sample is None else sample
        embedded = json.dumps(self.sample_manifest).encode()
        entries = {
            'media-suite/sample.mp4': sample,
            'media-suite/manifest.json': embedded,
            'media-suite/LICENSE.txt': b'CC0-1.0 https://creativecommons.org/publicdomain/zero/1.0/',
            'media-suite/README.txt': b'See manifest.json.',
            **dict(extra),
        }
        with tarfile.open(self.archive_path, 'w:gz') as archive:
            for name, data in entries.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        recorded = dict(self.sample_manifest)
        recorded['package'] = {'path': 'suite.tar.gz', 'bytes': self.archive_path.stat().st_size,
                               'sha256': sha256_file(self.archive_path)}
        self.manifest_path.write_text(json.dumps(recorded))

    def test_recorded_package_is_verified_without_extraction(self):
        self.write_archive()
        self.assertEqual(verify_package(self.manifest_path, self.root)['package']['path'], 'suite.tar.gz')
        self.assertFalse((self.root / 'sample.mp4').exists())

    def test_media_hash_mismatch_is_rejected_even_when_archive_hash_is_updated(self):
        self.write_archive(sample=b'different content')
        with self.assertRaisesRegex(ValueError, 'sample hashes'):
            verify_package(self.manifest_path, self.root)

    def test_archive_path_traversal_is_rejected_even_when_archive_hash_is_updated(self):
        self.write_archive(extra=(('../../outside', b'data'),))
        with self.assertRaisesRegex(ValueError, 'Unsafe or duplicate'):
            verify_package(self.manifest_path, self.root)

    def test_package_symlink_cannot_escape_the_repository_root(self):
        self.write_archive()
        with tempfile.TemporaryDirectory() as external:
            external_archive = Path(external) / 'suite.tar.gz'
            external_archive.write_bytes(self.archive_path.read_bytes())
            self.archive_path.unlink()
            self.archive_path.symlink_to(external_archive)
            with self.assertRaisesRegex(ValueError, 'outside the repository'):
                verify_package(self.manifest_path, self.root)

    def test_unexpected_archive_entries_are_rejected(self):
        self.write_archive(extra=(('media-suite/extra.mp4', b'extra'),))
        with self.assertRaisesRegex(ValueError, 'entries do not match'):
            verify_package(self.manifest_path, self.root)

    def test_corrupt_or_missing_package_identity_is_rejected(self):
        self.write_archive()
        with self.assertRaisesRegex(ValueError, 'identity mismatch'):
            self.archive_path.write_bytes(self.archive_path.read_bytes() + b'corrupt')
            verify_package(self.manifest_path, self.root)


if __name__ == '__main__':
    unittest.main()
