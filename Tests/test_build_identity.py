"""The Debug receipt must bind one source snapshot to one actual app bundle."""

import importlib.util
import io
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    'build_identity', Path(__file__).resolve().parents[1] / 'scripts/build_identity.py')
build_identity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(build_identity)


class BuildIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        source = self.root / 'Sources/Example.swift'
        source.parent.mkdir()
        source.write_text('struct Example {}\n')
        resolved = self.root / 'Bomu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        resolved.parent.mkdir(parents=True)
        resolved.write_text('{"pins": []}\n')
        self.app = self.root / 'Output/Bomu.app'
        info = self.app / 'Contents/Info.plist'
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'Bomu', 'CFBundleIdentifier': 'example.Bomu',
            'CFBundleShortVersionString': '0.0.1', 'CFBundleVersion': '2',
        }))
        executable = self.app / 'Contents/MacOS/Bomu'
        executable.parent.mkdir()
        executable.write_bytes(b'first build')

    def testReceiptTracksSourceAndActualBundleBytes(self):
        snapshot = build_identity.capture(self.root)
        first = build_identity.finalize(self.root, snapshot, self.app)
        self.assertEqual(first['sourceSHA256'], snapshot['sourceSHA256'])
        self.assertEqual(first['buildVersion'], '2')
        (self.app / 'Contents/MacOS/Bomu').write_bytes(b'second build')
        second = build_identity.finalize(self.root, snapshot, self.app)
        self.assertNotEqual(first['bundleSHA256'], second['bundleSHA256'])
        self.assertEqual(first['sourceSHA256'], second['sourceSHA256'])

    def testSourceChangeDuringBuildRejectsReceipt(self):
        snapshot = build_identity.capture(self.root)
        (self.root / 'Sources/Example.swift').write_text('struct Changed {}\n')
        with self.assertRaisesRegex(ValueError, 'Sources/Example.swift'):
            build_identity.finalize(self.root, snapshot, self.app)

    def testResolvedDependencyChangeRejectsReceipt(self):
        snapshot = build_identity.capture(self.root)
        resolved = self.root / 'Bomu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
        resolved.write_text('{"pins": ["changed"]}\n')
        with self.assertRaisesRegex(ValueError, 'Package.resolved'):
            build_identity.finalize(self.root, snapshot, self.app)

    def testResourceBytesAndAssetCatalogChangesInvalidateReceipt(self):
        for relative in ('Sources/Resources/WelcomeLandscape.png',
                         'Sources/DesignSystem/Artwork.xcassets/Hero.imageset/hero.png'):
            with self.subTest(resource=relative):
                resource = self.root / relative
                resource.parent.mkdir(parents=True, exist_ok=True)
                resource.write_bytes(b'original artwork')
                receipt = build_identity.finalize(
                    self.root, build_identity.capture(self.root), self.app)
                resource.write_bytes(b'revised artwork')
                with self.assertRaisesRegex(ValueError, 'Build inputs changed'):
                    build_identity.verify(self.root, receipt, self.app)
                resource.unlink()
                with self.assertRaisesRegex(ValueError, 'Build inputs changed'):
                    build_identity.verify(self.root, receipt, self.app)

    def testMissingDeclaredExecutableRejectsReceipt(self):
        snapshot = build_identity.capture(self.root)
        (self.app / 'Contents/MacOS/Bomu').unlink()
        with self.assertRaisesRegex(ValueError, 'declared executable'):
            build_identity.finalize(self.root, snapshot, self.app)

    def testOverlayInputsInvalidateReceiptWhenAddedChangedOrRemoved(self):
        for relative in ('Tools/MPVOverlay/inputs.json',
                         'Tools/MPVOverlay/mpv-0.41.0-render-fence.patch',
                         'Tools/SeekProbe/ffmpeg-9.0.1-ts-keyframes.patch'):
            with self.subTest(input=relative):
                before_addition = build_identity.capture(self.root)
                source = self.root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(b'original overlay input')
                with self.assertRaisesRegex(ValueError, 'Build inputs changed'):
                    build_identity.finalize(self.root, before_addition, self.app)
                receipt = build_identity.finalize(
                    self.root, build_identity.capture(self.root), self.app)
                source.write_bytes(b'changed overlay input')
                with self.assertRaisesRegex(ValueError, 'Build inputs changed'):
                    build_identity.verify(self.root, receipt, self.app)
                source.unlink()
                with self.assertRaisesRegex(ValueError, 'Build inputs changed'):
                    build_identity.verify(self.root, receipt, self.app)

    def testVerificationRejectsBundleChangedAfterBuild(self):
        receipt = build_identity.finalize(self.root, build_identity.capture(self.root), self.app)
        build_identity.verify(self.root, receipt, self.app)
        (self.app / 'Contents/MacOS/Bomu').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'bundleSHA256'):
            build_identity.verify(self.root, receipt, self.app)

    def testVerifyCommandUsesReceiptWithoutOutputArgument(self):
        receipt = build_identity.finalize(self.root, build_identity.capture(self.root), self.app)
        receipt_path = self.root / 'receipt.json'
        receipt_path.write_text(json.dumps(receipt))
        with patch('sys.argv', ['build_identity.py', 'verify', '--root', str(self.root),
                                '--receipt', str(receipt_path)]), redirect_stdout(io.StringIO()) as output:
            build_identity.main()
        self.assertIn('Verified build identity:', output.getvalue())


if __name__ == '__main__':
    unittest.main()
