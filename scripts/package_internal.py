#!/usr/bin/env python3
"""Inspect the bundled runtime graph before creating an internal development DMG."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'Config/Dependencies.lock.json').read_text())


def output(arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout


def macho_files(app):
    candidates = [path for path in app.rglob('*') if path.is_file()]
    return [path for path in candidates if 'Mach-O' in output(['file', '-b', str(path)])]


def version_key(version):
    parts = tuple(int(part) for part in version.split('.'))
    if not parts or len(parts) > 3:
        raise ValueError(f'Invalid macOS version: {version}')
    return parts + (0,) * (3 - len(parts))


def verify_macos_deployment_target(load_commands, supported_target):
    versions = []
    blocks = re.split(r'(?=^Load command \d+$)', load_commands, flags=re.MULTILINE)
    for block in blocks:
        if re.search(r'^\s*cmd LC_BUILD_VERSION\s*$', block, re.MULTILINE):
            platform = re.search(r'^\s*platform (\S+)\s*$', block, re.MULTILINE)
            minimum = re.search(r'^\s*minos (\S+)\s*$', block, re.MULTILINE)
            if platform is None or platform.group(1) not in {'1', 'MACOS'}:
                raise ValueError('Mach-O does not target macOS.')
            if minimum is None:
                raise ValueError('Mach-O is missing its minimum OS version.')
            versions.append(minimum.group(1))
        elif re.search(r'^\s*cmd LC_VERSION_MIN_MACOSX\s*$', block, re.MULTILINE):
            minimum = re.search(r'^\s*version (\S+)\s*$', block, re.MULTILINE)
            if minimum is None:
                raise ValueError('Mach-O is missing its minimum macOS version.')
            versions.append(minimum.group(1))

    if not versions:
        raise ValueError('Mach-O has no macOS deployment version load command.')
    minimum = max(versions, key=version_key)
    if version_key(minimum) > version_key(supported_target):
        raise ValueError(f'Mach-O requires macOS {minimum}, above the declared minimum {supported_target}.')
    return minimum


def rpaths(binary):
    lines = output(['otool', '-l', str(binary)]).splitlines()
    result = []
    for index, line in enumerate(lines):
        if line.strip() == 'cmd LC_RPATH':
            match = re.match(r'\s*path (.+) \(offset \d+\)$', lines[index + 2])
            if match:
                result.append(match.group(1))
    return result


def expanded(path, loader_dir, executable_dir):
    if path == '@loader_path' or path.startswith('@loader_path/'):
        return loader_dir / path.removeprefix('@loader_path').lstrip('/')
    if path == '@executable_path' or path.startswith('@executable_path/'):
        return executable_dir / path.removeprefix('@executable_path').lstrip('/')
    if path.startswith('/'):
        return Path(path)
    return None


def is_bundled_file(path, contents):
    try:
        resolved_path = path.resolve(strict=True)
        resolved_contents = contents.resolve(strict=True)
    except OSError:
        return False
    return resolved_path.is_file() and resolved_path.is_relative_to(resolved_contents)


def resolve_rpath_dependency(dependency, loader_dir, executable_dir, loader_rpaths,
                             executable_rpaths, contents):
    tail = dependency.removeprefix('@rpath/')
    search_paths = []
    for runpath in loader_rpaths:
        base = expanded(runpath, loader_dir, executable_dir)
        if base is not None:
            search_paths.append(base / tail)
    for runpath in executable_rpaths:
        base = expanded(runpath, executable_dir, executable_dir)
        if base is not None:
            search_paths.append(base / tail)
    return next((candidate for candidate in search_paths
                 if is_bundled_file(candidate, contents)), None)


def verify_runtime(app):
    app = app.resolve()
    contents = app / 'Contents'
    frameworks = contents / 'Frameworks'
    executable_dir = contents / 'MacOS'
    main_executable = executable_dir / 'Bomu'
    if not main_executable.is_file():
        raise SystemExit(f'Missing app executable: {main_executable}')

    present = {path.name for path in frameworks.glob('*.dylib')}
    expected = set(LOCK['libraries'])
    if missing := expected - present:
        raise SystemExit(f'Missing locked runtime libraries: {sorted(missing)}')
    if unexpected := present - expected:
        raise SystemExit(f'Unexpected runtime libraries: {sorted(unexpected)}')

    errors = []
    executable_rpaths = rpaths(main_executable)
    for name in sorted(expected):
        if not is_bundled_file(frameworks / name, contents):
            errors.append(f'Contents/Frameworks/{name} is missing or resolves outside the app bundle')

    binaries = macho_files(contents)
    for binary in binaries:
        try:
            deployment = output(['otool', '-l', '-arch', 'arm64', str(binary)])
            verify_macos_deployment_target(deployment, LOCK['toolchain']['deploymentTarget'])
        except (subprocess.CalledProcessError, ValueError) as error:
            errors.append(f'{binary.relative_to(app)} -> minimum OS check failed: {error}')
        dependencies = output(['otool', '-arch', 'arm64', '-L', str(binary)]).splitlines()[1:]
        for line in dependencies:
            dependency = line.strip().split(' (compatibility version ', 1)[0]
            resolved = None
            if dependency.startswith('@rpath/'):
                resolved = resolve_rpath_dependency(
                    dependency, binary.parent, executable_dir, rpaths(binary),
                    executable_rpaths, contents)
            elif dependency.startswith('@loader_path'):
                candidate = expanded(dependency, binary.parent, executable_dir)
                resolved = candidate if candidate and is_bundled_file(candidate, contents) else None
            elif dependency.startswith('@executable_path'):
                candidate = expanded(dependency, binary.parent, executable_dir)
                resolved = candidate if candidate and is_bundled_file(candidate, contents) else None
            elif dependency.startswith(('/System/Library/', '/usr/lib/', '/System/Cryptexes/')):
                continue
            else:
                errors.append(f'{binary.relative_to(app)} -> unsupported external dependency {dependency}')
                continue
            if resolved is None:
                errors.append(f'{binary.relative_to(app)} -> unresolved bundled dependency {dependency}')
    if errors:
        raise SystemExit('Runtime dependency closure failed:\n' + '\n'.join(errors))
    print(f'Runtime closure verified: {len(expected)} locked dylibs, {len(binaries)} Mach-O images, '
          f'macOS {LOCK["toolchain"]["deploymentTarget"]} minimum')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    verify_runtime(args.app)


if __name__ == '__main__':
    main()
