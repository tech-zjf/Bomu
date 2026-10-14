#!/usr/bin/env python3
"""Build an isolated, verified candidate benchmark app without launching a window."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

from media_fixtures import sha256_file

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('seek_lifecycle', ROOT / 'scripts/verify-seek-lifecycle.py')
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)


def source_identity():
    result = {}
    extensions = {'.swift', '.m', '.h', '.strings', '.py', '.sh', '.json', '.plist', '.xcconfig',
                  '.pbxproj', '.xcscheme'}
    for directory in ['Sources', 'Tools/PlaybackBenchmark', 'Config', 'Bomu.xcodeproj', 'scripts']:
        for path in sorted((ROOT / directory).rglob('*')):
            if path.is_file() and path.suffix in extensions:
                result[str(path.relative_to(ROOT))] = sha256_file(path)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('experiment', type=Path, help='Successful playback-format experiment directory')
    parser.add_argument('--output', type=Path, help='New app preparation directory inside the repository')
    args = parser.parse_args()
    experiment = args.experiment.resolve()
    subprocess.run([sys.executable, str(ROOT / 'scripts/toolchain.py')], check=True)
    subprocess.run([sys.executable, str(ROOT / 'scripts/dependencies.py'), 'check'], check=True)
    runtimes, _ = lifecycle.verified_inputs(experiment)
    report_path = experiment / 'report.json'
    report = json.loads(report_path.read_text())
    if (report['source'].get('profile') != 'playback-format'
            or report['source']['configure'] != lifecycle.candidate.PLAYBACK_FORMAT_CONFIGURE
            or report.get('capabilityDifferences') != {'rebuilt': [], 'candidate': []}):
        raise ValueError('Candidate must pass the current playback-format capability contract')
    for source, checksum in report['sourceSHA256'].items():
        if sha256_file(ROOT / source) != checksum:
            raise ValueError('Candidate source changed; rerun its experiment: ' + source)
    output = args.output.resolve() if args.output else experiment
    output.relative_to(ROOT)
    if args.output:
        output.mkdir(parents=True, exist_ok=False)
    application = output / 'BomuSeekCandidate.app'
    receipt_path = output / 'desktop-candidate.json'
    if application.exists() or receipt_path.exists():
        raise ValueError('Candidate app already exists; preserve it and select a new --output directory')
    sources = source_identity()
    build_log = output / 'desktop-build.log'
    with build_log.open('w') as log:
        subprocess.run(['xcodebuild', '-project', str(ROOT / 'Bomu.xcodeproj'),
            '-scheme', 'BomuBenchmark', '-configuration', 'Debug',
            '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(ROOT / '.build/DerivedData'),
            'CODE_SIGNING_ALLOWED=NO', 'build'], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    if source_identity() != sources:
        raise ValueError('Application sources changed while building')
    original = ROOT / '.build/DerivedData/Build/Products/Debug/BomuBenchmark.app'
    shutil.copytree(original, application)
    format_library = application / 'Contents/Frameworks/libavformat.63.dylib'
    shutil.copy2(runtimes['candidate'] / format_library.name, format_library)
    info_path = application / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    info.update(CFBundleIdentifier='io.github.tech-zjf.BomuSeekCandidate',
                CFBundleName='BomuSeekCandidate', CFBundleDisplayName='Bomu TS Seek Candidate')
    info_path.write_bytes(plistlib.dumps(info))
    # 只签名独立构建产物；正式缓存和原始基准应用不变，也不启动应用。
    subprocess.run(['codesign', '--force', '--sign', '-', str(format_library)], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(application)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(application)], check=True)
    if sha256_file(format_library) != report['runtimeSHA256']['candidate'][format_library.name]:
        raise ValueError('Candidate format library differs after app preparation')
    for path in (original / 'Contents/Frameworks').glob('*.dylib'):
        if path.name != format_library.name and sha256_file(path) != sha256_file(application / 'Contents/Frameworks' / path.name):
            raise ValueError('Unexpected change to another bundled runtime: ' + path.name)
    receipt = dict(schemaVersion=1, preparedAt=datetime.now(timezone.utc).isoformat(),
        experiment=str(experiment.relative_to(ROOT)),
        application=str(application.relative_to(ROOT)), bundleID=info['CFBundleIdentifier'],
        profile=report['source']['profile'], launched=False, desktopVerified=False,
        experimentReportSHA256=sha256_file(report_path), buildLogSHA256=sha256_file(build_log),
        sourceSHA256=sources,
        fileSHA256={str(path.relative_to(application)): sha256_file(path)
                    for directory in ['Contents/MacOS', 'Contents/Frameworks']
                    for path in sorted((application / directory).glob('*')) if path.is_file()})
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print('Prepared without launching: ' + str(application))


if __name__ == '__main__':
    main()
