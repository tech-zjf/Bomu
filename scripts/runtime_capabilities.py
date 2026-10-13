#!/usr/bin/env python3
"""Inspect one FFmpeg format runtime per process to avoid dynamic-loader aliasing."""
from collections import Counter
import ctypes
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def inspect_runtime(directory):
    lock = json.loads((ROOT / 'Config/Dependencies.lock.json').read_text())
    loaded = {}

    def load(name):
        if name not in loaded:
            for dependency in lock['libraries'][name]['dependencies']:
                load(dependency)
            loaded[name] = ctypes.CDLL(str(directory / name), mode=ctypes.RTLD_GLOBAL)
        return loaded[name]

    library = load('libavformat.63.dylib')
    library.avformat_version.argtypes = []
    library.avformat_version.restype = ctypes.c_uint
    version = library.avformat_version()
    if version >> 16 != 63:
        raise ValueError('This inspector requires the pinned libavformat 63 public ABI')
    result = dict(version=version)
    for name in ['avformat_configuration', 'avformat_license']:
        function = getattr(library, name)
        function.argtypes = []
        function.restype = ctypes.c_char_p
        result[name] = function().decode('utf-8')
    # AVInputFormat 与 AVOutputFormat 的公开 ABI 都以 const char *name 开头。
    # 只读取该字段，不依据内部结构大小跨版本解析。
    for function_name, field in [('av_demuxer_iterate', 'demuxers'), ('av_muxer_iterate', 'muxers')]:
        function = getattr(library, function_name)
        function.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        function.restype = ctypes.POINTER(ctypes.c_char_p)
        opaque = ctypes.c_void_p()
        names = []
        while True:
            item = function(ctypes.byref(opaque))
            if not item:
                break
            names.append(item[0].decode('utf-8'))
        result[field] = sorted(names)
    library.avio_enum_protocols.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_int]
    library.avio_enum_protocols.restype = ctypes.c_char_p
    for output, field in [(0, 'inputProtocols'), (1, 'outputProtocols')]:
        opaque = ctypes.c_void_p()
        names = []
        while True:
            item = library.avio_enum_protocols(ctypes.byref(opaque), output)
            if item is None:
                break
            names.append(item.decode('utf-8'))
        result[field] = sorted(names)
    path = directory / 'libavformat.63.dylib'
    exported = subprocess.check_output(['nm', '-arch', 'arm64', '-gjU', str(path)], text=True)
    result['exports'] = sorted(exported.splitlines())
    return result


def compare_capabilities(reference, candidate):
    problems = []
    for field in ['version', 'avformat_license']:
        if reference.get(field) is None or candidate.get(field) != reference[field]:
            problems.append('Format runtime identity differs: ' + field)
    for field in ['demuxers', 'muxers', 'inputProtocols', 'outputProtocols', 'exports']:
        expected, actual = reference.get(field), candidate.get(field)
        if not isinstance(expected, list) or not isinstance(actual, list):
            problems.append('Missing capability inventory: ' + field)
            continue
        if (not expected or not all(isinstance(item, str) and item for item in expected + actual)):
            problems.append('Invalid capability inventory: ' + field)
            continue
        removed, added = Counter(expected) - Counter(actual), Counter(actual) - Counter(expected)
        if removed or added:
            problems.append(dict(field=field, removed=dict(removed), added=dict(added)))
    return problems


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: runtime_capabilities.py RUNTIME_DIRECTORY')
    print(json.dumps(inspect_runtime(Path(sys.argv[1]).resolve()), indent=2))
