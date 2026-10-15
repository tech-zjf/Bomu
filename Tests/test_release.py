"""Release publishing must stop at each unmet trust boundary."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    'release', Path(__file__).resolve().parents[1] / 'scripts/release.py')
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_release_preflight_reports_independent_blockers_together(self):
        with patch.object(release, 'distribution_preflight_issues',
                          return_value=['license/provenance audit is incomplete']), \
                patch.object(release, 'developer_id_identities', return_value=[]):
            issues = release.release_preflight_issues(None, None)
        self.assertEqual(3, len(issues))
        self.assertIn('license/provenance audit', issues[0])
        self.assertIn('No valid Developer ID Application identity', issues[1])
        self.assertIn('BOMU_NOTARY_PROFILE', issues[2])

    def test_distribution_preflight_checks_every_independent_gate(self):
        from types import SimpleNamespace
        import json
        audit = SimpleNamespace(returncode=1, stdout='', stderr='missing project license')
        with patch.object(release.subprocess, 'run', return_value=audit), \
                patch.object(release, 'LOCK_PATH') as lock_path, \
                patch.object(release, 'run', side_effect=[
                    release.ReleaseError('wrong toolchain'), release.ReleaseError('runtime hash mismatch')
                ]):
            lock_path.read_text.return_value = json.dumps({
                'distributionReady': False, 'usage': 'development-poc-only'
            })
            issues = release.distribution_preflight_issues()
        self.assertEqual(4, len(issues))
        self.assertIn('missing project license', issues[0])
        self.assertIn('not approved for distribution', issues[1])
        self.assertIn('wrong toolchain', issues[2])
        self.assertIn('runtime hash mismatch', issues[3])

    def test_prerequisites_stop_when_license_audit_fails(self):
        with patch.object(release.subprocess, 'run', return_value=type('Result', (), {'returncode': 1})()) as run:
            with self.assertRaisesRegex(release.ReleaseError, 'license/provenance audit'):
                release.verify_distribution_prerequisites()
        self.assertEqual(1, run.call_count)

    def test_dependency_lock_must_explicitly_allow_distribution(self):
        with patch.object(release.subprocess, 'run', return_value=type('Result', (), {'returncode': 0})()), \
                patch.object(release, 'LOCK_PATH') as lock_path:
            import json
            lock_path.read_text.return_value = json.dumps({
                'distributionReady': False, 'usage': 'development-poc-only'})
            with self.assertRaisesRegex(release.ReleaseError, 'not approved for distribution'):
                release.verify_distribution_prerequisites()

    def test_ad_hoc_identity_is_not_accepted_as_distribution_identity(self):
        with patch.object(release, 'run', return_value='  1) ABCDEF "Apple Development: Example"\n'):
            with self.assertRaisesRegex(release.ReleaseError, 'Developer ID Application'):
                release.verify_identity('Apple Development: Example')

    def test_signing_identity_requires_an_exact_name_or_fingerprint(self):
        fingerprint = '0123456789ABCDEF0123456789ABCDEF01234567'
        name = 'Developer ID Application: Example Corp (TEAM123456)'
        listing = f'  1) {fingerprint} "{name}"\n     1 valid identities found\n'
        with patch.object(release, 'run', return_value=listing):
            with self.assertRaisesRegex(release.ReleaseError, 'exactly match'):
                release.verify_identity('Example Corp')
            release.verify_identity(name)
            release.verify_identity(fingerprint.lower())

    def test_release_requires_clean_git_working_tree(self):
        with patch.object(release, 'run', return_value='') as run:
            release.verify_source_tree_clean()
        self.assertIn('status', run.call_args.args[0])
        with patch.object(release, 'run', return_value=' M Sources/App/BomuApp.swift\n'):
            with self.assertRaisesRegex(release.ReleaseError, 'clean Git working tree'):
                release.verify_source_tree_clean()

    def test_release_checks_runtime_closure_before_signing(self):
        app = Path('/tmp/staging/Bomu.app')
        with patch.object(release, 'run') as run:
            release.verify_runtime_closure(app)
        arguments = run.call_args.args[0]
        self.assertEqual(str(release.ROOT / 'scripts/package_internal.py'), arguments[1])
        self.assertEqual(str(app), arguments[2])

    def test_app_signs_nested_libraries_before_the_bundle(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            app = Path(directory) / 'Bomu.app'
            frameworks = app / 'Contents/Frameworks'
            frameworks.mkdir(parents=True)
            (frameworks / 'libsample.dylib').touch()
            with patch.object(release, 'LOCK_PATH') as lock_path, \
                    patch.object(release, 'run', side_effect=[
                    '', '', '', '', 'Authority=Developer ID Application: Example\nflags=0x10000(runtime)']) as run:
                lock_path.read_text.return_value = '{"libraries":{"libsample.dylib":{}}}'
                release.sign_app(app, 'Developer ID Application: Example')
        calls = [call.args[0] for call in run.call_args_list]
        self.assertIn('libsample.dylib', calls[0][-1])
        self.assertIn('libsample.dylib', calls[1][-1])
        self.assertEqual(str(app), calls[2][-1])
        self.assertEqual(str(app), calls[3][-1])
        self.assertIn('-dv', calls[4])

    def test_app_signing_rejects_embedded_runtime_drift(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            app = Path(directory) / 'Bomu.app'
            frameworks = app / 'Contents/Frameworks'
            frameworks.mkdir(parents=True)
            with patch.object(release, 'LOCK_PATH') as lock_path, patch.object(release, 'run') as run:
                lock_path.read_text.return_value = '{"libraries":{"libexpected.dylib":{}}}'
                with self.assertRaisesRegex(release.ReleaseError, 'Embedded runtime differs'):
                    release.sign_app(app, 'Developer ID Application: Example')
        run.assert_not_called()

    def test_notarization_rejection_does_not_staple_or_pass(self):
        with patch.object(release, 'run', return_value='{"id":"submission-1","status":"Invalid"}') as run:
            with self.assertRaisesRegex(release.ReleaseError, 'not accepted'):
                release.submit_for_notarization(Path('/tmp/Bomu.dmg'), 'bomu-profile')
        self.assertEqual(1, run.call_count)

    def test_accepted_notarization_returns_its_submission_id(self):
        with patch.object(release, 'run', return_value='{"id":"submission-1","status":"Accepted"}') as run:
            result = release.submit_for_notarization(Path('/tmp/Bomu.zip'), 'bomu-profile')
        self.assertEqual({'id': 'submission-1', 'status': 'Accepted'}, result)
        self.assertEqual(1, run.call_count)
        self.assertIn('notarytool', run.call_args_list[0].args[0])

    def test_stapling_targets_the_supported_bundle_or_dmg(self):
        app = Path('/tmp/Bomu.app')
        with patch.object(release, 'run') as run:
            release.staple_and_validate(app)
        self.assertEqual(2, run.call_count)
        self.assertIn('staple', run.call_args_list[0].args[0])
        self.assertEqual(str(app), run.call_args_list[0].args[0][-1])
        self.assertIn('validate', run.call_args_list[1].args[0])

    def test_release_manifest_binds_artifacts_to_source_and_dependency_lock(self):
        import hashlib
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            app = Path(directory) / 'Bomu.app'
            executable = app / 'Contents/MacOS/Bomu'
            library = app / 'Contents/Frameworks/libsample.dylib'
            executable.parent.mkdir(parents=True)
            library.parent.mkdir(parents=True)
            executable.write_bytes(b'executable')
            library.write_bytes(b'runtime')
            dmg = Path(directory) / 'Bomu.dmg'
            dmg.write_bytes(b'disk image')
            with patch.object(release, 'LOCK_PATH') as lock_path, \
                    patch.object(release, 'run', side_effect=['abc123\n', '']):
                lock_path.read_bytes.return_value = b'{"lock":true}'
                manifest = release.release_manifest(
                    app, dmg, '0.2.0', 'Developer ID Application: Example',
                    {'id': 'app-id', 'status': 'Accepted'},
                    {'id': 'dmg-id', 'status': 'Accepted'})
        self.assertEqual('abc123', manifest['source']['revision'])
        self.assertTrue(manifest['source']['workingTreeClean'])
        self.assertEqual(hashlib.sha256(b'{"lock":true}').hexdigest(),
                         manifest['dependencyLockSHA256'])
        self.assertEqual(hashlib.sha256(b'executable').hexdigest(), manifest['executableSHA256'])
        self.assertEqual(hashlib.sha256(b'runtime').hexdigest(),
                         manifest['runtimeSHA256']['libsample.dylib'])
        self.assertEqual(hashlib.sha256(b'disk image').hexdigest(), manifest['sha256'])

    def test_release_manifest_records_a_dirty_source_tree(self):
        from tempfile import TemporaryDirectory
        with TemporaryDirectory() as directory:
            app = Path(directory) / 'Bomu.app'
            executable = app / 'Contents/MacOS/Bomu'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'executable')
            dmg = Path(directory) / 'Bomu.dmg'
            dmg.write_bytes(b'disk image')
            with patch.object(release, 'LOCK_PATH') as lock_path, \
                    patch.object(release, 'run', side_effect=['abc123\n', ' M Sources/App/BomuApp.swift\n']):
                lock_path.read_bytes.return_value = b'{}'
                manifest = release.release_manifest(app, dmg, '0.2.0', 'identity', {}, {})
        self.assertFalse(manifest['source']['workingTreeClean'])


if __name__ == '__main__':
    unittest.main()
