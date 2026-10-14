"""CLI contracts against the built binary; authored data only."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.environ.get('CC_INTENT_EVAL_BINARY'), 'built cc-models required')
class IntentEvaluationCLI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.input = self.root / 'input.json'
        self.report = self.root / 'report.json'
        self.binary = os.environ['CC_INTENT_EVAL_BINARY']

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args):
        env = dict(os.environ, CC_DATA_DIR=str(self.root / 'app-data'), CC_MODELS_DIR=str(self.root / 'models-absent'))
        return subprocess.run([self.binary, 'eval-intent', *map(str, args)], env=env, capture_output=True, text=True)

    def samples(self, count=5):
        return [dict(id=f'case-{i}', text='テストを書いて', truth='code', probabilities={
            'code': .8, 'todo': .05, 'research': .05, 'note': .05, 'schedule': .05}) for i in range(count)]

    def write_input(self, samples=None):
        self.input.write_text(json.dumps(dict(kind='synthetic', samples=self.samples() if samples is None else samples)))

    def test_saved_probabilities_split_and_no_private_text_in_report(self):
        self.write_input()
        result = self.run_cli('--input', self.input, '--output', self.report)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(self.report.read_text())
        self.assertEqual(report['labeledRecords'], 5)
        self.assertFalse(report['labelCountSufficient'])
        stored = report['evaluations'][0]
        self.assertEqual(stored['development'][0]['samples'], 4)
        self.assertEqual(stored['holdout'][0]['samples'], 1)
        self.assertEqual(stored['development'][2]['accuracy'], 1)
        self.assertNotIn('case-0', self.report.read_text())
        self.assertNotIn('テストを書いて', self.report.read_text())
        self.assertFalse((self.root / 'models-absent').exists())

    def test_table_and_json_can_be_used_together(self):
        self.write_input()
        result = self.run_cli('--input', self.input, '--table', '--output', self.report)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('| coverage | accuracy (classified) |', result.stdout)
        self.assertIn('| stored | holdout | 0.7 | 1 | 100.0% | 100.0% |', result.stdout)
        self.assertNotIn('case-0', result.stdout)
        self.assertEqual(json.loads(self.report.read_text())['labeledRecords'], 5)

    def test_no_labels_reports_need_and_exit_two(self):
        self.write_input([])
        result = self.run_cli('--input', self.input, '--output', self.report)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(json.loads(self.report.read_text())['status'], 'needs_manual_labels')

    def test_invalid_probability_distribution_fails(self):
        rows = self.samples(); rows[0]['probabilities'] = {'code': .9}
        self.write_input(rows)
        self.assertNotEqual(self.run_cli('--input', self.input).returncode, 0)

    def test_missing_probabilities_count_is_explicit(self):
        rows = self.samples(); del rows[-1]['probabilities']
        self.write_input(rows)
        result = self.run_cli('--input', self.input, '--output', self.report)
        self.assertEqual(result.returncode, 0, result.stderr)
        stored = json.loads(self.report.read_text())['evaluations'][0]
        self.assertEqual(stored['missingStoredProbabilities'], 1)
        self.assertEqual(stored['holdout'], [])

    def test_input_and_database_cannot_be_overwritten(self):
        self.write_input()
        before = self.input.read_bytes()
        self.assertNotEqual(self.run_cli('--input', self.input, '--output', self.input).returncode, 0)
        self.assertEqual(before, self.input.read_bytes())
        db = self.root / 'records.sqlite'
        with sqlite3.connect(db) as conn:
            conn.execute('CREATE TABLE records (id TEXT, captured_at TEXT, intent TEXT, json TEXT)')
        before = db.read_bytes()
        self.assertNotEqual(self.run_cli('--database', db, '--output', db).returncode, 0)
        self.assertEqual(before, db.read_bytes())

    def test_recompute_without_models_fails_without_download(self):
        self.write_input()
        result = self.run_cli('--input', self.input, '--recompute')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'models-absent').exists())

    def test_bad_thresholds_and_duplicate_ids_fail(self):
        self.write_input()
        for threshold in ('nan', '-.1', '1.1', '0.7,', ''):
            self.assertNotEqual(self.run_cli('--input', self.input, '--thresholds', threshold).returncode, 0)
        rows = self.samples(); rows[-1]['id'] = rows[0]['id']; self.write_input(rows)
        self.assertNotEqual(self.run_cli('--input', self.input).returncode, 0)

    def test_candidate_export_and_validation_before_inference(self):
        result = self.run_cli('--print-question')
        self.assertEqual(result.returncode, 0, result.stderr)
        candidate = json.loads(result.stdout)
        self.assertEqual(set(candidate['descriptions']), {'todo', 'research', 'code', 'note', 'schedule'})
        candidate['name'] = 'invalid'; del candidate['descriptions']['code']
        path = self.root / 'candidate.json'; path.write_text(json.dumps(candidate))
        self.write_input()
        self.assertNotEqual(self.run_cli('--input', self.input, '--candidate', path).returncode, 0)
        self.assertFalse((self.root / 'models-absent').exists())


if __name__ == '__main__':
    unittest.main()
