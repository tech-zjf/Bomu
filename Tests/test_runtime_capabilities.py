"""Capability equality must compare identities and counts, not just totals."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from runtime_capabilities import compare_capabilities


class RuntimeCapabilityTests(unittest.TestCase):
    def setUp(self):
        self.reference = dict(version=0x3f0165, avformat_license='GPL version 2 or later',
            demuxers=['matroska,webm', 'mov,mp4'], muxers=['matroska', 'matroska', 'mp4'],
            inputProtocols=['file', 'https'], outputProtocols=['file', 'https'],
            exports=['_avformat_open_input', '_av_read_frame'])

    def test_inventory_order_is_not_a_capability_difference(self):
        candidate = deepcopy(self.reference)
        candidate['demuxers'].reverse()
        self.assertEqual(compare_capabilities(self.reference, candidate), [])

    def test_same_total_with_a_removed_protocol_fails(self):
        candidate = deepcopy(self.reference)
        candidate['inputProtocols'] = ['file', 'http']
        self.assertEqual(compare_capabilities(self.reference, candidate),
                         [dict(field='inputProtocols', removed={'https': 1}, added={'http': 1})])

    def test_shared_names_do_not_hide_removed_registrations(self):
        candidate = deepcopy(self.reference)
        candidate['muxers'].remove('matroska')
        self.assertTrue(compare_capabilities(self.reference, candidate))

    def test_version_exports_and_missing_evidence_are_checked(self):
        for field in ['version', 'avformat_license', 'exports', 'demuxers']:
            with self.subTest(field=field):
                candidate = deepcopy(self.reference)
                candidate.pop(field)
                self.assertTrue(compare_capabilities(self.reference, candidate))
        candidate = deepcopy(self.reference)
        candidate['exports'].pop()
        self.assertTrue(compare_capabilities(self.reference, candidate))

    def test_invalid_protocol_identity_is_rejected(self):
        for bad in [None, 1, '']:
            candidate = deepcopy(self.reference)
            candidate['inputProtocols'][0] = bad
            self.assertTrue(compare_capabilities(self.reference, candidate))


if __name__ == '__main__':
    unittest.main()
