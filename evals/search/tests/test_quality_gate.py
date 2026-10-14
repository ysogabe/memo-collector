import copy,json,sys,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
from quality_gate import failures
class GateTests(unittest.TestCase):
 def setUp(self):
  self.baseline=json.loads((ROOT/'golden-quality.json').read_text());self.actual=copy.deepcopy(self.baseline)
 def row(self):return self.actual['modes']['baseline_native_vector']['summaries']['split:holdout']
 def test_equal_and_timing_changes_pass(self):
  self.assertEqual(failures(self.baseline,self.actual),[]);self.row()['p95Milliseconds']=1e9;self.assertEqual(failures(self.baseline,self.actual),[])
 def test_recall_degradation_is_caught(self):
  self.row()['recall']['3']-=.03;self.assertTrue(failures(self.baseline,self.actual))
 def test_two_point_drop_is_allowed(self):
  self.row()['recall']['3']-=.02;self.assertEqual(failures(self.baseline,self.actual),[])
 def test_missing_mode_cohort_and_query_count_are_caught(self):
  self.actual['modes'].pop('poc_rrf');self.assertTrue(failures(self.baseline,self.actual))
  self.actual=copy.deepcopy(self.baseline);self.row()['queryCount']-=1;self.assertTrue(failures(self.baseline,self.actual))
 def test_negative_false_hits_must_not_increase(self):
  self.actual['modes']['poc_gated_rrf']['summaries']['split:holdout']['noAnswerFalseHitRate']+=.125
  self.assertTrue(failures(self.baseline,self.actual))
 def test_nonfinite_and_missing_metric_are_caught(self):
  for value in [None,float('nan'),float('inf')]:self.row()['mrr']=value;self.assertTrue(failures(self.baseline,self.actual))
 def test_stale_corpus_hash_fails(self):
  self.actual['metadata']['corpus_sha256']='wrong';self.assertTrue(failures(self.baseline,self.actual))
if __name__=='__main__':unittest.main()
