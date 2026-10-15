"""The release gate accepts only pinned sources with verified license evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('license_audit',
    Path(__file__).resolve().parents[1] / 'scripts/license_audit.py')
license_audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(license_audit)


class LicenseAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'licenses').mkdir()
        (self.root / 'licenses/project.txt').write_text('Project license')
        (self.root / 'licenses/component.txt').write_text('Component notice')
        (self.root / 'recipes').mkdir()
        (self.root / 'recipes/component.txt').write_text(json.dumps({
            'verificationStatus': {'status': 'verified'},
            'binaryMatch': {
                'workspaceBinarySHA256': 'binary-hash',
                'matchesReleaseArtifact': True,
            },
        }))
        (self.root / 'licenses/package.txt').write_text('Package license')
        self.lock = {
            'libraries': {'libsample.dylib': {'sha256': 'binary-hash'}},
            'swiftPackages': {'Package': {
                'license': 'MIT', 'url': 'https://example.invalid/package',
                'revision': 'abc123',
            }},
        }
        self.manifest = {
            'project': {
                'status': 'verified', 'licenseExpression': 'MIT',
                'licenseFile': 'licenses/project.txt',
                'licenseSHA256': self.digest('licenses/project.txt'),
            },
            'libraries': {'libsample.dylib': {
                'status': 'verified', 'licenseExpression': 'BSD-2-Clause',
                'binarySHA256': 'binary-hash',
                'copyright': 'Sample authors',
                'noticeFile': 'licenses/component.txt',
                'noticeSHA256': self.digest('licenses/component.txt'),
                'sourceURL': 'https://example.invalid/source',
                'sourceVersion': '1.2.3', 'sourceSHA256': 'a' * 64,
                'buildRecipeFile': 'recipes/component.txt',
                'buildRecipeSHA256': self.digest('recipes/component.txt'),
            }},
            'swiftPackages': {'Package': {
                'status': 'verified', 'licenseExpression': 'MIT',
                'noticeFile': 'licenses/package.txt',
                'noticeSHA256': self.digest('licenses/package.txt'),
                'sourceURL': 'https://example.invalid/package',
                'sourceRevision': 'abc123',
            }},
        }

    def digest(self, relative_path):
        return hashlib.sha256((self.root / relative_path).read_bytes()).hexdigest()

    def test_complete_pinned_evidence_passes(self):
        self.assertEqual([], license_audit.collect_gaps(self.lock, self.manifest, self.root))

    def test_current_unverified_distribution_reports_each_runtime_gap(self):
        current_lock = json.loads(license_audit.LOCK_PATH.read_text())
        manifest = {'project': {'status': 'unverified'}, 'libraries': {}, 'swiftPackages': {}}
        gaps = license_audit.collect_gaps(current_lock, manifest, self.root)
        self.assertTrue(any('Bomu project' in gap for gap in gaps))
        self.assertTrue(any('libavformat.63.dylib' in gap for gap in gaps))
        self.assertGreaterEqual(sum('verified component record' in gap for gap in gaps), 40)
        self.assertTrue(any('libavformat.63.dylib: sourceVersion' == gap for gap in gaps))
        self.assertTrue(any('libavformat.63.dylib: buildRecipeSHA256' == gap for gap in gaps))

    def test_gap_summary_groups_field_names_without_dropping_affected_components(self):
        gaps = [
            'liba.dylib: sourceURL',
            'libb.dylib: sourceURL',
            'libc.dylib: noticeSHA256',
        ]

        summary = license_audit.summarize_gaps(gaps)

        self.assertIn('3 evidence requirements remain', summary)
        self.assertIn('sourceURL (2): liba.dylib, libb.dylib', summary)
        self.assertIn('noticeSHA256 (1): libc.dylib', summary)

    def test_missing_package_notice_is_reported_once(self):
        manifest = {
            'project': self.manifest['project'],
            'libraries': self.manifest['libraries'],
            'swiftPackages': {},
        }

        gaps = license_audit.collect_gaps(self.lock, manifest, self.root)

        self.assertEqual(1, gaps.count('Package: noticeFile'))

    def test_source_checksum_must_be_sha256_formatted(self):
        self.manifest['libraries']['libsample.dylib']['sourceSHA256'] = 'verified-by-human'

        gaps = license_audit.collect_gaps(self.lock, self.manifest, self.root)

        self.assertIn(
            'libsample.dylib: source SHA-256 must contain 64 hexadecimal characters', gaps)

    def test_manifest_cannot_upgrade_a_recipe_that_records_an_unverified_binary(self):
        recipe = {
            'verificationStatus': {'status': 'unverified'},
            'binaryComparison': {
                'workspaceBinarySHA256': 'binary-hash',
                'canonicalContentMatch': False,
            },
        }
        path = self.root / 'recipes/component.txt'
        path.write_text(json.dumps(recipe))
        self.manifest['libraries']['libsample.dylib']['status'] = 'verified'
        self.manifest['libraries']['libsample.dylib']['buildRecipeSHA256'] = self.digest(
            'recipes/component.txt')

        gaps = license_audit.collect_gaps(self.lock, self.manifest, self.root)

        self.assertIn(
            'libsample.dylib: manifest status conflicts with build recipe', gaps)
        self.assertIn(
            'libsample.dylib: build recipe records a release artifact mismatch', gaps)

    def test_recipe_paths_cannot_escape_repository_when_digest_is_missing(self):
        record = self.manifest['libraries']['libsample.dylib']
        record['buildRecipeFile'] = '../outside.json'
        record['buildRecipeSHA256'] = None

        gaps = license_audit.collect_gaps(self.lock, self.manifest, self.root)

        self.assertIn('libsample.dylib: buildRecipeSHA256', gaps)
        self.assertIn('libsample.dylib: build recipe missing or hash mismatch', gaps)

    def test_ffmpeg_overlay_record_matches_checked_in_recipe_and_notices(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libavformat.63.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        overlay = current_lock['ffmpegOverlay']

        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual(current_lock['libraries'][name]['sha256'], record['binarySHA256'])
        self.assertEqual(overlay['sha256'], record['sourceSHA256'])
        self.assertEqual(overlay['librarySHA256'], recipe['output']['sha256'])
        self.assertEqual(overlay['patchSHA256'], recipe['patch']['sha256'])
        self.assertEqual('GPL-2.0-or-later', record['licenseExpression'])
        notice = (repository_root / record['noticeFile']).read_text()
        self.assertIn('GNU GENERAL PUBLIC LICENSE', notice)
        self.assertIn('CREDITS', notice)

    def test_ffmpeg_upstream_records_match_pinned_ci_artifact(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        names = {
            'libavcodec.63.dylib', 'libavdevice.63.dylib', 'libavfilter.12.dylib',
            'libavutil.61.dylib', 'libswresample.7.dylib', 'libswscale.10.dylib',
        }
        recipe_path = repository_root / 'ThirdParty/FFmpeg-upstream-build-recipe.json'
        recipe = json.loads(recipe_path.read_text())
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertEqual(names, set(recipe['components']))
        self.assertTrue(names <= current_manifest['libraries'].keys())
        self.assertEqual([], [gap for gap in gaps if any(gap.startswith(f'{name}:') for name in names)])
        self.assertEqual('f86d54276547df6d14104583ea604af67433f1e1',
                         recipe['buildSystem']['commit'])
        self.assertEqual(35411161790, recipe['buildSystem']['workflow']['successfulRunID'])
        self.assertEqual('cf38e0e28c7e5605942c4a77755349b0145804a397af37eb1fb4c77cb237f635',
                         recipe['source']['archiveSHA256'])
        for name in names:
            self.assertEqual(current_lock['libraries'][name]['sha256'],
                             recipe['binaryMatch']['components'][name]['workspaceBinarySHA256'])
            self.assertTrue(recipe['binaryMatch']['components'][name]['matchesReleaseArtifact'])

        for entry in ('versionsFile', 'workflow'):
            snapshot = repository_root / recipe['buildSystem'][entry]['localSnapshot']
            content = snapshot.read_bytes()
            git_blob = hashlib.sha1(f'blob {len(content)}\0'.encode() + content).hexdigest()
            self.assertEqual(recipe['buildSystem'][entry]['gitBlobSHA1'], git_blob)

    def test_dav1d_record_matches_pinned_iina_release_and_source_notice(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libdav1d.7.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)
        notice = (repository_root / record['noticeFile']).read_bytes()
        notice_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('BSD-2-Clause', record['licenseExpression'])
        self.assertEqual('8d4d6418c1ab4adf0a05bddfc11182216d5238a1', notice_blob)
        self.assertEqual('e099f53253f6c247580c554d53a13f1040638f2066edc3c740e4c2f15174ce22',
                         recipe['source']['archiveSHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])

    def test_libunibreak_record_preserves_custom_license_and_release_match(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libunibreak.7.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('LicenseRef-libunibreak', record['licenseExpression'])
        self.assertEqual('6b4137ca2158ffb57a112d54726dd11b6a2a06db', git_blob)
        self.assertEqual('8c9a6e121736cd0d5c890ae3ae96f3f4010a19aa040f1dbded833a62a87717d3',
                         recipe['source']['archiveSHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_liblz4_record_uses_library_license_and_pinned_release_match(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'liblz4.1.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('BSD-2-Clause', record['licenseExpression'])
        self.assertEqual('488491695a6b6984aa3a49a8392b192ed2bcac1d', git_blob)
        self.assertEqual('537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b',
                         recipe['source']['archiveSHA256'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_libogg_record_matches_pinned_source_ci_artifact_and_license_blob(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libogg.0.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('BSD-3-Clause', record['licenseExpression'])
        self.assertEqual('6111c6c5a6b95057e43d36b7c217b073bf5f9b22', git_blob)
        self.assertEqual('83e6704730683d004d20e21b8f7f55dcb3383cdf84c0daedf30bde175f774638',
                         recipe['source']['archiveSHA256'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_libwebp_family_records_share_exact_license_and_ci_artifact_evidence(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        names = {'libsharpyuv.0.dylib', 'libwebp.7.dylib', 'libwebpmux.3.dylib'}
        recipe_path = repository_root / 'ThirdParty/libwebp-build-recipe.json'
        recipe = json.loads(recipe_path.read_text())
        notice = (repository_root / 'ThirdParty/libwebp-COPYING.txt').read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertEqual(names, set(recipe['components']))
        self.assertFalse(any(any(gap.startswith(f'{name}:') for name in names) for gap in gaps), gaps)
        self.assertEqual('7a6f99547d4d6b4c5e6d5321acfaeba313e08de3', git_blob)
        self.assertEqual('e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564',
                         recipe['source']['archiveSHA256'])
        for name in names:
            record = current_manifest['libraries'][name]
            self.assertEqual('BSD-3-Clause', record['licenseExpression'])
            self.assertEqual(current_lock['libraries'][name]['sha256'],
                             recipe['binaryMatch']['components'][name]['workspaceBinarySHA256'])
            self.assertTrue(recipe['binaryMatch']['components'][name]['matchesReleaseArtifact'])

    def test_zstd_record_binds_exact_bsd_license_source_and_release_binary(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libzstd.1.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('BSD-3-Clause', record['licenseExpression'])
        self.assertEqual('75800288cc243f164b9d130f125e2ffae28f8e39', git_blob)
        self.assertEqual('37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3',
                         recipe['source']['archiveSHA256'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_libass_record_binds_isc_license_pinned_build_and_release_binary(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libass.9.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('ISC', record['licenseExpression'])
        self.assertEqual('3ff0e11457a6edccfab065cae0f905a6e1ed80ee', git_blob)
        self.assertEqual('2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc',
                         recipe['source']['archiveSHA256'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_speex_record_matches_pinned_source_bsd_notice_and_ci_artifact(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libspeex.1.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('BSD-3-Clause', record['licenseExpression'])
        self.assertEqual('7d6dc4aabd38f6e184028ff871744ac6b71b63ae', git_blob)
        self.assertEqual('4b44d4f2b38a370a2d98a78329fefc56a0cf93d1c1be70029217baae6628feea',
                         recipe['source']['archiveSHA256'])
        self.assertIn('--disable-ogg', recipe['buildSystem']['configureFlags'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_fribidi_record_binds_lgpl_source_authors_and_release_binary(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libfribidi.0.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        authors = (repository_root / recipe['sourceLicense']['authorsFile']['localSnapshot']).read_bytes()
        authors_blob = hashlib.sha1(f'blob {len(authors)}\0'.encode() + authors).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('LGPL-2.1-or-later', record['licenseExpression'])
        self.assertEqual('ae23fcfda2da8599b52baff4c257847205d78c56', git_blob)
        self.assertEqual('a47e0dc93650dfa93410a389b6eff84787e6d7cb', authors_blob)
        self.assertEqual('1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c',
                         recipe['source']['archiveSHA256'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_udfread_record_binds_tarball_copyright_lgpl_and_release_binary(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libudfread.3.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        git_blob = hashlib.sha1(f'blob {len(notice)}\0'.encode() + notice).hexdigest()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('LGPL-2.1-or-later', record['licenseExpression'])
        self.assertEqual('4362b49151d7b34ef83b3067a8f9c9f877d72a0e', git_blob)
        self.assertIn('GNU LESSER GENERAL PUBLIC LICENSE', notice.decode())
        self.assertEqual('bb477cbd4cfbfc7787d9d05b71ee5e70430f5cfebf1297497f7e83547958050f',
                         recipe['source']['archiveSHA256'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_bs2b_record_uses_exact_source_archive_license_and_build_transformations(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libbs2b.0.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_bytes()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('MIT', record['licenseExpression'])
        self.assertIn('Copyright (c) 2005 Boris Mikhaylov', notice.decode())
        self.assertEqual('6aaafd81aae3898ee40148dd1349aab348db9bfae9767d0e66e0b07ddd4b2528',
                         recipe['source']['archiveSHA256'])
        self.assertEqual('libbs2b-3.1.0/COPYING', recipe['source']['archiveEntry'])
        transformations = recipe['buildSystem']['sourceTransformations']
        self.assertEqual(4, len(transformations))
        self.assertIn('remove bin_PROGRAMS section', transformations[2]['operation'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_bluray_record_binds_lgpl_source_and_external_udfread_dependency(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libbluray.3.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        notice = (repository_root / record['noticeFile']).read_text()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('LGPL-2.1-or-later', record['licenseExpression'])
        self.assertIn('GNU LESSER GENERAL PUBLIC LICENSE', notice)
        self.assertEqual('76b5dc40097f28dca4ebb009c98ed51321b2927453f75cc72cf74acd09b9f449',
                         recipe['source']['archiveSHA256'])
        self.assertIn('libudfread >= 1.2.0', recipe['buildSystem']['externalDependencies'])
        self.assertEqual('not used; Meson resolves the separately pinned IINA dependency',
                         recipe['buildSystem']['bundledUdfreadBuild'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_vorbis_records_use_the_verified_release_artifact(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        report = json.loads((repository_root /
            'docs/engineering/distribution/iina-1.5.0-deps-comparison-2026-10-14.json').read_text())
        components = {item['name']: item for item in report['components']}

        for name in ('libvorbis.0.dylib', 'libvorbisenc.2.dylib'):
            with self.subTest(name=name):
                record = current_manifest['libraries'][name]
                recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
                gaps = license_audit.collect_gaps(
                    current_lock, current_manifest, repository_root)
                component_gaps = [gap for gap in gaps if gap.startswith(f'{name}:')]
                self.assertEqual([], component_gaps)
                self.assertEqual('verified', record['status'])
                self.assertEqual('BSD-3-Clause', record['licenseExpression'])
                self.assertEqual('1.3.7', recipe['source']['version'])
                self.assertEqual(current_lock['libraries'][name]['sha256'],
                                 recipe['binaryMatch']['workspaceBinarySHA256'])
                self.assertFalse(recipe['binaryMatch']['matchesVersionedIINAEndpoint'])
                self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
                self.assertEqual(
                    components[name]['depsBuildscriptsFatRelease']['referenceCanonicalSHA256'],
                    recipe['binaryMatch']['releaseArtifactCanonicalArm64SHA256'])
                self.assertEqual('verified', recipe['verificationStatus']['status'])
                self.assertEqual(recipe['releaseArtifact']['sha256'],
                                 current_lock['verifiedRuntimeArtifact']['sha256'])

    def test_font_rendering_stack_records_pinned_notices_and_release_binaries(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())

        for name in ('libfontconfig.1.dylib', 'libfreetype.6.dylib', 'libharfbuzz.0.dylib'):
            with self.subTest(name=name):
                record = current_manifest['libraries'][name]
                recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
                notice = (repository_root / record['noticeFile']).read_bytes()
                script_snapshot = (repository_root /
                    recipe['buildSystem']['buildScript']['localSnapshot']).read_bytes()
                gaps = license_audit.collect_gaps(
                    current_lock, current_manifest, repository_root)

                self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
                self.assertEqual(hashlib.sha256(notice).hexdigest(), record['noticeSHA256'])
                self.assertEqual(hashlib.sha1(
                    f'blob {len(script_snapshot)}\0'.encode() + script_snapshot).hexdigest(),
                    recipe['buildSystem']['buildScript']['gitBlobSHA1'])
                self.assertEqual(current_lock['libraries'][name]['sha256'],
                                 recipe['binaryMatch']['workspaceBinarySHA256'])
                self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
                self.assertEqual(record['licenseExpression'], recipe['sourceLicense']['spdx'])

        freetype = json.loads((repository_root /
            current_manifest['libraries']['libfreetype.6.dylib']['buildRecipeFile']).read_text())
        self.assertIn('--without-harfbuzz', freetype['buildSystem']['configureFlags'])
        self.assertIn('FreeType License', freetype['buildSystem']['licenseNotes'][0])

    def test_lcms_record_uses_mit_source_and_disables_unused_formats(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'liblcms2.2.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('MIT', record['licenseExpression'])
        self.assertEqual('49e7e134e4299733dd0eda434fa468997a28ab3d33fa397c642b03644f552216',
                         recipe['source']['archiveSHA256'])
        flags = recipe['buildSystem']['configureFlags']
        self.assertIn('--without-jpeg', flags)
        self.assertIn('--without-tiff', flags)
        self.assertIn('--without-zlib', flags)
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])

    def test_mujs_and_zimg_keep_exact_licenses_and_source_transformations(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        expected = {
            'libmujs.dylib': ('ISC', '956d5a20dd4efe5aa58673558787b9e2539255f9bf62585e90e1921fa040d89d'),
            'libzimg.2.dylib': ('WTFPL', 'be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577'),
        }

        for name, (license_id, source_hash) in expected.items():
            with self.subTest(name=name):
                record = current_manifest['libraries'][name]
                recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
                gaps = license_audit.collect_gaps(
                    current_lock, current_manifest, repository_root)
                self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
                self.assertEqual(license_id, record['licenseExpression'])
                self.assertEqual(source_hash, recipe['source']['archiveSHA256'])
                self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
                self.assertTrue(recipe['buildSystem']['sourceTransformations'])

        zimg = json.loads((repository_root /
            current_manifest['libraries']['libzimg.2.dylib']['buildRecipeFile']).read_text())
        self.assertIn('autogen.sh', zimg['buildSystem']['sourceTransformations'][0])

    def test_soxr_and_uchardet_preserve_selected_library_licenses(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        expected = {
            'libsoxr.0.dylib': ('LGPL-2.1-or-later', 'b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889'),
            'libuchardet.0.dylib': ('MPL-1.1', 'e97a60cfc00a1c147a674b097bb1422abd9fa78a2d9ce3f3fdcc2e78a34ac5f0'),
        }

        for name, (license_id, source_hash) in expected.items():
            with self.subTest(name=name):
                record = current_manifest['libraries'][name]
                recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
                notice = (repository_root / record['noticeFile']).read_bytes()
                gaps = license_audit.collect_gaps(
                    current_lock, current_manifest, repository_root)
                self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
                self.assertEqual(license_id, record['licenseExpression'])
                self.assertEqual(source_hash, recipe['source']['archiveSHA256'])
                self.assertEqual(hashlib.sha256(notice).hexdigest(), record['noticeSHA256'])
                self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
                self.assertTrue(recipe['source']['licenseArchiveEntries'])

    def test_libarchive_notice_covers_compiled_license_exceptions(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libarchive.13.dylib'
        record = current_manifest['libraries'][name]
        recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
        files = recipe['sourceLicense']['files']
        notice = (repository_root / record['noticeFile']).read_bytes()
        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)

        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
        self.assertEqual('BSD-2-Clause AND BSD-3-Clause AND CC0-1.0',
                         record['licenseExpression'])
        self.assertIn('UC Regents', notice.decode())
        self.assertIn('CC0 1.0 Universal', notice.decode())
        self.assertIn('-DENABLE_LIBB2=OFF', recipe['buildSystem']['cmakeOptions'])
        self.assertTrue(any('archive_read_support_filter_compress.c' in f['source']
                            for f in files))
        for file in files:
            contents = (repository_root / file['path']).read_bytes()
            self.assertEqual(file['sha256'], hashlib.sha256(contents).hexdigest())

    def test_luajit_and_rubberband_records_bind_source_license_and_build_mode(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        expected = {
            'libluajit-5.1.2.dylib': ('MIT', '9c4c370559352e0622231d5a1f28e95ff56e2dce6308238e6588b0943aac5e63'),
            'librubberband.3.dylib': ('GPL-2.0-only', 'af050313ee63bc18b35b2e064e5dce05b276aaf6d1aa2b8a82ced1fe2f8028e9'),
        }

        for name, (license_id, source_hash) in expected.items():
            with self.subTest(name=name):
                record = current_manifest['libraries'][name]
                recipe = json.loads((repository_root / record['buildRecipeFile']).read_text())
                notice = (repository_root / record['noticeFile']).read_text()
                gaps = license_audit.collect_gaps(
                    current_lock, current_manifest, repository_root)
                self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
                self.assertEqual(license_id, record['licenseExpression'])
                self.assertEqual(source_hash, recipe['source']['archiveSHA256'])
                self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
                self.assertTrue(notice.strip())

        luajit = (repository_root / current_manifest[
            'libraries']['libluajit-5.1.2.dylib']['noticeFile']).read_text()
        rubberband = json.loads((repository_root /
            current_manifest['libraries']['librubberband.3.dylib']['buildRecipeFile']).read_text())
        self.assertIn('Copyright (C) 1994-2012 Lua.org, PUC-Rio.', luajit)
        self.assertIn('-Dfft=vdsp', rubberband['buildSystem']['buildOptions'])
        self.assertIn('-Dresampler=builtin', rubberband['buildSystem']['buildOptions'])

    def test_jxl_and_brotli_records_bind_recursive_source_and_bundled_licenses(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        recipe_path = repository_root / 'ThirdParty/libjxl-build-recipe.json'
        recipe = json.loads(recipe_path.read_text())
        closure = recipe['sourceClosure']
        canonical_closure = json.dumps(
            closure, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
        self.assertEqual(recipe['sourceClosureSHA256'], hashlib.sha256(canonical_closure).hexdigest())
        submodules = {item['path']: item['commit'] for item in closure['submodules']}
        self.assertEqual('36533a866ed1ca4b75cf049f4521e4ec5fe24727',
                         submodules['third_party/brotli'])
        self.assertEqual('457c891775a7397bdb0376bb1031e6e027af1c48',
                         submodules['third_party/highway'])
        self.assertIn('SKCMS disabled', recipe['buildSystem']['submoduleBuildFacts'][2])

        expressions = {
            'libjxl.0.11.dylib': 'BSD-3-Clause AND Apache-2.0',
            'libjxl_cms.0.11.dylib': 'BSD-3-Clause AND MIT',
            'libjxl_threads.0.11.dylib': 'BSD-3-Clause',
            'libbrotlicommon.1.dylib': 'MIT',
            'libbrotlidec.1.dylib': 'MIT',
            'libbrotlienc.1.dylib': 'MIT',
        }
        for name, license_id in expressions.items():
            with self.subTest(name=name):
                record = current_manifest['libraries'][name]
                component = recipe['binaryMatch']['components'][name]
                gaps = license_audit.collect_gaps(
                    current_lock, current_manifest, repository_root)
                self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
                self.assertEqual('verified', record['status'])
                self.assertEqual(license_id, record['licenseExpression'])
                self.assertEqual(recipe['sourceClosureSHA256'], record['sourceSHA256'])
                self.assertEqual(current_lock['libraries'][name]['sha256'],
                                 component['workspaceBinarySHA256'])
                self.assertTrue(component['matchesReleaseArtifact'])
                self.assertIn(name, recipe['components'])

    def test_libplacebo_record_binds_recursive_source_gl_loader_and_linked_code(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        name = 'libplacebo.360.dylib'
        record = current_manifest['libraries'][name]
        recipe_path = repository_root / record['buildRecipeFile']
        recipe = json.loads(recipe_path.read_text())
        closure = recipe['sourceClosure']
        canonical_closure = json.dumps(
            closure, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
        self.assertEqual(recipe['sourceClosureSHA256'], hashlib.sha256(canonical_closure).hexdigest())
        self.assertEqual('cee9b076f2c63104ccfd497fa79c39a867293ec4', closure['commit'])
        submodules = {item['path']: item['commit'] for item in closure['submodules']}
        self.assertEqual('73db193f853e2ee079bf3ca8a64aa2eaf6459043',
                         submodules['3rdparty/glad'])
        self.assertEqual('97b54ca9e75f5303507699d27c6b4f4efe4641a1',
                         submodules['3rdparty/fast_float'])

        gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)
        self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
        self.assertEqual('verified', record['status'])
        self.assertEqual(recipe['sourceClosureSHA256'], record['sourceSHA256'])
        self.assertEqual(current_lock['libraries'][name]['sha256'],
                         recipe['binaryMatch']['workspaceBinarySHA256'])
        self.assertTrue(recipe['binaryMatch']['matchesReleaseArtifact'])
        self.assertIn('-Dopengl=enabled', recipe['buildSystem']['mesonOptions'])
        self.assertIn('-Dvulkan=disabled', recipe['buildSystem']['mesonOptions'])
        self.assertIn('Khronos EGL headers', recipe['sourceLicenses'])

        for evidence in recipe['noticeFiles'].values():
            path = repository_root / evidence['path']
            self.assertEqual(evidence['sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
        script = repository_root / recipe['buildSystem']['buildScript']['localSnapshot']
        content = script.read_bytes()
        git_blob = hashlib.sha1(f'blob {len(content)}\0'.encode() + content).hexdigest()
        self.assertEqual(recipe['buildSystem']['buildScript']['gitBlobSHA1'], git_blob)

    def test_iina_release_binary_adoption_keeps_sources_and_verifies_exact_assets(self):
        repository_root = license_audit.ROOT
        current_lock = json.loads((repository_root / 'Config/Dependencies.lock.json').read_text())
        current_manifest = json.loads(
            (repository_root / 'Config/ThirdPartyLicenses.json').read_text())
        versions = (repository_root /
                    'docs/engineering/distribution/iina-deps-buildscripts-f86d542-versions.env').read_text()
        expected = {
            'libSvtAv1Enc.4.dylib': ('svt-av1', 'SVT_AV1_SHA256',
                                     'BSD-2-Clause AND BSD-3-Clause-Clear', '2b72f9d1714dc6bff530c0cdfc5d3ba15cd2a1ac'),
            'libjpeg.62.dylib': ('jpeg-turbo', 'JPEG_TURBO_SHA256',
                                 'LicenseRef-IJG', '3cded44d22e3010ec1cf9c0412f6821fe61241d0'),
            'libmpv.2.dylib': ('mpv', 'MPV_SHA256',
                               'GPL-2.0-or-later', 'a7c21ab44d15705d659ea18e511777123a664aa7'),
        }
        for name, (recipe_name, version_key, expression, script_blob) in expected.items():
            with self.subTest(name=name):
                record = current_manifest['libraries'][name]
                recipe_path = repository_root / record['buildRecipeFile']
                recipe = json.loads(recipe_path.read_text())
                source = recipe['source']
                notice = (repository_root / record['noticeFile']).read_bytes()
                script = (repository_root /
                          recipe['buildSystem']['buildScript']['localSnapshot']).read_bytes()
                common = (repository_root /
                          recipe['buildSystem']['sharedBuildScript']['localSnapshot']).read_bytes()
                script_git_blob = hashlib.sha1(f'blob {len(script)}\0'.encode() + script).hexdigest()
                common_git_blob = hashlib.sha1(f'blob {len(common)}\0'.encode() + common).hexdigest()
                gaps = license_audit.collect_gaps(current_lock, current_manifest, repository_root)
                binary = recipe['binaryComparison']
                artifact = current_lock['verifiedRuntimeArtifact']

                self.assertEqual('verified', record['status'])
                self.assertEqual(expression, record['licenseExpression'])
                self.assertEqual(current_lock['libraries'][name]['sha256'], record['binarySHA256'])
                self.assertEqual(source['archiveSHA256'], record['sourceSHA256'])
                self.assertIn(f'{version_key}="{source["archiveSHA256"]}"', versions)
                self.assertEqual(hashlib.sha256(notice).hexdigest(), record['noticeSHA256'])
                self.assertEqual(script_blob, script_git_blob)
                self.assertEqual(recipe['buildSystem']['sharedBuildScript']['gitBlobSHA1'],
                                 common_git_blob)
                self.assertTrue(binary['canonicalContentMatch'])
                self.assertFalse(binary['versionedIINAEndpointArm64Match'])
                self.assertEqual('verified', binary['verificationStatus'])
                self.assertEqual(artifact['sha256'], recipe['releaseArtifact']['sha256'])
                self.assertEqual(artifact['workflowRunID'], recipe['releaseArtifact']['workflowRunID'])
                self.assertFalse(any(gap.startswith(f'{name}:') for gap in gaps), gaps)
                self.assertEqual(recipe['sourceLicense']['expression'], expression)
        mpv = json.loads((repository_root /
            current_manifest['libraries']['libmpv.2.dylib']['buildRecipeFile']).read_text())
        self.assertIn('-Dgpl=true (Meson default; not overridden)', mpv['buildSystem']['buildOptions'])
        jpeg = json.loads((repository_root /
            current_manifest['libraries']['libjpeg.62.dylib']['buildRecipeFile']).read_text())
        self.assertIn('-DWITH_TURBOJPEG=OFF', jpeg['buildSystem']['buildOptions'])

    def test_notice_or_pinned_package_revision_mismatch_fails_closed(self):
        self.manifest['libraries']['libsample.dylib']['noticeSHA256'] = 'wrong-hash'
        self.manifest['libraries']['libsample.dylib']['binarySHA256'] = 'wrong-binary-hash'
        self.manifest['swiftPackages']['Package']['sourceRevision'] = 'different'
        gaps = license_audit.collect_gaps(self.lock, self.manifest, self.root)
        self.assertIn('libsample.dylib: notice missing or hash mismatch', gaps)
        self.assertIn('libsample.dylib: binary hash differs from dependency lock', gaps)
        self.assertIn('Package: source revision differs from dependency lock', gaps)

    def test_notice_paths_cannot_escape_repository_and_stale_records_are_rejected(self):
        self.manifest['libraries']['libsample.dylib']['noticeFile'] = '../../outside-license.txt'
        self.manifest['swiftPackages']['StalePackage'] = {'status': 'verified'}
        gaps = license_audit.collect_gaps(self.lock, self.manifest, self.root)
        self.assertIn('libsample.dylib: notice missing or hash mismatch', gaps)
        self.assertIn('StalePackage: record is not present in the Swift package lock', gaps)


if __name__ == '__main__':
    unittest.main()
