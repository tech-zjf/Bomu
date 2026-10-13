"""Exercise version rejection and Xcode's resolved build-setting boundary."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('toolchain', Path(__file__).resolve().parents[1] / 'scripts/toolchain.py')
toolchain = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(toolchain)


class ToolchainTests(unittest.TestCase):
    def setUp(self):
        self.lock = {
            'xcode': '26.1.1', 'xcodeBuild': '17B100',
            'swift': '6.2.1', 'swiftBuild': 'swiftlang-6.2.1.4.8 clang-1700.4.4.1',
            'macOSSDK': '26.1', 'macOSSDKBuild': '25B74',
            'swiftLanguageVersion': '6.0', 'architecture': 'arm64', 'deploymentTarget': '14.0',
        }
        self.actual = {key: self.lock[key] for key in (
            'xcode', 'xcodeBuild', 'swift', 'swiftBuild', 'macOSSDK', 'macOSSDKBuild')}
        self.environment = {
            'ARCHS': 'arm64', 'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SWIFT_VERSION': '6.0',
            'PLATFORM_NAME': 'macosx', 'XCODE_PRODUCT_BUILD_VERSION': '17B100',
            'SDK_VERSION': '26.1', 'SDK_PRODUCT_BUILD_VERSION': '25B74',
        }

    def testMatchingCompilerAndBuildSettingsPass(self):
        toolchain.verify_toolchain(self.lock, self.actual, self.environment)

    def testEachChangedToolVersionIsRejected(self):
        for key in self.actual:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                toolchain.verify_toolchain(self.lock, dict(self.actual, **{key: 'unexpected'}))

    def testCommandLineTargetOverridesAreRejected(self):
        changes = {'ARCHS': 'arm64 x86_64', 'MACOSX_DEPLOYMENT_TARGET': '15.0',
                   'SWIFT_VERSION': '5.0', 'PLATFORM_NAME': 'iphoneos',
                   'XCODE_PRODUCT_BUILD_VERSION': '17B99', 'SDK_VERSION': '26.0',
                   'SDK_PRODUCT_BUILD_VERSION': '25A1'}
        for key, value in changes.items():
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                toolchain.verify_toolchain(self.lock, self.actual, dict(self.environment, **{key: value}))

    def testMissingBuildSettingDoesNotUseADefault(self):
        del self.environment['ARCHS']
        with self.assertRaisesRegex(ValueError, 'ARCHS'):
            toolchain.verify_toolchain(self.lock, self.actual, self.environment)

    @patch.object(toolchain, 'output')
    def testInspectionUsesActualCompilerAndSDKOverrides(self, output):
        output.side_effect = [
            'Xcode 26.1.1\nBuild version 17B100',
            'swift-driver version: 1.127.14.1 Apple Swift version 6.2.1 '
            '(swiftlang-6.2.1.4.8 clang-1700.4.4.1)\nTarget: arm64-apple-macosx26.0',
            '26.1', '25B74',
        ]
        actual = toolchain.inspect_toolchain({'SWIFT_EXEC': '/selected/swiftc', 'SDKROOT': '/selected/MacOSX.sdk'})
        self.assertEqual(actual, self.actual)
        self.assertEqual(output.call_args_list[1].args[0], ['/selected/swiftc', '--version'])
        self.assertEqual(output.call_args_list[2].args[0],
                         ['/usr/bin/xcrun', '--sdk', '/selected/MacOSX.sdk', '--show-sdk-version'])

    @patch.object(toolchain, 'output')
    def testDefaultCompilerIsResolvedThroughSelectedXcode(self, output):
        output.side_effect = [
            'Xcode 26.1.1\nBuild version 17B100', '/active/swiftc',
            'Apple Swift version 6.2.1 (swiftlang-6.2.1.4.8 clang-1700.4.4.1)', '26.1', '25B74',
        ]
        self.assertEqual(toolchain.inspect_toolchain({}), self.actual)
        self.assertEqual(output.call_args_list[1].args[0], ['/usr/bin/xcrun', '--find', 'swiftc'])
        self.assertEqual(output.call_args_list[2].args[0], ['/active/swiftc', '--version'])

    @patch.object(toolchain, 'output', return_value='unknown developer tool')
    def testUnrecognizedXcodeFailsExplicitly(self, output):
        with self.assertRaisesRegex(ValueError, 'Xcode'):
            toolchain.inspect_toolchain({})

    @patch.object(toolchain, 'output')
    def testUnrecognizedSwiftFailsExplicitly(self, output):
        output.side_effect = ['Xcode 26.1.1\nBuild version 17B100', 'Swift preview compiler']
        with self.assertRaisesRegex(ValueError, 'Swift'):
            toolchain.inspect_toolchain({'SWIFT_EXEC': '/preview/swiftc'})


if __name__ == '__main__':
    unittest.main()
