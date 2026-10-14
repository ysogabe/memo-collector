#!/usr/bin/env python3
import argparse,json,math,statistics,subprocess,datetime,hashlib,platform
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def dot(a,b):return sum(x*y for x,y in zip(a,b))
def norm(v):
 n=math.sqrt(dot(v,v));return [x/n for x in v]
def pct(x,p):
 x=sorted(x);return x[max(0,math.ceil(len(x)*p)-1)]
parser=argparse.ArgumentParser()
parser.add_argument('inputs',nargs='+')
parser.add_argument('--output',type=Path,default=ROOT/'spikes/llama/results.json')
parser.add_argument('--build',default='Swift debug on both; native llama static library Release')
args=parser.parse_args()
reports={Path(p).stem:json.loads(Path(p).read_text()) for p in args.inputs}
records=json.loads((ROOT/'evals/search/records.json').read_text())['records']
queries=json.loads((ROOT/'evals/search/queries.json').read_text())['queries']
summary={'hardware':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(), 'memoryBytes':int(subprocess.check_output(['sysctl','-n','hw.memsize'],text=True)), 'os':platform.platform(), 'date':str(datetime.date.today()), 'build':args.build, 'corpusSHA256':hashlib.sha256((ROOT/'evals/search/records.json').read_bytes()).hexdigest(), 'querySHA256':hashlib.sha256((ROOT/'evals/search/queries.json').read_bytes()).hexdigest(), 'reports':{},'agreement':{}}
for name,r in reports.items():
 rows={x['id']:x for x in r['rows']}
 assert len(rows)==len(r['rows']), 'duplicate input ID'
 assert all(len(x['vector'])==768 and all(math.isfinite(v) for v in x['vector']) and abs(math.sqrt(dot(x['vector'],x['vector']))-1)<.01 for x in rows.values()), 'invalid embedding'
 item={k:v for k,v in r.items() if k!='rows'}
 item['latency']={}
 for kind in ['query','document','image','fused']:
  times=[t for x in rows.values() if x['kind']==kind for t in x['milliseconds'][1:]]
  if times:item['latency'][kind]={'p50Ms':pct(times,.5),'p95Ms':pct(times,.95),'n':len(times),'firstPassP95Ms':pct([x['milliseconds'][0] for x in rows.values() if x['kind']==kind],.95)}
 qres=[]
 for q in queries:
  if q['split']!='holdout':continue
  vec=norm(rows['query:'+q['id']]['vector'][:256])
  order=sorted([(dot(vec,norm(rows['doc:'+x['record']['id']]['vector'][:256])),x['record']['id']) for x in records if q['includeArchived'] or x['record']['status']!='archived'],reverse=True)
  ranked=[x[1] for x in order][:30]; rel={x['recordID']:x['grade'] for x in q['relevant']}
  if not rel:continue
  rr=next((1/(i+1) for i,x in enumerate(ranked) if x in rel),0)
  def dcg(vals):return sum((2**grade-1)/math.log2(i+2) for i,grade in enumerate(vals))
  ideal=dcg(sorted(rel.values(),reverse=True)[:3]); actual=dcg([rel.get(x,0) for x in ranked[:3]])
  qres.append({'recall3':len(set(ranked[:3])&rel.keys())/len(rel),'mrr':rr,'ndcg3':actual/ideal})
 norms=[math.sqrt(dot(x['vector'],x['vector'])) for x in rows.values()]
 item['output768NormRange']=[min(norms),max(norms)]
 item['holdoutPositiveCount']=len(qres)
 item['holdout256']={k:statistics.mean(x[k] for x in qres) for k in ['recall3','mrr','ndcg3']}
 summary['reports'][name]=item
names=list(reports)
for i,name in enumerate(names):
 for other in names[i+1:]:
  a={x['id']:x for x in reports[name]['rows']};b={x['id']:x for x in reports[other]['rows']}
  agreement={}
  for kind in ['query','document','image','fused']:
   matched=[key for key in a if key in b and a[key]['kind']==kind]
   if not matched:continue
   values=[dot(norm(a[k]['vector']),norm(b[k]['vector'])) for k in matched]
   agreement[kind]={'minCosine':min(values),'meanCosine':statistics.mean(values),'count':len(values),
       'tokenIDsEqual':sum(a[k].get('tokenIDs') is not None and a[k].get('tokenIDs')==b[k].get('tokenIDs') for k in matched),
       'imageInputHashEqual':sum(a[k].get('imageInputHash') is not None and a[k].get('imageInputHash')==b[k].get('imageInputHash') for k in matched)}
  summary['agreement'][name+' vs '+other]=agreement
out=args.output;out.write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
for name,r in summary['reports'].items():print(name,r['latency'],r['holdout256'])
