#!/usr/bin/env python3
"""Reproducibly build the pinned development FFmpeg format-library overlay."""
import hashlib
from pathlib import Path
import subprocess
import struct
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE_VERSION = '9.0.1'
SOURCE_URL = 'https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz'
SOURCE_SHA256 = 'cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635'
PATCH = ROOT / 'Tools/SeekProbe/ffmpeg-9.0.1-ts-keyframes.patch'
CONFIGURE = [
    '--enable-shared', '--disable-static', '--disable-autodetect', '--disable-doc',
    '--disable-debug', '--disable-programs', '--disable-encoders',
    '--disable-avfilter', '--disable-avdevice', '--disable-swscale', '--disable-swresample',
    '--install-name-dir=@rpath', '--arch=arm64', '--target-os=darwin',
    '--extra-cflags=-mmacosx-version-min=14.0', '--extra-ldflags=-mmacosx-version-min=14.0',
    '--cc=xcrun clang', '--enable-gpl', '--enable-bzlib', '--enable-zlib', '--enable-iconv',
    '--enable-securetransport', '--extra-libs=-liconv',
]


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def source_archive(root=ROOT):
    archive = root / '.build/downloads' / f'ffmpeg-{SOURCE_VERSION}.tar.xz'
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        partial = archive.with_suffix('.download')
        subprocess.run(['curl', '--fail', '--location', '--retry', '2', SOURCE_URL,
                        '-o', str(partial)], check=True, timeout=180)
        if sha256(partial) != SOURCE_SHA256:
            raise ValueError('FFmpeg source checksum mismatch')
        partial.replace(archive)
    if sha256(archive) != SOURCE_SHA256:
        raise ValueError('FFmpeg source checksum mismatch')
    return archive


def normalize_build_uuid(library):
    """Replace ld64's random arm64 LC_UUID with a content-derived stable UUID."""
    library = Path(library)
    data = bytearray(library.read_bytes())
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected a 64-bit little-endian Mach-O library')
    command_count = struct.unpack_from('<I', data, 16)[0]
    offset = 32
    uuid_range = None
    for _ in range(command_count):
        if offset + 8 > len(data):
            raise ValueError('Truncated Mach-O load command')
        command, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError('Invalid Mach-O load command size')
        if command == 0x1B:
            if size != 24 or uuid_range is not None:
                raise ValueError('Unexpected Mach-O UUID command')
            uuid_range = (offset + 8, offset + 24)
        offset += size
    if uuid_range is None:
        raise ValueError('Mach-O library has no LC_UUID')
    start, end = uuid_range
    data[start:end] = bytes(end - start)
    stable_uuid = bytearray(hashlib.sha256(data).digest()[:16])
    stable_uuid[6] = (stable_uuid[6] & 0x0F) | 0x50
    stable_uuid[8] = (stable_uuid[8] & 0x3F) | 0x80
    data[start:end] = stable_uuid
    library.write_bytes(data)


def build_library(output, archive=None):
    """Build only libavformat in an existing empty, isolated output directory."""
    output = Path(output).resolve()
    if any(output.iterdir()):
        raise ValueError('FFmpeg overlay build directory must be empty')
    archive = archive or source_archive()
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            destination = (output / member.name).resolve()
            if not destination.is_relative_to(output) or member.issym() or member.islnk():
                raise ValueError('Unsupported FFmpeg archive member')
        source.extractall(output)
    source = output / f'ffmpeg-{SOURCE_VERSION}'
    with (output / 'patch.log').open('w') as log:
        subprocess.run(['patch', '--batch', '--fuzz=0', '-p1', '-i', PATCH], cwd=source,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    with (output / 'configure.log').open('w') as log:
        subprocess.run([source / 'configure', *CONFIGURE], cwd=source,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
    with (output / 'build.log').open('w') as log:
        subprocess.run(['make', '-j4', 'libavformat/libavformat.63.dylib'], cwd=source,
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
    library = source / 'libavformat/libavformat.63.dylib'
    if not library.is_file():
        raise FileNotFoundError('FFmpeg build did not produce libavformat.63.dylib')
    normalize_build_uuid(library)
    return library
