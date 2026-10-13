#!/usr/bin/env python3
"""Verify the selected compiler and SDK against the shared development lock."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def output(arguments):
    try:
        result = subprocess.run(arguments, check=True, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        raise ValueError(f'Cannot inspect {arguments[0]}: {error}') from error
    return result.stdout.strip()


def inspect_toolchain(environment):
    xcode = output(['/usr/bin/xcodebuild', '-version'])
    xcode_match = re.fullmatch(r'Xcode ([\d.]+)\nBuild version (\S+)', xcode)
    if xcode_match is None:
        raise ValueError('Cannot identify the selected Xcode version and build.')
    # A build setting can select a compiler independently of xcode-select.
    compiler = environment.get('SWIFT_EXEC') or output(['/usr/bin/xcrun', '--find', 'swiftc'])
    swift = output([compiler, '--version'])
    swift_match = re.search(r'Apple Swift version ([\d.]+) \(([^)]+)\)', swift)
    if swift_match is None:
        raise ValueError('Cannot identify the selected Apple Swift compiler.')
    sdk = environment.get('SDKROOT') or 'macosx'
    return {
        'xcode': xcode_match[1],
        'xcodeBuild': xcode_match[2],
        'swift': swift_match[1],
        'swiftBuild': swift_match[2],
        'macOSSDK': output(['/usr/bin/xcrun', '--sdk', sdk, '--show-sdk-version']),
        'macOSSDKBuild': output(['/usr/bin/xcrun', '--sdk', sdk, '--show-sdk-build-version']),
    }


def verify_toolchain(expected, actual, build_environment=None):
    mismatches = []
    for key in ('xcode', 'xcodeBuild', 'swift', 'swiftBuild', 'macOSSDK', 'macOSSDKBuild'):
        if actual[key] != expected[key]:
            mismatches.append(f'{key}: expected {expected[key]}, found {actual[key]}')
    if build_environment is not None:
        # Validate resolved settings, including command-line overrides and Xcode GUI builds.
        settings = {
            'ARCHS': expected['architecture'],
            'MACOSX_DEPLOYMENT_TARGET': expected['deploymentTarget'],
            'SWIFT_VERSION': expected['swiftLanguageVersion'],
            'PLATFORM_NAME': 'macosx',
            'XCODE_PRODUCT_BUILD_VERSION': expected['xcodeBuild'],
            'SDK_VERSION': expected['macOSSDK'],
            'SDK_PRODUCT_BUILD_VERSION': expected['macOSSDKBuild'],
        }
        for key, value in settings.items():
            actual_value = build_environment.get(key)
            if actual_value != value:
                mismatches.append(f'{key}: expected {value}, found {actual_value!r}')
    if mismatches:
        raise ValueError('Development toolchain does not match Config/Dependencies.lock.json:\n  '
                         + '\n  '.join(mismatches))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-environment', action='store_true',
                        help='Also validate the resolved settings exported by an Xcode build phase.')
    parser.add_argument('--json', action='store_true', help='Print verified tool versions as JSON.')
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    try:
        expected = json.loads((root / 'Config/Dependencies.lock.json').read_text())['toolchain']
        actual = inspect_toolchain(os.environ)
        verify_toolchain(expected, actual, os.environ if arguments.build_environment else None)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f'error: {error}\nSelect the locked Xcode with DEVELOPER_DIR for this command; '
                    'do not change the lock just to silence a mismatch.\n')
    if arguments.json:
        print(json.dumps(actual, indent=2))
    else:
        print(f"Verified Xcode {actual['xcode']} ({actual['xcodeBuild']}), "
              f"Swift {actual['swift']}, macOS SDK {actual['macOSSDK']} ({actual['macOSSDKBuild']})")


if __name__ == '__main__':
    main()
