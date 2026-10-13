"""Wrong generated media must fail before it can define playback expectations."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
SPEC = importlib.util.spec_from_file_location('media_suite',
    Path(__file__).resolve().parents[1] / 'scripts/generate-media-suite.py')
media_suite = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = media_suite
SPEC.loader.exec_module(media_suite)


class MediaSuiteTests(unittest.TestCase):
    def setUp(self):
        self.probe = {'format': {'duration': '6'}, 'streams': [
            {'codec_type': 'video', 'codec_name': 'h264', 'width': 960, 'height': 540,
             'pix_fmt': 'yuv420p', 'profile': 'High', 'avg_frame_rate': '30/1'},
            {'codec_type': 'audio', 'codec_name': 'aac', 'sample_rate': '48000', 'channels': 2}]}

    def test_rotation_requires_real_display_matrix(self):
        recipe = media_suite.Recipe('rotation.mp4', 'test', rotate=True)
        with self.assertRaisesRegex(ValueError, 'rotation metadata is missing'):
            media_suite.validate_recipe(recipe, self.probe)
        self.probe['streams'][0]['side_data_list'] = [{'rotation': 90}]
        media_suite.validate_recipe(recipe, self.probe)

    def test_main10_cannot_silently_become_eight_bit(self):
        recipe = media_suite.Recipe('main10.mp4', 'test', video='libx265', pixel_format='yuv420p10le', profile='main10')
        self.probe['streams'][0].update(codec_name='hevc', profile='Main 10')
        with self.assertRaisesRegex(ValueError, 'pixel format'):
            media_suite.validate_recipe(recipe, self.probe)

    def test_wrong_audio_channels_are_rejected(self):
        self.probe['streams'][1]['channels'] = 1
        with self.assertRaisesRegex(ValueError, 'audio format'):
            media_suite.validate_recipe(media_suite.Recipe('stereo.mp4', 'test'), self.probe)

    def test_second_audio_track_must_exist(self):
        recipe = media_suite.Recipe('dual.mkv', 'test', dual_audio=True)
        with self.assertRaisesRegex(ValueError, 'stream count'):
            media_suite.validate_recipe(recipe, self.probe)
        self.probe['streams'].append(deepcopy(self.probe['streams'][1]))
        media_suite.validate_recipe(recipe, self.probe)


if __name__ == '__main__':
    unittest.main()
