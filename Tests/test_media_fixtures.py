import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from media_fixtures import sha256_file, verify_manifest


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


if __name__ == '__main__':
    unittest.main()
