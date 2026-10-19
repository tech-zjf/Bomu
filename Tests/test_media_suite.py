"""Wrong generated media must fail before it can define playback expectations."""
from copy import deepcopy
from dataclasses import replace
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

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

    def test_b11_has_sixty_unique_audio_and_video_cases_without_changing_a04(self):
        a04 = media_suite.recipes_for_suite('a04')
        b11 = media_suite.recipes_for_suite('b11')
        self.assertEqual(len(a04), 30)
        self.assertEqual(len(b11), 60)
        self.assertTrue(all(recipe.video and recipe.audio for recipe in b11))
        self.assertEqual(len({recipe.file for recipe in b11}), 60)

    def test_b11_rejects_duplicate_encoding_under_a_different_filename(self):
        recipes = list(media_suite.B11_ADDITIONAL_RECIPES)
        recipes[-1] = replace(recipes[0], file='renamed-duplicate.mp4', coverage='Different label')
        with patch.object(media_suite, 'B11_ADDITIONAL_RECIPES', recipes):
            with self.assertRaisesRegex(ValueError, 'duplicate encoding'):
                media_suite.recipes_for_suite('b11')

    def test_nonstandard_video_encoders_have_real_probe_mappings(self):
        cases = [
            (media_suite.Recipe('mpeg4.avi', 'test', size='640x480', rate='25',
                                video='mpeg4', profile=''), 'mpeg4', 'yuv420p'),
            (media_suite.Recipe('mpeg2.mpg', 'test', size='720x576', rate='25',
                                video='mpeg2video', profile=''), 'mpeg2video', 'yuv420p'),
            (media_suite.Recipe('prores.mov', 'test', size='1280x720', rate='25',
                                video='prores_ks', pixel_format='yuv422p10le', profile=''),
             'prores', 'yuv422p10le'),
        ]
        for recipe, codec, pixel_format in cases:
            with self.subTest(codec=codec):
                probe = deepcopy(self.probe)
                width, height = map(int, recipe.size.split('x'))
                probe['streams'][0].update(codec_name=codec, width=width, height=height,
                                           pix_fmt=pixel_format, profile='')
                probe['streams'][0]['avg_frame_rate'] = recipe.rate + '/1' if '/' not in recipe.rate else recipe.rate
                media_suite.validate_recipe(recipe, probe)


if __name__ == '__main__':
    unittest.main()
