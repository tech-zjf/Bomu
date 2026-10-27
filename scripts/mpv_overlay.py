#!/usr/bin/env python3
"""Build the fixed mpv render-fence overlay in an isolated directory.

This builder never replaces the dependency cache. Its caller owns staging and
must verify the output before atomically publishing a complete runtime set.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile

from ffmpeg_overlay import normalize_build_uuid
from mpv_overlay_headers import prepare_headers
import toolchain

ROOT = Path(__file__).resolve().parents[1]
INPUTS_PATH = ROOT / 'Tools/MPVOverlay/inputs.json'
INPUTS = json.loads(INPUTS_PATH.read_text())
CONFIGURE = [
    '-Dlibmpv=true', '-Dcplayer=false', '-Dmacos-cocoa-cb=disabled',
    '-Dmacos-touchbar=disabled', '-Dmacos-media-player=disabled',
    '-Dmanpage-build=disabled', '-Dtests=false', '-Dlua=luajit',
    '-Djavascript=enabled', '-Dlcms2=enabled', '-Dvulkan=disabled', '-Dgl=enabled',
    '-Dzimg=enabled', '-Dlibbluray=enabled', '-Dlibarchive=enabled',
    '-Duchardet=enabled', '-Djpeg=enabled', '-Drubberband=enabled',
    '-Dbuild-date=false', '-Dswift-flags=-target arm64-apple-macosx14.0',
    '-Dprefix=/bomu-runtime', '-Dbuildtype=release', '-Ddefault_library=shared',
    '-Dwrap_mode=nofallback', '-Dc_link_args=-Wl,-headerpad_max_install_names',
]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def definition():
    """The build inputs that must agree with the runtime lock before staging."""
    return {
        'version': INPUTS['sourceVersion'],
        'library': 'libmpv.2.dylib',
        'baseSHA256': INPUTS['baseLibrarySHA256'],
        'inputsFile': str(INPUTS_PATH.relative_to(ROOT)),
        'inputsSHA256': sha256(INPUTS_PATH),
        'builderFiles': {name: sha256(ROOT / name) for name in
                         ('scripts/mpv_overlay.py', 'scripts/mpv_overlay_headers.py',
                          'scripts/ffmpeg_overlay.py')},
        'configure': CONFIGURE,
        'normalizeBuildUUID': 'content-sha256-v1',
        'normalization': 'portable-rpath-relink; strip-S; content-UUID; ad-hoc libmpv.2',
    }


def verify_definition(locked, expected_output_hash):
    expected = definition()
    if any(locked.get(key) != value for key, value in expected.items()):
        raise ValueError('mpv overlay definition differs from its verified builder')
    if locked.get('librarySHA256') != expected_output_hash:
        raise ValueError('mpv overlay output hash differs from dependency lock')
    verify(ROOT / INPUTS['patch']['path'], INPUTS['patch']['sha256'])


def verify(path, expected):
    if not Path(path).is_file() or sha256(path) != expected:
        raise ValueError(f'Overlay input hash mismatch: {path}')


def cached_archive(record, cache):
    """Use only verified bytes, including after an interrupted download."""
    cache = Path(cache)
    archive = cache / record['filename']
    old_tool_cache = cache / 'mpv-build-tools' / record['filename']
    if not archive.exists() and old_tool_cache.is_file():
        verify(old_tool_cache, record['sha256'])
        return old_tool_cache
    if archive.exists():
        verify(archive, record['sha256'])
        return archive
    cache.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(prefix='mpv-input-', dir=cache, delete=False) as stream:
        partial = Path(stream.name)
    try:
        subprocess.run(['/usr/bin/curl', '--fail', '--location', '--retry', '2',
                        '--max-time', '180', record['url'], '-o', str(partial)],
                       check=True, timeout=200)
        verify(partial, record['sha256'])
        partial.replace(archive)
    finally:
        partial.unlink(missing_ok=True)
    return archive


def unpack(archive, destination):
    """Extract pinned source archives without allowing writes outside staging."""
    destination = Path(destination)
    destination.mkdir()
    with tarfile.open(archive) as source:
        source.extractall(destination, filter='data')
    roots = list(destination.iterdir())
    if len(roots) != 1 or not roots[0].is_dir():
        raise ValueError(f'Expected one source root in {archive}')
    return roots[0]


def run(arguments, *, cwd, env, log, timeout=300):
    """Own a build process group until success or bounded failure cleanup."""
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    previous_handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
    process = None
    succeeded = False
    with Path(log).open('a') as stream:
        try:
            for sig in previous_handlers:
                signal.signal(sig, interrupted)
            process = subprocess.Popen([str(x) for x in arguments], cwd=cwd, env=env,
                                       stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            code = process.wait(timeout=timeout)
            if code:
                raise subprocess.CalledProcessError(code, arguments)
            succeeded = True
        finally:
            try:
                if process is not None and not succeeded:
                    # Only descendants in the group we created are signalled.
                    # The leader can exit before a TERM-resistant compiler child.
                    for sig in (signal.SIGTERM, signal.SIGKILL):
                        try:
                            os.killpg(process.pid, sig)
                        except ProcessLookupError:
                            pass
                        try:
                            process.wait(timeout=1)
                        except subprocess.TimeoutExpired:
                            pass
                    process.wait(timeout=5)
            finally:
                for sig, handler in previous_handlers.items():
                    signal.signal(sig, handler)


def build_environment(output):
    # Do not inherit CFLAGS, SDKROOT, pkg-config or loader overrides from a shell.
    env = {key: os.environ[key] for key in
           ('HOME', 'TMPDIR', 'USER', 'LOGNAME', 'DEVELOPER_DIR') if key in os.environ}
    env.update(PATH=f'{output}/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin',
               LC_ALL='C', MACOSX_DEPLOYMENT_TARGET='14.0',
               CLANG_MODULE_CACHE_PATH=str(output / 'module-cache'),
               PKG_CONFIG=str(output / 'tools/bin/pkgconf'),
               PKG_CONFIG_LIBDIR=str(output / 'sysroot/lib/pkgconfig'),
               PKG_CONFIG_PATH='')
    return env


def prepare_tools(output, archives, sources, env):
    tools = output / 'tools'
    run([sys.executable, '-m', 'venv', tools], cwd=output, env=env,
        log=output / 'tools.log')
    run([tools / 'bin/python', '-m', 'pip', 'install', '--no-index', '--no-deps',
         archives['meson'], archives['ninja']], cwd=output, env=env,
        log=output / 'tools.log')
    # pkgconf embeds its prefix into C string defines without shell-safe spaces.
    # A fixed, unused prefix plus an explicit PKG_CONFIG_LIBDIR avoids that
    # upstream limitation; build only the static CLI and copy it into our tools.
    run([sources['pkgconf'] / 'configure', '--prefix=/bomu-build-tools',
         '--disable-shared', '--enable-static'], cwd=sources['pkgconf'], env=env,
        log=output / 'tools.log')
    run(['make', '-j4', 'pkgconf'], cwd=sources['pkgconf'], env=env,
        log=output / 'tools.log')
    shutil.copy2(sources['pkgconf'] / 'pkgconf', tools / 'bin/pkgconf')
    for name, expected in [('meson', '1.9.1'), ('pkgconf', '2.5.1')]:
        version = subprocess.check_output([tools / 'bin' / name, '--version'],
                                          env=env, text=True, timeout=10).strip()
        if version != expected:
            raise ValueError(f'Unexpected {name} version: {version}')


def portable_link(output, env):
    """Relink generated objects with runtime-relative paths before layout.

    Removing an absolute build rpath after linking leaves path-length-dependent
    layout. Preserve Meson's actual link arguments except those two search paths;
    no source, symbols or machine instructions are patched by this operation.
    """
    build = output / 'mpv-build'
    commands = subprocess.check_output(
        [output / 'tools/bin/ninja', '-C', build, '-t', 'commands', 'libmpv.2.dylib'],
        env=env, text=True, timeout=30).splitlines()
    arguments = shlex.split(commands[-1])
    if (arguments[0] not in ('cc', 'clang') or '-o' not in arguments
            or arguments[arguments.index('-o') + 1] != 'libmpv.2.dylib'
            or any(arg in ('&&', ';', '|', '>') for arg in arguments)):
        raise ValueError('Unexpected Meson library link command')
    rpath = '-Wl,-rpath,' + str(output / 'sysroot/lib')
    if arguments.count(rpath) != 1:
        raise ValueError('Expected exactly one isolated build rpath')
    arguments[arguments.index(rpath)] = '-Wl,-rpath,@loader_path'
    swift = toolchain.output(['/usr/bin/xcrun', '--find', 'swiftc'])
    swift_library = str(Path(swift).parent.parent / 'lib/swift/macosx')
    result = []
    index = 0
    removed = 0
    while index < len(arguments):
        if arguments[index:index + 4] == ['-Xlinker', '-rpath', '-Xlinker', swift_library]:
            index += 4
            removed += 1
            continue
        result.append(arguments[index])
        index += 1
    if removed != 1:
        raise ValueError('Expected one build-only Swift rpath')
    (output / 'portable-link-command.json').write_text(json.dumps(result, indent=2) + '\n')
    run(result, cwd=build, env=env, log=output / 'portable-link.log')
    library = output / 'libmpv.2.dylib'
    shutil.copyfile(build / library.name, library)
    run(['codesign', '--remove-signature', library], cwd=output, env=env,
        log=output / 'portable-link.log')
    run(['strip', '-S', library], cwd=output, env=env, log=output / 'portable-link.log')
    normalize_build_uuid(library)
    run(['codesign', '--force', '--sign', '-', '--identifier', 'libmpv.2', library],
        cwd=output, env=env, log=output / 'portable-link.log')
    return library


def build_library(output, libraries, *, cache=None):
    output = Path(output).resolve()
    libraries = Path(libraries).resolve()
    if sys.version_info < (3, 12) or platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('The overlay builder requires macOS arm64 and Python 3.12+')
    if not output.is_dir() or any(output.iterdir()):
        raise ValueError('Overlay output directory must exist and be empty')
    lock = json.loads((ROOT / 'Config/Dependencies.lock.json').read_text())
    actual_toolchain = toolchain.inspect_toolchain(os.environ)
    toolchain.verify_toolchain(lock['toolchain'], actual_toolchain)
    patch = ROOT / INPUTS['patch']['path']
    verify(patch, INPUTS['patch']['sha256'])
    # libmpv itself is never a link input; all other runtime bytes stay pinned.
    library_names = [name for name in lock['libraries'] if name != 'libmpv.2.dylib']
    for name in library_names:
        verify(libraries / name, lock['libraries'][name]['sha256'])
    archives = {name: cached_archive(record, cache or ROOT / '.build/downloads')
                for name, record in INPUTS['archives'].items()}
    sources_directory = output / 'sources'
    sources_directory.mkdir()
    sources = {name: unpack(archive, sources_directory / name)
               for name, archive in archives.items() if archive.suffix != '.whl'}
    env = build_environment(output)
    prepare_tools(output, archives, sources, env)
    run([sources['ffmpeg'] / 'configure',
         *INPUTS['headerConfiguration']['ffmpeg']['configure']],
        cwd=sources['ffmpeg'], env=env, log=output / 'headers.log')
    run(['make', 'libavutil/ffversion.h'], cwd=sources['ffmpeg'], env=env,
        log=output / 'headers.log')
    prepare_headers(output, sources, libraries, library_names, INPUTS['headerConfiguration'])
    run(['patch', '--batch', '--fuzz=0', '-p1', '-i', patch], cwd=sources['mpv'],
        env=env, log=output / 'patch.log')
    run([output / 'tools/bin/meson', 'setup', output / 'mpv-build', sources['mpv'], *CONFIGURE],
        cwd=output, env=env, log=output / 'configure.log')
    run([output / 'tools/bin/meson', 'compile', '-C', output / 'mpv-build', '-j', '4'],
        cwd=output, env=env, log=output / 'build.log', timeout=900)
    library = portable_link(output, env)
    report = {'inputsSHA256': sha256(INPUTS_PATH), 'patchSHA256': sha256(patch),
              'builderSHA256': sha256(Path(__file__)),
              'headerBuilderSHA256': sha256(ROOT / 'scripts/mpv_overlay_headers.py'),
              'toolchain': actual_toolchain, 'configure': CONFIGURE,
              'runtimeInputs': {name: sha256(libraries / name) for name in library_names},
              'outputSHA256': sha256(library)}
    (output / 'build-receipt.json').write_text(json.dumps(report, indent=2) + '\n')
    return library


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--libraries', type=Path, default=ROOT / '.build/dependencies/lib')
    args = parser.parse_args()
    library = build_library(args.output, args.libraries)
    print(f'Built isolated mpv overlay: {library} ({sha256(library)})')


if __name__ == '__main__':
    main()
