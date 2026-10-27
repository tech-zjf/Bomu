#!/usr/bin/env python3
"""Record the exact inputs and bundle produced by a local Debug build."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib


INPUT_DIRECTORIES = ('Sources', 'Tools/PlaybackBenchmark', 'Tools/MPVOverlay',
                     'Config', 'Bomu.xcodeproj', 'scripts')
INPUT_SUFFIXES = {'.swift', '.m', '.mm', '.c', '.h', '.strings', '.xcassets', '.py',
                  '.sh', '.json', '.plist', '.xcconfig', '.pbxproj', '.xcscheme', '.patch'}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def digest_json(value: object) -> str:
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    return hashlib.sha256(data).hexdigest()


def source_files(root: Path) -> dict[str, str]:
    files = {}
    for directory in INPUT_DIRECTORIES:
        for path in sorted((root / directory).rglob('*')):
            # Resource bytes affect the visible app just as source code does.
            # Include all resource formats and asset-catalog contents, not only
            # text files: an edited illustration must invalidate an old receipt.
            is_resource = path.is_relative_to(root / 'Sources/Resources') or any(
                parent.suffix == '.xcassets' for parent in path.relative_to(root).parents)
            if path.is_file() and (path.suffix in INPUT_SUFFIXES or is_resource):
                files[str(path.relative_to(root))] = sha256_file(path)
    for name in ('Package.swift', 'Package.resolved',
                 'Bomu.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
                 'Tools/SeekProbe/ffmpeg-9.0.1-ts-keyframes.patch'):
        path = root / name
        if path.is_file():
            files[name] = sha256_file(path)
    return files


def capture(root: Path) -> dict:
    files = source_files(root)
    if not files:
        raise ValueError('No build inputs found')
    return {'schemaVersion': 1, 'sourceSHA256': digest_json(files), 'sourceFiles': files}


def finalize(root: Path, snapshot: dict, app: Path) -> dict:
    current = capture(root)
    if snapshot != current:
        changed = sorted(set(snapshot.get('sourceFiles', {})) ^ set(current['sourceFiles']))
        changed += sorted(name for name in set(snapshot.get('sourceFiles', {})) & set(current['sourceFiles'])
                          if snapshot['sourceFiles'][name] != current['sourceFiles'][name])
        raise ValueError('Build inputs changed during build: ' + ', '.join(changed[:8]))
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable = info.get('CFBundleExecutable')
    if not isinstance(executable, str) or not (app / 'Contents/MacOS' / executable).is_file():
        raise ValueError('App has no declared executable')
    bundle_files = {str(path.relative_to(app)): sha256_file(path)
                    for path in sorted(app.rglob('*')) if path.is_file()}
    return {
        'schemaVersion': 1,
        'createdAt': datetime.now(timezone.utc).isoformat(),
        'application': str(app.resolve()),
        'bundleIdentifier': info['CFBundleIdentifier'],
        'shortVersion': info['CFBundleShortVersionString'],
        'buildVersion': info['CFBundleVersion'],
        'localizations': sorted(path.name for path in (app / 'Contents/Resources').glob('*.lproj')),
        'sourceSHA256': snapshot['sourceSHA256'],
        'sourceFiles': snapshot['sourceFiles'],
        'bundleSHA256': digest_json(bundle_files),
        'bundleFiles': bundle_files,
    }


def verify(root: Path, receipt: dict, app: Path) -> None:
    if Path(receipt['application']) != app.resolve():
        raise ValueError('Receipt points to a different application')
    fresh = finalize(root, {
        'schemaVersion': receipt['schemaVersion'],
        'sourceSHA256': receipt['sourceSHA256'],
        'sourceFiles': receipt['sourceFiles'],
    }, app)
    for key in ('bundleIdentifier', 'shortVersion', 'buildVersion', 'localizations',
                'bundleSHA256', 'bundleFiles'):
        if fresh[key] != receipt[key]:
            raise ValueError(f'Application differs from receipt: {key}')


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('capture', 'finalize', 'verify'))
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--output', type=Path)
    parser.add_argument('--snapshot', type=Path)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    if args.action != 'verify' and args.output is None:
        parser.error(f'{args.action} requires --output')
    if args.action == 'capture':
        value = capture(root)
    elif args.action == 'finalize':
        if args.snapshot is None or args.app is None:
            parser.error('finalize requires --snapshot and --app')
        value = finalize(root, json.loads(args.snapshot.read_text()), args.app)
    else:
        if args.receipt is None:
            parser.error('verify requires --receipt')
        receipt = json.loads(args.receipt.read_text())
        app = args.app or Path(receipt['application'])
        verify(root, receipt, app)
        print(f"Verified build identity: {app} ({receipt['sourceSHA256']})")
        return
    write_json(args.output, value)
    print(f"{args.action} build identity: {args.output} ({value['sourceSHA256']})")


if __name__ == '__main__':
    main()
