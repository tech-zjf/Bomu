import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/prepare-test-media.py'
SPEC = importlib.util.spec_from_file_location('prepare_test_media', SCRIPT)
prepare_test_media = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare_test_media)


class PrepareTestMediaTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.sample = self.directory / 'sample.mp4'
        self.sample_bytes = b'CC0 synthetic fixture'
        self.sample_name = self.sample.name

    def write_valid_fixture(self):
        self.sample.write_bytes(self.sample_bytes)
        manifest = {'samples': [{
            'file': self.sample_name,
            'sha256': hashlib.sha256(self.sample_bytes).hexdigest(),
        }]}
        (self.directory / 'manifest.json').write_text(json.dumps(manifest))

    def test_missing_manifest_runs_generator_then_verifies_generated_hash(self):
        def generate(command, *, cwd, check):
            self.assertEqual(command, ['fixture-generator'])
            self.assertEqual(cwd, prepare_test_media.ROOT)
            self.assertTrue(check)
            self.write_valid_fixture()

        with patch.object(prepare_test_media.subprocess, 'run', side_effect=generate) as run:
            prepare_test_media.ensure_samples(self.directory, {self.sample_name}, ['fixture-generator'])
        run.assert_called_once()

    def test_existing_corrupt_fixture_fails_closed_without_regeneration(self):
        self.write_valid_fixture()
        self.sample.write_bytes(b'changed')

        with patch.object(prepare_test_media.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                prepare_test_media.ensure_samples(self.directory, {self.sample_name}, ['fixture-generator'])
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
