#!/usr/bin/env python3
"""Build, sign, notarize, staple, and assess a Bomu macOS distribution."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / 'Config/Dependencies.lock.json'
PRODUCTS = ROOT / '.build/DerivedData/Build/Products/Release'


class ReleaseError(RuntimeError):
    pass


def run(arguments: list[str], *, capture: bool = False) -> str:
    result = subprocess.run(arguments, check=False, text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        details = result.stderr.strip() if capture and result.stderr else ''
        raise ReleaseError(f"Command failed ({result.returncode}): {' '.join(arguments)}"
                           + (f'\n{details}' if details else ''))
    return (result.stdout or result.stderr or '') if capture else ''


def verify_distribution_prerequisites() -> None:
    audit = subprocess.run([sys.executable, str(ROOT / 'scripts/license_audit.py'), 'check'],
                           check=False)
    if audit.returncode:
        raise ReleaseError('Release blocked: dependency license/provenance audit is incomplete.')
    lock = json.loads(LOCK_PATH.read_text())
    if lock.get('distributionReady') is not True or lock.get('usage') != 'redistributable':
        raise ReleaseError('Release blocked: dependency lock is not approved for distribution.')
    run([sys.executable, str(ROOT / 'scripts/toolchain.py')])
    run([sys.executable, str(ROOT / 'scripts/dependencies.py'), 'check'])


def distribution_preflight_issues() -> list[str]:
    issues = []
    try:
        audit = subprocess.run(
            [sys.executable, str(ROOT / 'scripts/license_audit.py'), 'check'],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        if audit.returncode:
            details = (audit.stderr or audit.stdout).strip()
            issue = 'Dependency license/provenance audit is incomplete.'
            issues.append(f'{issue}\n{details}' if details else issue)
    except OSError as error:
        issues.append(f'Could not run dependency license/provenance audit: {error}')

    try:
        lock = json.loads(LOCK_PATH.read_text())
        if lock.get('distributionReady') is not True or lock.get('usage') != 'redistributable':
            issues.append('Dependency lock is not approved for distribution.')
    except (OSError, json.JSONDecodeError) as error:
        issues.append(f'Could not read dependency lock: {error}')

    checks = (
        ('Locked toolchain check failed', [sys.executable, str(ROOT / 'scripts/toolchain.py')]),
        ('Locked runtime dependency check failed',
         [sys.executable, str(ROOT / 'scripts/dependencies.py'), 'check']),
    )
    for description, command in checks:
        try:
            run(command)
        except (ReleaseError, OSError) as error:
            issues.append(f'{description}: {error}')
    return issues


def developer_id_identities() -> list[tuple[str, str]]:
    listing = run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture=True)
    installed = []
    for line in listing.splitlines():
        match = re.match(r'\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"(?:\s|$)', line)
        if match is None:
            continue
        fingerprint, name = match.groups()
        if name.startswith('Developer ID Application:'):
            installed.append((fingerprint.upper(), name))
    return installed


def verify_identity(identity: str) -> None:
    installed = developer_id_identities()
    fingerprint_request = identity.upper() if re.fullmatch(r'[0-9A-Fa-f]{40}', identity) else None
    if not any(fingerprint_request == fingerprint or identity == name
               for fingerprint, name in installed):
        raise ReleaseError(
            'The requested signing identity must exactly match an installed Developer ID '
            'Application name or 40-character certificate fingerprint.')


def release_preflight_issues(identity: str | None, notary_profile: str | None) -> list[str]:
    issues = distribution_preflight_issues()

    try:
        if identity:
            verify_identity(identity)
        elif developer_id_identities():
            issues.append('Set BOMU_SIGNING_IDENTITY or pass --identity to select a Developer ID identity.')
        else:
            issues.append('No valid Developer ID Application identity is installed.')
    except (ReleaseError, OSError) as error:
        issues.append(str(error))

    if not notary_profile:
        issues.append('Set BOMU_NOTARY_PROFILE or pass --notary-profile.')
    return issues


def verify_source_tree_clean() -> None:
    changes = run(['git', '-C', str(ROOT), 'status', '--porcelain', '--untracked-files=all'], capture=True)
    if changes.strip():
        raise ReleaseError('Release requires a clean Git working tree; commit or remove local changes first.')


def verify_runtime_closure(app: Path) -> None:
    run([sys.executable, str(ROOT / 'scripts/package_internal.py'), str(app)])


def sign_app(app: Path, identity: str) -> None:
    frameworks = app / 'Contents/Frameworks'
    expected = set(json.loads(LOCK_PATH.read_text()).get('libraries', {}))
    actual = {library.name for library in frameworks.glob('*.dylib')}
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        raise ReleaseError(f'Embedded runtime differs from the lock; missing={missing}, unexpected={unexpected}')
    for library in sorted(frameworks.glob('*.dylib')):
        run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', str(library)])
        run(['codesign', '--verify', '--strict', '--verbose=2', str(library)])
    run(['codesign', '--force', '--sign', identity, '--options', 'runtime', '--timestamp', str(app)])
    run(['codesign', '--verify', '--strict', '--verbose=2', str(app)])
    details = run(['codesign', '-dv', '--verbose=4', str(app)], capture=True)
    if 'Authority=Developer ID Application:' not in details:
        raise ReleaseError('Signed app does not report a Developer ID Application authority.')
    if 'flags=0x10000(runtime)' not in details:
        raise ReleaseError('Signed app is missing the hardened runtime flag.')


def submit_for_notarization(target: Path, profile: str) -> dict[str, str]:
    result = run(['xcrun', 'notarytool', 'submit', str(target), '--keychain-profile', profile,
                  '--wait', '--output-format', 'json'], capture=True)
    try:
        response = json.loads(result)
    except json.JSONDecodeError as error:
        raise ReleaseError('notarytool did not return valid JSON.') from error
    if response.get('status') != 'Accepted':
        raise ReleaseError(f"Apple notarization was not accepted: {response.get('status', 'unknown status')}")
    submission_id = response.get('id')
    if not submission_id:
        raise ReleaseError('Accepted notarization response did not include a submission ID.')
    return {'id': submission_id, 'status': 'Accepted'}


def staple_and_validate(target: Path) -> None:
    run(['xcrun', 'stapler', 'staple', str(target)])
    run(['xcrun', 'stapler', 'validate', str(target)])


def release_manifest(app: Path, dmg: Path, version: str, identity: str,
                     app_notarization: dict[str, str], dmg_notarization: dict[str, str]) -> dict:
    executable = app / 'Contents/MacOS/Bomu'
    frameworks = app / 'Contents/Frameworks'
    lock_bytes = LOCK_PATH.read_bytes()
    source_revision = run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], capture=True).strip()
    working_tree = run(['git', '-C', str(ROOT), 'status', '--porcelain', '--untracked-files=all'],
                       capture=True)
    return {
        'schemaVersion': 1,
        'app': 'Bomu.app',
        'version': version,
        'architecture': 'arm64',
        'minimumSystemVersion': '14.0',
        'source': {
            'revision': source_revision,
            'workingTreeClean': not working_tree.strip(),
        },
        'dependencyLockSHA256': hashlib.sha256(lock_bytes).hexdigest(),
        'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'runtimeSHA256': {
            library.name: hashlib.sha256(library.read_bytes()).hexdigest()
            for library in sorted(frameworks.glob('*.dylib'))
        },
        'signingIdentity': identity,
        'notarization': {'app': app_notarization, 'dmg': dmg_notarization},
        'dmg': dmg.name,
        'sha256': hashlib.sha256(dmg.read_bytes()).hexdigest(),
        'createdAt': datetime.now(timezone.utc).isoformat(),
    }


def package(output: Path, identity: str, profile: str) -> Path:
    source_app = PRODUCTS / 'Bomu.app'
    if not source_app.is_dir():
        raise ReleaseError(f'Release build did not produce {source_app}')
    version = run(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleShortVersionString',
                   str(source_app / 'Contents/Info.plist')], capture=True).strip()
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', version):
        raise ReleaseError(f'Unexpected app version: {version!r}')

    output.mkdir(parents=True, exist_ok=False)
    app = output / 'Bomu.app'
    shutil.copytree(source_app, app, symlinks=True)
    verify_runtime_closure(app)
    sign_app(app, identity)

    applications_link = output / 'Applications'
    applications_link.symlink_to('/Applications')
    with tempfile.TemporaryDirectory(prefix='bomu-notary-') as temporary:
        app_archive = Path(temporary) / f'Bomu-{version}-arm64-notarization.zip'
        run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(app_archive)])
        app_notarization = submit_for_notarization(app_archive, profile)
    staple_and_validate(app)
    run(['spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)])

    dmg = output.parent / f'Bomu-{version}-arm64.dmg'
    run(['hdiutil', 'create', '-quiet', '-volname', f'Bomu {version}', '-srcfolder', str(output),
         '-format', 'UDZO', str(dmg)])
    run(['codesign', '--force', '--sign', identity, '--timestamp', str(dmg)])
    run(['codesign', '--verify', '--strict', '--verbose=2', str(dmg)])
    dmg_notarization = submit_for_notarization(dmg, profile)
    staple_and_validate(dmg)
    run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature',
         '--verbose=4', str(dmg)])
    run(['hdiutil', 'verify', str(dmg)])
    manifest = release_manifest(app, dmg, version, identity, app_notarization, dmg_notarization)
    (output.parent / f'{dmg.stem}-release.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f"Notarized release: {dmg}\nSHA-256: {manifest['sha256']}")
    return dmg


def build(identity: str) -> None:
    run([sys.executable, str(ROOT / 'scripts/toolchain.py')])
    run([sys.executable, str(ROOT / 'scripts/dependencies.py'), 'check'])
    verify_source_tree_clean()
    run(['xcodebuild', '-project', str(ROOT / 'Bomu.xcodeproj'), '-scheme', 'Bomu',
         '-configuration', 'Release', '-destination', 'platform=macOS,arch=arm64',
         '-derivedDataPath', str(ROOT / '.build/DerivedData'),
         '-clonedSourcePackagesDirPath', str(ROOT / '.build/SourcePackages'),
         '-packageCachePath', str(ROOT / '.build/SwiftPMCache'),
         f'CODE_SIGN_IDENTITY={identity}', 'CODE_SIGN_STYLE=Manual',
         'ENABLE_HARDENED_RUNTIME=YES', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
         'CODE_SIGNING_ALLOWED=NO', 'build'])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', default=os.environ.get('BOMU_SIGNING_IDENTITY'),
                        help='Installed Developer ID Application identity name or SHA-1 hash.')
    parser.add_argument('--notary-profile', default=os.environ.get('BOMU_NOTARY_PROFILE'),
                        help='notarytool Keychain profile name; no credentials are read from this repository.')
    parser.add_argument('--preflight-only', action='store_true', help='Check release evidence and local signing setup.')
    arguments = parser.parse_args()
    try:
        if arguments.preflight_only:
            issues = release_preflight_issues(arguments.identity, arguments.notary_profile)
            if issues:
                print(f'Release preflight found {len(issues)} blocker(s):', file=sys.stderr)
                for issue in issues:
                    lines = issue.splitlines()
                    print(f'- {lines[0]}', file=sys.stderr)
                    for detail in lines[1:]:
                        print(f'  {detail}', file=sys.stderr)
                return 1
            print('Release prerequisites and Developer ID identity passed. '
                  'Notary credentials are checked on submission.')
            return 0

        verify_distribution_prerequisites()
        if not arguments.identity:
            raise ReleaseError('Set BOMU_SIGNING_IDENTITY or pass --identity.')
        verify_identity(arguments.identity)
        if not arguments.notary_profile:
            raise ReleaseError('Set BOMU_NOTARY_PROFILE or pass --notary-profile.')
        timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
        output_root = ROOT / '.build/distribution/releases' / timestamp
        build(arguments.identity)
        package(output_root / 'staging', arguments.identity, arguments.notary_profile)
        return 0
    except (ReleaseError, OSError, json.JSONDecodeError) as error:
        print(f'Release failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
