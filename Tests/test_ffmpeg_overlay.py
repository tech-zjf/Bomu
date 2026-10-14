import hashlib
import importlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
ffmpeg_overlay = importlib.import_module('ffmpeg_overlay')


class FFmpegOverlayTests(unittest.TestCase):
    def test_dependency_lock_matches_the_overlay_builder(self):
        lock = json.loads((ROOT / 'Config/Dependencies.lock.json').read_text())
        overlay = lock['ffmpegOverlay']
        self.assertEqual(overlay['url'], ffmpeg_overlay.SOURCE_URL)
        self.assertEqual(overlay['sha256'], ffmpeg_overlay.SOURCE_SHA256)
        self.assertEqual(overlay['configure'], ffmpeg_overlay.CONFIGURE)
        self.assertEqual(overlay['patchSHA256'], ffmpeg_overlay.sha256(ffmpeg_overlay.PATCH))
        self.assertEqual(overlay['normalizeBuildUUID'], 'content-sha256-v1')
        self.assertEqual(lock['libraries'][overlay['library']]['sha256'], overlay['librarySHA256'])

    def test_content_derived_uuid_normalizes_linker_randomness(self):
        binaries = []
        with tempfile.TemporaryDirectory() as directory:
            for index, seed in enumerate((b'first-linker-uuid', b'second-linker-uuid')):
                data = bytearray(32 + 24 + 32)
                struct.pack_into('<IiiIIIII', data, 0, 0xFEEDFACF, 0x0100000C, 0, 6, 1, 24, 0, 0)
                struct.pack_into('<II', data, 32, 0x1B, 24)
                data[40:56] = hashlib.sha256(seed).digest()[:16]
                data[56:] = b'same-mach-o-payload-0123456789'
                path = Path(directory) / f'library-{index}.dylib'
                path.write_bytes(data)
                ffmpeg_overlay.normalize_build_uuid(path)
                binaries.append(path.read_bytes())
        self.assertEqual(binaries[0], binaries[1])
        stable_uuid = binaries[0][40:56]
        self.assertEqual(stable_uuid[6] >> 4, 5)
        self.assertEqual(stable_uuid[8] >> 6, 2)


if __name__ == '__main__':
    unittest.main()
