#!/usr/bin/env python3
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
# Baseline update is explicit. Normal QA never writes this file.
frozen={k:r[k] for k in ['schemaVersion','corpusID','metadata']}
frozen['metadata']={k:v for k,v in r['metadata'].items() if k in ['corpus_sha256','queries_sha256','model_signature','scope','threshold']}
frozen['modes']={}
for mode,data in r['modes'].items():
 frozen['modes'][mode]={'summaries':{name:{k:v for k,v in row.items() if 'Milliseconds' not in k} for name,row in data['summaries'].items()}}
Path(sys.argv[2]).write_text(json.dumps(frozen,ensure_ascii=False,sort_keys=True,indent=2)+'\n')
