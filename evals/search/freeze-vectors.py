#!/usr/bin/env python3
"""Explicitly freeze a synthetic evaluation cache. Reads only the provided cache file."""
import json,sys,hashlib,math
from pathlib import Path
root=Path(__file__).resolve().parent
cache=json.loads(Path(sys.argv[1]).read_text())
for name,field in [('records.json','corpusHash'),('queries.json','queryHash')]:
 assert hashlib.sha256((root/name).read_bytes()).hexdigest()==cache[field], 'stale fixture cache'
pipeline=dict(modelID='FluidInference/embeddinggemma-2-coreml',revision='3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4',runtime='coreml-vectors1',quantization='fp16+bf16-token-table',dimension=256,imageTokens=280,preprocessingVersion='prompts1/tokenizer1/bicubic1/interleaved1/mean-mrl1',vectorSchemaVersion=1)
assert cache['dimension']==256
for v in list(cache['documents'].values())+list(cache['queries'].values()):assert len(v)==256 and all(math.isfinite(x) for x in v) and abs(sum(x*x for x in v)-1)<.01
frozen={k:cache[k] for k in ['corpusHash','queryHash','indexSignature','dimension','documents','queries']}
frozen.update(schemaVersion=1,pipeline=pipeline,provenance='Core ML cpuAndGPU vectors generated exclusively from authored synthetic search-ja-v2, 2026-10-14; no user DB or model weights.')
(root/'frozen-vectors.json').write_text(json.dumps(frozen,ensure_ascii=False,separators=(',',':'))+'\n')
