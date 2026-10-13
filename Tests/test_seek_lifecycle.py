"""Reject stale native state and incomplete teardown in interleaved seek evidence."""
import importlib.util
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
SPEC = importlib.util.spec_from_file_location('seek_lifecycle',
    Path(__file__).resolve().parents[1] / 'scripts/verify-seek-lifecycle.py')
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)


class SeekLifecycleTests(unittest.TestCase):
    def setUp(self):
        def state(stage, frames, position, pause=True, **overrides):
            sample = dict(stage=stage, frames=frames, pause=pause, seeking=False, matchesFile=True,
                          commandErrors=0, lastReplyID=0, commandReplies=0,
                          **{'time-pos': position, 'eof-reached': False, 'vo-configured': True,
                             'idle-active': False, 'audio-out-params/samplerate': 48000})
            sample.update(overrides)
            return sample
        self.samples = []
        for index, target in enumerate(lifecycle.TARGETS):
            frames = index * 30 + 16
            self.samples += [dict(stage='case', name='sequential-' + str(index), target=target),
                             state('before', frames, 0.5), dict(stage='restart', elapsedMS=20),
                             state('paused-seek', frames + 1, target),
                             state('resumed', frames + 29, target + 0.9, pause=False)]
        self.samples += [state('burst-before', 136, 1.2),
                         state('burst-paused', 150, 3, lastReplyID=199, commandReplies=100),
                         state('burst-resumed', 180, 3.9, pause=False, commandReplies=100),
                         state('replacement-playing', 200, 0.55, pause=False, commandReplies=101),
                         state('replacement-stable', 215, 1.05, pause=False, commandReplies=101),
                         state('stopped', 218, None, commandReplies=102,
                               **{'idle-active': True, 'vo-configured': False}),
                         state('quiet', 218, None, commandReplies=102,
                               **{'idle-active': True, 'vo-configured': False}),
                         dict(stage='released', coreAlive=False, renderAlive=False,
                              threadAlive=False, elapsedMS=10)]

    def test_complete_ordered_native_sequence_passes(self):
        self.assertEqual(lifecycle.assess_lifecycle(self.samples), [])

    def test_old_file_after_replacement_is_rejected(self):
        self.samples[-5]['matchesFile'] = False
        self.assertIn('An old file remained active after replacement',
                      lifecycle.assess_lifecycle(self.samples))

    def test_stale_seek_on_replacement_is_rejected(self):
        self.samples[-4]['time-pos'] = 4.5
        self.assertIn('Replacement inherited a stale seek position',
                      lifecycle.assess_lifecycle(self.samples))

    def test_frame_activity_after_stop_is_rejected(self):
        self.samples[-2]['frames'] += 1
        self.assertIn('Video frames continued after stop', lifecycle.assess_lifecycle(self.samples))

    def test_incomplete_sequence_does_not_pass_with_successful_release(self):
        self.assertTrue(lifecycle.assess_lifecycle(self.samples[-1:]))
        self.assertTrue(lifecycle.assess_lifecycle(self.samples[:-1]))

    def test_unacknowledged_burst_and_lost_pause_are_rejected(self):
        self.samples[-7].update(lastReplyID=198, pause=False)
        failures = lifecycle.assess_lifecycle(self.samples)
        self.assertIn('The final queued seek was not acknowledged', failures)
        self.assertIn('Pause intent was not retained through the seek', failures)

    def test_native_command_failure_is_not_hidden_by_final_playing_state(self):
        self.samples[-4]['commandErrors'] = 1
        self.assertIn('An asynchronous native command failed', lifecycle.assess_lifecycle(self.samples))

    def test_last_reply_does_not_stand_in_for_every_burst_acknowledgement(self):
        self.samples[-7]['commandReplies'] = 99
        self.assertIn('The seek burst has outstanding command replies',
                      lifecycle.assess_lifecycle(self.samples))

    def test_unknown_or_invalid_teardown_does_not_pass(self):
        for key in ['coreAlive', 'renderAlive', 'threadAlive']:
            with self.subTest(resource=key):
                sample = dict(self.samples[-1])
                sample.pop(key)
                self.assertTrue(lifecycle.assess_release(sample))
        for value in [None, True, float('inf'), -1, 5001]:
            with self.subTest(elapsed=value):
                self.assertTrue(lifecycle.assess_release(dict(self.samples[-1], elapsedMS=value)))

    def test_opening_must_have_been_queued_before_teardown(self):
        self.assertEqual(lifecycle.assess_opening([dict(stage='opening-queued'), self.samples[-1]]), [])
        self.assertTrue(lifecycle.assess_opening([self.samples[-1]]))

    def test_unrelated_native_failure_is_not_a_reproduced_ts_defect(self):
        self.assertFalse(lifecycle.reproduces_missing_frames([]))
        self.assertFalse(lifecycle.reproduces_missing_frames(self.samples))
        self.samples[3]['frames'] = self.samples[1]['frames']
        self.samples[4]['frames'] = self.samples[1]['frames']
        self.assertTrue(lifecycle.reproduces_missing_frames(self.samples))
        self.samples[4]['eof-reached'] = True
        self.assertFalse(lifecycle.reproduces_missing_frames(self.samples))


if __name__ == '__main__':
    unittest.main()
