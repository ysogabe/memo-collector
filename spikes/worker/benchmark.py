#!/usr/bin/env python3
"""Opt-in actual Core ML comparison and durable-save -> helper -> search PoC."""
import json, math, resource, statistics, subprocess, sys, tempfile, time, os, signal, datetime
from pathlib import Path
from client import Client,WorkerError
from queue import Queue
ROOT=Path(__file__).resolve().parents[2]
def pct(values,p): return sorted(values)[max(0,math.ceil(len(values)*p)-1)]
def latency(values): return {'p50Ms':pct(values,.5),'p95Ms':pct(values,.95),'n':len(values)}
def cosine(a,b):return sum(x*y for x,y in zip(a,b))/math.sqrt(sum(x*x for x in a)*sum(x*x for x in b))
exe=sys.argv[1]
key=json.loads(subprocess.check_output([exe,'--signature']))['key']
records=json.loads((ROOT/'evals/search/records.json').read_text())['records']
queries=[q for q in json.loads((ROOT/'evals/search/queries.json').read_text())['queries'] if q['split']=='holdout' and q['relevant']][:16]
with tempfile.TemporaryDirectory(prefix='cc-worker-bench-') as tmp:
 tmp=Path(tmp);queue=Queue(tmp/'jobs.sqlite');save_times=[]
 # Persist synthetic records + jobs BEFORE starting the inference helper.
 for row in records:
  r=row['record'];start=time.monotonic();queue.save(r['id'],r['annotation']['text'],key);save_times.append((time.monotonic()-start)*1000)
 assert queue.db.execute('SELECT count(*) FROM records').fetchone()[0]==48
 client=Client([exe],key,startup_timeout=300,request_timeout=5)
 try:
  client.start();startup=client.start_milliseconds;ready=dict(client.ready)
  ipc_times=[];vectors=[];worker_memory=[];total_rss=[]
  for q in queries:
   vector=None
   for _ in range(3):
    start=time.monotonic();reply=client.request('query',q['text']);ipc_times.append((time.monotonic()-start)*1000);vector=reply['vector'];worker_memory.append(reply['footprintMB'])
    rss=sum(int(subprocess.check_output(['ps','-o','rss=','-p',str(pid)]).strip()) for pid in [os.getpid(),client.process.pid])*1024/1e6
    total_rss.append(rss)
   vectors.append(vector)
  # Actual helper kill; the next query retries with the identical key.
  client.process.kill();client.process.wait();start=time.monotonic();recovered=client.request('query',queries[0]['text']);recovery=(time.monotonic()-start)*1000
  assert cosine(recovered['vector'],vectors[0])>.99999
  by_id={x['record']['id']:x['record'] for x in records};obsolete=False;completed=0
  while (job:=queue.claim()) is not None:
   r=by_id[job['record_id']];reply=client.request('document',job['text'],title=r['window']['title'])
   if not obsolete:
    queue.save(job['record_id'],job['text']+' 合成編集',key)
    assert not queue.complete(job,reply['vector'],reply['key']);obsolete=True;continue
   assert queue.complete(job,reply['vector'],reply['key']);completed+=1
  assert completed==48
  first=queries[0];rank=queue.search(vectors[0],key);relevant={x['recordID'] for x in first['relevant']}
  assert set(x[1] for x in rank[:3]) & relevant, 'synthetic E2E search miss'
  assert queue.db.execute("SELECT count(*) FROM jobs WHERE state='succeeded'").fetchone()[0]==48
  assert queue.search(vectors[0],'incompatible-key')==[]
  after_unload=client.request('unload')['footprintMB'];client.dispose()
  # Separate child: hang is killed at deadline, with no automatic retry.
  faulty=Client([exe],key,startup_timeout=300,request_timeout=.1,max_restarts=0)
  try:
   faulty.start();start=time.monotonic()
   try:faulty.request('hang');raise AssertionError('hang accepted')
   except WorkerError:timeout_ms=(time.monotonic()-start)*1000
   assert faulty.process is None
  finally:faulty.dispose()
  # Orphan a synthetic helper while it is hanging; parent-watch must terminate it.
  pid_file=tmp/'orphan.pid'
  parent_code="""import os,sys,time,json;sys.path.insert(0,sys.argv[1]);from client import Client
c=Client([sys.argv[2]],sys.argv[3],startup_timeout=300);c.start()
c.process.stdin.write(b'{"id":"orphan","op":"hang"}\\n');c.process.stdin.flush()
open(sys.argv[4],'w').write(str(c.process.pid));time.sleep(.1);os._exit(0)
"""
  subprocess.run([sys.executable,'-c',parent_code,str(ROOT/'spikes/worker'),exe,key,str(pid_file)],check=True)
  orphan_pid=int(pid_file.read_text());start=time.monotonic();gone=False
  while time.monotonic()-start<5:
   try:os.kill(orphan_pid,0)
   except ProcessLookupError:gone=True;break
   time.sleep(.05)
  if not gone:os.kill(orphan_pid,signal.SIGKILL)
  assert gone, 'parent-watch failed'
  orphan_ms=(time.monotonic()-start)*1000
  # Same Swift executable/API, inference in its own benchmark host process (not the app).
  input_file=tmp/'queries.json';input_file.write_text(json.dumps([q['text'] for q in queries],ensure_ascii=False))
  inline_file=tmp/'inline.json';subprocess.run([exe,'--inline',str(input_file),str(inline_file)],check=True)
  inline=json.loads(inline_file.read_text());agreement=[cosine(v,r['vector']) for v,r in zip(vectors,inline['rows'])]
  assert min(agreement)>.99999
  result={'schemaVersion':1,'date':str(datetime.date.today()),'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(), 'memoryBytes':int(subprocess.check_output(['sysctl','-n','hw.memsize'],text=True)),'runtime':'Core ML cpuAndGPU, text-only, 256d, Swift Debug',
    'key':key,'save48BeforeInference':latency(save_times),'helperStartupMs':startup,'helperReady':ready,
    'helperRequestEndToEnd':latency(ipc_times),'helperWarmRequest':latency([x for i,x in enumerate(ipc_times) if i%3!=0]),
    'helperMaxWarmPhysicalMB':max(worker_memory),'helperAfterUnloadPhysicalMB':after_unload,
    'parentAndHelperMaxSampledRSSMB':max(total_rss),'orphanWatchExitMs':orphan_ms,
    'inlineMaxInferencePhysicalMB':inline['maxInferenceFootprintMB'], 'inlineLoadMs':inline['loadMilliseconds'],'inlineWarmInference':latency([t for r in inline['rows'] for t in r['milliseconds'][1:]]),
    'inlineAfterUnloadPhysicalMB':inline['afterUnloadFootprintMB'],'minInlineHelperCosine':min(agreement),
    'killedHelperRecoveryMs':recovery,'hangDetectionAndKillMs':timeout_ms,
    'parentPeakRSSMB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1e6,
    'e2e':{'savedBeforeWorker':48,'currentVersionResults':completed,'obsoleteResultRejected':obsolete,'matchingQueryTop3':True,'wrongGenerationEmpty':True},
    'scope':'standalone synthetic queue/text helper; no AppCoordinator, STT, intent, UI event loop, real capture attachments, battery or M1 measurements'}
  (ROOT/'spikes/worker/results.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
  print(json.dumps(result,ensure_ascii=False,indent=2))
 finally:
  client.dispose();queue.close()
