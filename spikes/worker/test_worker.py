import json,sys,tempfile,time,unittest
from pathlib import Path
from queue import Queue,Policy
from client import Client,WorkerError
ROOT=Path(__file__).resolve().parent
VECTOR=[1.0]+[0.0]*255
class QueueTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.path=Path(self.tmp.name)/'queue.sqlite';self.now=100.;self.q=Queue(self.path,clock=lambda:self.now)
 def tearDown(self):self.q.close();self.tmp.cleanup()
 def save(self,**kw):self.q.save('record','synthetic','fixture',**kw)
 def test_persist_before_inference_and_deduplicate(self):
  self.save(); self.q.close(); self.q=Queue(self.path,clock=lambda:self.now)
  with self.q.db:self.q.enqueue('record','embedding','fixture',1)
  self.assertEqual(self.q.db.execute('SELECT count(*) FROM jobs').fetchone()[0],1)
  job=self.q.claim();self.assertEqual(job['text'],'synthetic');self.assertTrue(self.q.complete(job,VECTOR,'fixture'))
  self.assertIsNone(self.q.claim());self.assertEqual(self.q.search(VECTOR,'fixture')[0][1],'record')
 def test_edit_rejects_obsolete_completion(self):
  self.save();old=self.q.claim();self.q.save('record','changed','fixture')
  self.assertFalse(self.q.complete(old,VECTOR,'fixture'));new=self.q.claim();self.assertEqual(new['version'],2)
  self.assertTrue(self.q.complete(new,VECTOR,'fixture'))
 def test_expired_lease_and_restart_fence(self):
  self.save();old=self.q.claim(lease_seconds=1);self.now+=2
  self.q.close();self.q=Queue(self.path,clock=lambda:self.now);new=self.q.claim()
  self.assertNotEqual(old['token'],new['token']);self.assertFalse(self.q.complete(old,VECTOR,'fixture'));self.assertTrue(self.q.complete(new,VECTOR,'fixture'))
 def test_completion_after_lease_expiry_is_rejected(self):
  self.save();job=self.q.claim(lease_seconds=1);self.now+=2;self.assertFalse(self.q.complete(job,VECTOR,'fixture'))
 def test_backoff_and_terminal_retry_limit(self):
  self.save()
  for i in range(3):
   job=self.q.claim();self.assertEqual(job['attempts'],i+1);self.assertTrue(self.q.fail(job));self.assertIsNone(self.q.claim());self.now+=2**i
  self.assertEqual(self.q.db.execute('SELECT state FROM jobs').fetchone()[0],'failed');self.assertIsNone(self.q.claim())
 def test_cancel_and_delete(self):
  self.save();job=self.q.claim();self.q.cancel('record');self.assertFalse(self.q.complete(job,VECTOR,'fixture'));self.assertIsNone(self.q.claim())
  self.q.delete('record');self.assertEqual(self.q.db.execute('SELECT count(*) FROM jobs').fetchone()[0],0)
 def test_partial_success_survives_embedding_failure(self):
  self.save(steps=('guard','intent','embedding'));guard=self.q.claim();self.assertEqual(guard['step'],'guard');self.q.complete(guard,{'status':'synthetic_ok'},'fixture')
  intent=self.q.claim();self.q.complete(intent,{'label':'synthetic'},'fixture');embedding=self.q.claim();self.q.fail(embedding)
  self.assertEqual(self.q.db.execute('SELECT count(*) FROM results').fetchone()[0],2)
 def test_generation_and_vector_validation(self):
  self.save();job=self.q.claim();self.assertFalse(self.q.complete(job,VECTOR,'other'))
  for v in [[],[float('nan')]*256,[2.]*256]:self.assertFalse(self.q.complete(job,v,'fixture'))
  self.assertTrue(self.q.complete(job,VECTOR,'fixture'));self.assertEqual(self.q.search(VECTOR,'other'),[])
 def test_new_input_hides_old_index(self):
  self.save();job=self.q.claim();self.q.complete(job,VECTOR,'fixture');self.q.save('record','changed','fixture');self.assertEqual(self.q.search(VECTOR,'fixture'),[])
 def test_new_capture_priority_and_power_policy(self):
  self.save(backfill=True)
  for policy in [Policy(low_power=True),Policy(battery=True),Policy(high_load=True)]:self.assertIsNone(self.q.claim(policy))
  self.q.save('new','new','fixture');self.assertIsNone(self.q.claim(Policy(capturing=True)))
  self.assertEqual(self.q.claim(Policy(low_power=True))['record_id'],'new');self.assertEqual(self.q.claim()['record_id'],'record')
 def test_duplicate_claim_cannot_take_live_lease(self):
  self.save();job=self.q.claim();other=Queue(self.path,clock=lambda:self.now)
  try:self.assertIsNone(other.claim())
  finally:other.close()
class ClientTests(unittest.TestCase):
 def client(self,mode='ok',**kw):return Client([sys.executable,str(ROOT/'fake_worker.py'),mode],'fixture',startup_timeout=1,request_timeout=.05,**kw)
 def test_valid_response_and_size_limit(self):
  c=self.client()
  try:
   self.assertEqual(c.request('query','text')['vector'],VECTOR)
   with self.assertRaises(WorkerError):c.request('query','x'*8001)
  finally:c.dispose()
 def test_crash_timeout_restart_budget_and_cleanup(self):
  for op in ['crash','hang']:
   c=self.client(max_restarts=1)
   try:
    start=time.monotonic()
    with self.assertRaises(WorkerError):c.request(op)
    self.assertEqual(c.restarts,1);self.assertIsNone(c.process);self.assertLess(time.monotonic()-start,3)
   finally:c.dispose()
 def test_protocol_corruption_is_rejected(self):
  for mode in ['bad-id','bad-key','wrong-shape','nan','oversize','invalid-json','bad-ready']:
   c=self.client(mode,max_restarts=0)
   try:
    with self.assertRaises(WorkerError):c.request('query')
    self.assertIsNone(c.process)
   finally:c.dispose()
 def test_unexpected_exit_restarts_then_recovers(self):
  c=self.client()
  try:
   c.start();old=c.process;old.kill();old.wait();self.assertEqual(c.request('query')['vector'],VECTOR);self.assertEqual(c.restarts,1)
  finally:c.dispose()
if __name__=='__main__':unittest.main()
