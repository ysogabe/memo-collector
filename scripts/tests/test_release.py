"""Packaging boundary checks; no user Library, certificates or network required."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch, Mock

spec = importlib.util.spec_from_file_location('cc_release', Path(__file__).parents[1] / 'release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Context Capture.app'
        contents = self.app / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'MacOS/ContextCapture').touch()
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.ysogabe.ContextCapture',
            'CFBundleExecutable': 'ContextCapture',
        }))
        self.mock_run = patch.object(release, 'run').start()
        self.addCleanup(patch.stopall)

    def test_clean_bundle_checks_architecture_and_signature(self):
        release.check_payload(self.app)
        self.assertEqual(self.mock_run.call_count, 2)
        self.assertEqual(self.mock_run.call_args_list[0].args[:3], ('lipo', '-verify_arch', 'arm64'))
        self.assertIn('--strict', self.mock_run.call_args_list[1].args)

    def test_rejects_private_data_and_models(self):
        for name in ('personal.sqlite', 'personal.sqlite-wal', 'personal.sqlite.pre-index-v2-backup',
                     'personal.db-shm', 'secret.p12',
                     'capture.wav', 'capture.heic', 'model.safetensors', '.env.prod'):
            with self.subTest(name=name):
                item = self.app / 'Contents' / name
                item.touch()
                with self.assertRaisesRegex(RuntimeError, 'private data/model'):
                    release.check_payload(self.app)
                item.unlink()
        for name in ('Models', 'captures', 'encoder.mlmodelc'):
            with self.subTest(name=name):
                item = self.app / 'Contents' / name
                item.mkdir()
                with self.assertRaises(RuntimeError):
                    release.check_payload(self.app)
                item.rmdir()

    def test_rejects_external_links(self):
        (self.app / 'Contents/outside').symlink_to(Path(self.temp.name))
        with self.assertRaisesRegex(RuntimeError, 'escapes bundle'):
            release.check_payload(self.app)

    def test_allows_internal_framework_links(self):
        (self.app / 'Contents/link').symlink_to('MacOS/ContextCapture')
        release.check_payload(self.app)

    def test_rejects_wrong_app_and_missing_executable(self):
        executable = self.app / 'Contents/MacOS/ContextCapture'
        executable.unlink()
        with self.assertRaisesRegex(RuntimeError, 'Missing app executable'):
            release.check_payload(self.app)
        executable.touch()
        info = self.app / 'Contents/Info.plist'
        info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'other'}))
        with self.assertRaisesRegex(RuntimeError, 'Unexpected bundle identifier'):
            release.check_payload(self.app)


class SigningTests(unittest.TestCase):
    def test_preview_keeps_project_team_signing_by_default(self):
        # Ad-hoc signing pins the designated requirement to a per-build cdhash and breaks TCC grants.
        args = release.signing_args(preview=True)
        self.assertEqual(args, [])
        self.assertNotIn('CODE_SIGN_IDENTITY=-', args)

    def test_preview_adhoc_is_explicit(self):
        self.assertEqual(release.signing_args(preview=True, adhoc=True),
                         ['CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM='])

    def test_public_uses_developer_id_with_timestamp(self):
        identity = 'Developer ID Application: Example (TEAMID)'
        self.assertEqual(release.signing_args(preview=False, identity=identity),
                         [f'CODE_SIGN_IDENTITY={identity}', 'OTHER_CODE_SIGN_FLAGS=--timestamp'])


class NotarizationTests(unittest.TestCase):
    def test_accepted_status_is_required_even_if_command_exits_successfully(self):
        with patch.object(release, 'run', return_value=Mock(stdout='{}')):
            with self.assertRaisesRegex(RuntimeError, 'not accepted'):
                release.notarize(Path('app.zip'), 'profile')
        with patch.object(release, 'run', return_value=Mock(stdout='{"status":"Invalid","id":"test-id"}')):
            with self.assertRaisesRegex(RuntimeError, 'Invalid'):
                release.notarize(Path('app.zip'), 'profile')
        with patch.object(release, 'run', return_value=Mock(stdout='{"status":"Accepted"}')):
            release.notarize(Path('app.zip'), 'profile')


if __name__ == '__main__':
    unittest.main()
