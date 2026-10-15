"""The internal package gate must verify resolved files stay inside the app bundle."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('package_internal',
    Path(__file__).resolve().parents[1] / 'scripts/package_internal.py')
package_internal = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package_internal)


class InternalPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.contents = self.root / 'Bomu.app/Contents'
        (self.contents / 'Frameworks').mkdir(parents=True)

    def test_accepts_regular_files_and_symlinks_resolving_inside_bundle(self):
        target = self.contents / 'libsample-real.dylib'
        target.write_bytes(b'library')
        link = self.contents / 'Frameworks/libsample.dylib'
        link.symlink_to('../libsample-real.dylib')

        self.assertTrue(package_internal.is_bundled_file(target, self.contents))
        self.assertTrue(package_internal.is_bundled_file(link, self.contents))

    def test_rejects_symlinks_resolving_outside_bundle_and_missing_files(self):
        outside = self.root / 'external.dylib'
        outside.write_bytes(b'library')
        link = self.contents / 'Frameworks/libsample.dylib'
        link.symlink_to(outside)

        self.assertFalse(package_internal.is_bundled_file(link, self.contents))
        self.assertFalse(package_internal.is_bundled_file(
            self.contents / 'Frameworks/missing.dylib', self.contents))

    def test_rpath_resolution_requires_a_declared_runpath(self):
        library = self.contents / 'Frameworks/libsample.dylib'
        library.write_bytes(b'library')
        executable_dir = self.contents / 'MacOS'
        executable_dir.mkdir()

        resolved = package_internal.resolve_rpath_dependency(
            '@rpath/libsample.dylib', self.contents / 'Frameworks', executable_dir,
            [], [], self.contents)

        self.assertIsNone(resolved)

    def test_rpath_resolution_uses_the_actual_executable_runpath(self):
        library = self.contents / 'Frameworks/libsample.dylib'
        library.write_bytes(b'library')
        executable_dir = self.contents / 'MacOS'
        executable_dir.mkdir()

        resolved = package_internal.resolve_rpath_dependency(
            '@rpath/libsample.dylib', self.contents / 'Frameworks', executable_dir,
            [], ['@executable_path/../Frameworks'], self.contents)

        self.assertEqual(library.resolve(), resolved.resolve())


if __name__ == '__main__':
    unittest.main()
