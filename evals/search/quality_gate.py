#!/usr/bin/env python3
"""Gate freshly executed quality reports. Timing is deliberately not a quality gate."""
import json,math,sys
from pathlib import Path
COUNTS=['queryCount','answerableCount','noAnswerCount']
SCALARS=['mrr','noAnswerEmptyRate','noAnswerFalseHitRate']
MAPS=['recall','hitRate','ndcg']
def failures(baseline,actual,drop=.02):
 errors=[]
 if baseline.get('corpusID')!=actual.get('corpusID'):errors.append('corpusID changed')
 for key in ['corpus_sha256','queries_sha256']:
  if baseline.get('metadata',{}).get(key)!=actual.get('metadata',{}).get(key):errors.append(key+' changed')
 for name,mode in baseline.get('modes',{}).items():
  candidate=actual.get('modes',{}).get(name,{})
  for group,expected in mode['summaries'].items():
   row=candidate.get('summaries',{}).get(group)
   label=name+'/'+group
   if row is None:errors.append(label+' missing');continue
   for field in COUNTS:
    if row.get(field)!=expected[field]:errors.append(label+'/'+field+' changed')
   fields={k:expected.get(k) for k in SCALARS}
   values={k:row.get(k) for k in SCALARS}
   for field in MAPS:
    for cutoff in ['1','3','10']:
     key=field+'@'+cutoff;fields[key]=expected.get(field,{}).get(cutoff);values[key]=row.get(field,{}).get(cutoff)
   for field,old in fields.items():
    if old is None:continue
    new=values[field]
    if type(new) not in (int,float) or not math.isfinite(new) or not 0<=new<=1:errors.append(label+'/'+field+' missing/invalid');continue
    tolerance=0 if field.startswith('noAnswer') else drop
    if field=='noAnswerFalseHitRate': old,new=1-old,1-new
    if old-new>tolerance+1e-9:errors.append(f'{label}/{field}: {old:.6f} -> {new:.6f} (allowed drop {tolerance:.2f})')
 if not baseline.get('modes'):errors.append('empty baseline')
 return errors
if __name__=='__main__':
 if len(sys.argv)!=3:raise SystemExit('usage: quality_gate.py BASELINE ACTUAL')
 base=json.loads(Path(sys.argv[1]).read_text());actual=json.loads(Path(sys.argv[2]).read_text())
 errors=failures(base,actual)
 if errors:
  print('\n'.join(errors),file=sys.stderr);raise SystemExit(1)
 print('quality gate passed: Recall/HitRate/nDCG@1/3/10, MRR, counts and no-answer rate; timing excluded')
