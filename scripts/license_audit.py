#!/usr/bin/env python3
"""Fail closed when release dependency provenance and notices are incomplete."""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / 'Config/Dependencies.lock.json'
MANIFEST_PATH = ROOT / 'Config/ThirdPartyLicenses.json'


def collect_gaps(lock, manifest, root=ROOT):
    gaps = []
    project = manifest.get('project', {})
    if project.get('status') != 'verified':
        gaps.append('Bomu project: verified evidence status')
    for key in ('licenseExpression', 'licenseFile', 'licenseSHA256'):
        if not project.get(key):
            gaps.append(f'Bomu project: {key}')
    if project.get('licenseFile') and project.get('licenseSHA256') and \
            _hash_at(root, project['licenseFile']) != project['licenseSHA256']:
        gaps.append('Bomu project: license file missing or hash mismatch')

    library_records = manifest.get('libraries', {})
    for name in sorted(set(library_records) - set(lock.get('libraries', {}))):
        gaps.append(f'{name}: record is not present in the runtime dependency lock')
    for name in sorted(lock.get('libraries', {})):
        record = library_records.get(name)
        if not record:
            gaps.append(f'{name}: verified component record')
            record = {}
        elif record.get('status') != 'verified':
            gaps.append(f'{name}: verified component record')
        for key in ('binarySHA256', 'licenseExpression', 'copyright', 'noticeFile', 'noticeSHA256',
                    'sourceURL', 'sourceVersion', 'sourceSHA256',
                    'buildRecipeFile', 'buildRecipeSHA256'):
            if not record.get(key):
                gaps.append(f'{name}: {key}')
        if record.get('sourceSHA256') and not _is_sha256(record['sourceSHA256']):
            gaps.append(f'{name}: source SHA-256 must contain 64 hexadecimal characters')
        if record.get('binarySHA256') and record['binarySHA256'] != lock['libraries'][name].get('sha256'):
            gaps.append(f'{name}: binary hash differs from dependency lock')
        notice_path = record.get('noticeFile')
        notice_hash = _hash_at(root, notice_path) if notice_path else None
        if notice_path and (notice_hash is None or notice_hash != record.get('noticeSHA256')):
            gaps.append(f'{name}: notice missing or hash mismatch')
        recipe_path = record.get('buildRecipeFile')
        recipe_hash = _hash_at(root, recipe_path) if recipe_path else None
        if recipe_path and (recipe_hash is None or recipe_hash != record.get('buildRecipeSHA256')):
            gaps.append(f'{name}: build recipe missing or hash mismatch')
        elif recipe_hash is not None:
            gaps.extend(_recipe_binary_gaps(name, record, root / recipe_path, root))

    package_records = manifest.get('swiftPackages', {})
    for name in sorted(set(package_records) - set(lock.get('swiftPackages', {}))):
        gaps.append(f'{name}: record is not present in the Swift package lock')
    for name, package in sorted(lock.get('swiftPackages', {}).items()):
        record = package_records.get(name)
        if not record:
            gaps.append(f'{name}: verified Swift package record')
            record = {}
        elif record.get('status') != 'verified':
            gaps.append(f'{name}: verified Swift package record')
        for key in ('licenseExpression', 'sourceURL', 'sourceRevision', 'noticeFile', 'noticeSHA256'):
            if not record.get(key):
                gaps.append(f'{name}: {key}')
        if record.get('licenseExpression') != package.get('license'):
            gaps.append(f'{name}: license expression differs from dependency lock')
        if record.get('sourceURL') != package.get('url'):
            gaps.append(f'{name}: source URL differs from dependency lock')
        if record.get('sourceRevision') != package.get('revision'):
            gaps.append(f'{name}: source revision differs from dependency lock')
        notice_path = record.get('noticeFile')
        if notice_path and _hash_at(root, notice_path) != record.get('noticeSHA256'):
            gaps.append(f'{name}: notice missing or hash mismatch')
    return gaps


def summarize_gaps(gaps):
    grouped = defaultdict(list)
    for gap in gaps:
        component, requirement = gap.split(': ', maxsplit=1)
        grouped[requirement].append(component)
    lines = [f'Release license/provenance audit incomplete: {len(gaps)} evidence requirements remain.']
    for requirement, components in sorted(grouped.items()):
        names = ', '.join(components)
        lines.append(f'- {requirement} ({len(components)}): {names}')
    return '\n'.join(lines)


def _hash_at(root, relative_path):
    root = root.resolve()
    path = (root / relative_path).resolve()
    if not path.is_relative_to(root):
        return None
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _is_sha256(value):
    return isinstance(value, str) and re.fullmatch(r'[0-9a-fA-F]{64}', value) is not None


def _recipe_binary_gaps(name, record, recipe_path, repository_root):
    try:
        recipe = json.loads(recipe_path.read_text())
    except (OSError, json.JSONDecodeError):
        return [f'{name}: build recipe is not valid JSON']

    gaps = []
    source_license = recipe.get('sourceLicense', {})
    if not isinstance(source_license, dict):
        gaps.append(f'{name}: source license reference evidence is invalid')
        source_license = {}
    reference_files = source_license.get('referenceFiles', [])
    if not isinstance(reference_files, list):
        gaps.append(f'{name}: source license reference evidence is invalid')
        reference_files = []
    for reference in reference_files:
        if not isinstance(reference, dict):
            gaps.append(f'{name}: source license reference evidence is invalid')
            continue
        path = reference.get('path')
        expected_hash = reference.get('sha256')
        if not path or not _is_sha256(expected_hash):
            gaps.append(f'{name}: source license reference path or SHA-256 is invalid')
        elif _hash_at(repository_root, path) != expected_hash:
            gaps.append(f'{name}: source license reference file missing or hash mismatch')

    recipe_status = recipe.get('verificationStatus')
    if isinstance(recipe_status, dict):
        recipe_status = recipe_status.get('status')
    binary_match = recipe.get('binaryMatch', {})
    binary_comparison = recipe.get('binaryComparison', {})
    if recipe_status is None:
        recipe_status = binary_comparison.get('verificationStatus')
    if recipe_status and recipe_status != record.get('status'):
        gaps.append(f'{name}: manifest status conflicts with build recipe')

    component_evidence = binary_match.get('components', {}).get(name)
    if component_evidence is None:
        component_evidence = binary_match.get('components', {}).get('components', {}).get(name)
    if component_evidence is None and binary_match.get('workspaceBinarySHA256'):
        component_evidence = binary_match
    if component_evidence is None and binary_comparison.get('workspaceBinarySHA256'):
        component_evidence = binary_comparison
    if component_evidence:
        workspace_hash = component_evidence.get('workspaceBinarySHA256')
        if workspace_hash and workspace_hash != record.get('binarySHA256'):
            gaps.append(f'{name}: build recipe binary hash differs from license manifest')
        artifact_match = component_evidence.get('matchesReleaseArtifact')
        if artifact_match is None:
            artifact_match = binary_comparison.get('canonicalContentMatch')
        if artifact_match is False and record.get('status') == 'verified':
            gaps.append(f'{name}: build recipe records a release artifact mismatch')

    output_hash = recipe.get('output', {}).get('binarySHA256InDependencyLock')
    if output_hash and output_hash != record.get('binarySHA256'):
        gaps.append(f'{name}: build output hash differs from license manifest')
    return gaps


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check'])
    args = parser.parse_args()
    del args
    lock = json.loads(LOCK_PATH.read_text())
    manifest = json.loads(MANIFEST_PATH.read_text()) if MANIFEST_PATH.exists() else {}
    gaps = collect_gaps(lock, manifest)
    if gaps:
        print(summarize_gaps(gaps))
        raise SystemExit(1)
    print('Release license/provenance audit passed.')


if __name__ == '__main__':
    main()
