"""A moving clock cannot stand in for a correctly resumed video frame."""
from copy import deepcopy
import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
SPEC = importlib.util.spec_from_file_location('seek_candidate',
    Path(__file__).resolve().parents[1] / 'scripts/verify-seek-candidate.py')
candidate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(candidate)


class SeekCandidateTests(unittest.TestCase):
    def setUp(self):
        base = dict(frames=16, seeking=False, pause=True,
                    **{'eof-reached': False, 'vo-configured': True,
                       'time-pos': 0.52, 'audio-out-params/samplerate': 48000})
        self.samples = [dict(base, stage='before'), dict(stage='restart', elapsedMS=30),
                        dict(base, stage='paused-seek', frames=17, **{'time-pos': 3.02}),
                        dict(base, stage='resumed', frames=46, pause=False, **{'time-pos': 3.98})]

    def test_exact_seek_requires_paused_frame_and_resumed_frames(self):
        self.assertEqual(candidate.assess_measurements(self.samples, 3, True), [])
        self.samples[2]['frames'] = self.samples[0]['frames']
        self.assertIn('Seek or resume produced no new video frames',
                      candidate.assess_measurements(self.samples, 3, True))

    def test_resumed_clock_without_new_frames_is_rejected(self):
        self.samples[3]['frames'] = self.samples[2]['frames']
        self.assertIn('Seek or resume produced no new video frames',
                      candidate.assess_measurements(self.samples, 3, True))

    def test_later_keyframe_is_not_an_exact_seek(self):
        self.samples[2]['time-pos'] = 6.8
        self.samples[3]['time-pos'] = 7.8
        self.assertIn('Paused seek missed the target by more than 0.2 seconds',
                      candidate.assess_measurements(self.samples, 3, True))

    def test_unknown_and_nonfinite_position_do_not_pass(self):
        for invalid in [None, float('nan'), float('inf'), True]:
            with self.subTest(position=invalid):
                samples = deepcopy(self.samples)
                samples[2]['time-pos'] = invalid
                self.assertTrue(candidate.assess_measurements(samples, 3, True))

    def test_incomplete_or_reordered_measurements_are_rejected(self):
        self.assertTrue(candidate.assess_measurements(self.samples[:-1], 3, True))
        self.assertTrue(candidate.assess_measurements(list(reversed(self.samples)), 3, True))

    def test_lost_pause_intent_is_rejected(self):
        self.samples[2]['pause'] = False
        self.assertIn('Pause intent was not retained through the seek',
                      candidate.assess_measurements(self.samples, 3, True))

    def test_audio_only_requires_output_without_video_frames(self):
        for index in [0, 2, 3]:
            self.samples[index].update(frames=0, **{'vo-configured': False})
        self.assertEqual(candidate.assess_measurements(self.samples, 3, False), [])
        self.samples[3]['audio-out-params/samplerate'] = None
        self.assertTrue(candidate.assess_measurements(self.samples, 3, False))

    def test_ended_playback_does_not_pass_as_resume(self):
        self.samples[3]['eof-reached'] = True
        self.assertTrue(candidate.assess_measurements(self.samples, 3, True))


if __name__ == '__main__':
    unittest.main()
