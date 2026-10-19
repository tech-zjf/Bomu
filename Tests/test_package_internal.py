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

    def test_macos_build_version_within_supported_floor_is_accepted(self):
        load_commands = """Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 11.0
      sdk 26.5
"""

        self.assertEqual(
            package_internal.verify_macos_deployment_target(load_commands, '14.0'),
            '11.0'
        )

    def test_legacy_macos_version_command_is_accepted(self):
        load_commands = """Load command 9
      cmd LC_VERSION_MIN_MACOSX
  cmdsize 16
  version 13.0
      sdk 13.3
"""

        self.assertEqual(
            package_internal.verify_macos_deployment_target(load_commands, '14.0'),
            '13.0'
        )

    def test_dependency_above_supported_macos_floor_is_rejected(self):
        load_commands = """Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 14.1
      sdk 26.5
"""

        with self.assertRaisesRegex(ValueError, 'requires macOS 14.1'):
            package_internal.verify_macos_deployment_target(load_commands, '14.0')

    def test_non_macos_binary_is_rejected(self):
        load_commands = """Load command 11
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 2
    minos 14.0
      sdk 26.5
"""

        with self.assertRaisesRegex(ValueError, 'does not target macOS'):
            package_internal.verify_macos_deployment_target(load_commands, '14.0')


if __name__ == '__main__':
    unittest.main()
