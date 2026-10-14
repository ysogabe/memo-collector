#!/usr/bin/env python3
"""Synthetic fault source for transport tests; never a model substitute in benchmarks."""
import json,sys,time,os
mode=sys.argv[1] if len(sys.argv)>1 else 'ok'
print(json.dumps({'event':'ready','key':'wrong' if mode=='bad-ready' else 'fixture','dimension':256}),flush=True)
for line in sys.stdin:
 r=json.loads(line); op=r['op']
 if op=='crash': os._exit(86)
 if op=='hang': time.sleep(60)
 if mode=='oversize': print('x'*70000,flush=True); continue
 if mode=='invalid-json': print('{oops',flush=True); continue
 vector=[1.0]+[0.0]*255
 if mode=='wrong-shape': vector=[]
 if mode=='nan': vector[0]=float('nan')
 print(json.dumps({'id':'wrong' if mode=='bad-id' else r['id'],'key':'wrong' if mode=='bad-key' else 'fixture','vector':vector,'milliseconds':0,'footprintMB':0}),flush=True)
