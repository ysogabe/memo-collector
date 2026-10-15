"""Maintenance CLI contract; authored SQLite fixtures only, no production data/models."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get('CC_INTENT_EVAL_BINARY'), 'built cc-models required')
class IntentReprocessingCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.data = self.root / 'data'
        self.data.mkdir()
        self.db = self.data / 'ContextCapture.sqlite'
        self.models = self.root / 'models-absent'
        self.backup = self.root / 'backup.sqlite'
        self.output = self.root / 'report.json'
        self.binary = os.environ['CC_INTENT_EVAL_BINARY']

    def tearDown(self):
        self.tmp.cleanup()

    def cli(self, *args):
        env = dict(os.environ, CC_DATA_DIR=str(self.data), CC_MODELS_DIR=str(self.models))
        return subprocess.run([self.binary, 'reprocess-intents', *map(str, args)], env=env, capture_output=True, text=True)

    def create_db(self):
        with sqlite3.connect(self.db) as conn:
            conn.execute('CREATE TABLE records (id TEXT PRIMARY KEY, captured_at REAL, intent TEXT, has_triage INTEGER, json TEXT)')
            conn.execute('PRAGMA user_version = 21')
            for identifier, model, confidence in [('private-id', 'old', .6), ('manual-id', 'user', .8)]:
                record = dict(id=identifier, captured_at='2026-10-01T00:00:00.000Z',
                              app=dict(name='Synthetic'), annotation=dict(text='非公開の合成注釈', edited=False),
                              url='https://example.invalid/private', screenshot='captures/missing.png',
                              triage=dict(intent='code', intent_confidence=confidence, mentions_datetime=False, model=model,
                                          intent_probabilities=dict(code=confidence, todo=(1-confidence)/4, research=(1-confidence)/4,
                                                                    note=(1-confidence)/4, schedule=(1-confidence)/4)))
                conn.execute('INSERT INTO records VALUES (?, 0, ?, 1, ?)', (identifier, 'code', json.dumps(record)))

    def test_default_preview_is_readonly_and_needs_no_models(self):
        self.create_db()
        before = self.db.read_bytes()
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['mode'], 'dry-run')
        self.assertEqual(report['threshold'], .6)
        self.assertEqual(report['snapshot']['eligibleRecords'], 1)
        self.assertEqual(report['snapshot']['manualRecords'], 1)
        self.assertEqual(report['snapshot']['storedClassificationChanges70To60'], 1)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertFalse(self.models.exists())
        self.assertFalse(self.backup.exists())
        with sqlite3.connect(self.db) as conn:
            self.assertEqual(conn.execute('PRAGMA user_version').fetchone()[0], 21)
            self.assertEqual(conn.execute("SELECT count(*) FROM sqlite_master WHERE name='grdb_migrations'").fetchone()[0], 0)
        for private in ('private-id', 'manual-id', '非公開の合成注釈', 'example.invalid', 'captures/missing'):
            self.assertNotIn(private, result.stdout + result.stderr)
        self.assertNotIn('accuracy', result.stdout)

    def test_explicit_roots_and_json_output(self):
        self.create_db()
        result = self.cli('--data-root', self.data, '--models-root', self.models, '--dry-run', '--output', self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.output.read_text())['snapshot']['totalRecords'], 2)
        self.assertEqual(result.stdout, '')
        self.assertFalse(self.models.exists())

    def test_special_token_only_annotation_is_excluded_after_product_preprocessing(self):
        self.create_db()
        with sqlite3.connect(self.db) as conn:
            conn.execute("UPDATE records SET json=json_set(json,'$.annotation.text',?) WHERE id='private-id'",
                         (' <|im_end|> \n<|startoftext|> ',))
        before = self.db.read_bytes()
        result = self.cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        snapshot = json.loads(result.stdout)['snapshot']
        self.assertEqual(snapshot['emptyAnnotations'], 1)
        self.assertEqual(snapshot['eligibleRecords'], 0)
        self.assertEqual(self.db.read_bytes(), before)

    def test_missing_database_is_not_created(self):
        result = self.cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.db.exists())

    def test_unexpected_database_name_is_not_used(self):
        self.create_db()
        other = self.data / 'arbitrary.sqlite'
        self.db.rename(other)
        before = other.read_bytes()
        self.assertNotEqual(self.cli().returncode, 0)
        self.assertFalse(self.db.exists())
        self.assertEqual(other.read_bytes(), before)

    def test_corrupt_database_fails_without_backup_or_overwrite(self):
        self.db.write_bytes(b'invalid database sentinel')
        self.assertNotEqual(self.cli('--apply', '--backup', self.backup).returncode, 0)
        self.assertEqual(self.db.read_bytes(), b'invalid database sentinel')
        self.assertFalse(self.backup.exists())

    def test_apply_requires_backup_and_rejects_dry_run(self):
        self.create_db()
        before = self.db.read_bytes()
        for args in [('--apply',), ('--backup', self.backup), ('--apply', '--dry-run', '--backup', self.backup)]:
            self.assertNotEqual(self.cli(*args).returncode, 0)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertFalse(self.backup.exists())

    def test_missing_model_fails_before_backup_or_source_write_and_does_not_download(self):
        self.create_db()
        before = self.db.read_bytes()
        self.assertNotEqual(self.cli('--apply', '--backup', self.backup).returncode, 0)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertFalse(self.models.exists())
        self.assertFalse(self.backup.exists())

    def test_existing_backup_input_and_model_destinations_are_protected(self):
        self.create_db()
        self.backup.write_bytes(b'backup sentinel')
        before = self.db.read_bytes()
        for destination in [self.backup, self.db, self.data / 'new.sqlite', self.models / 'new.sqlite']:
            self.assertNotEqual(self.cli('--apply', '--backup', destination).returncode, 0)
        self.assertEqual(self.backup.read_bytes(), b'backup sentinel')
        self.assertEqual(self.db.read_bytes(), before)

    def test_report_protects_database_backup_and_roots_and_existing_files(self):
        self.create_db()
        self.output.write_bytes(b'report sentinel')
        before = self.db.read_bytes()
        for destination in [self.db, self.data / 'new.json', self.models / 'new.json', self.output]:
            self.assertNotEqual(self.cli('--output', destination).returncode, 0)
        self.assertNotEqual(self.cli('--apply', '--backup', self.backup, '--output', self.backup).returncode, 0)
        self.assertEqual(self.db.read_bytes(), before)
        self.assertEqual(self.output.read_bytes(), b'report sentinel')
        self.assertFalse(self.backup.exists())

    def test_symlink_report_cannot_overwrite_database(self):
        self.create_db()
        self.output.symlink_to(self.db)
        before = self.db.read_bytes()
        self.assertNotEqual(self.cli('--output', self.output).returncode, 0)
        self.assertEqual(self.db.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
