#!/usr/bin/env python3
import hashlib,json,shutil,subprocess,sys,tempfile
from pathlib import Path
root=Path(__file__).resolve().parent
manifest=json.loads((root/'manifest.json').read_text())
for name,digest in manifest['files'].items():
 if hashlib.sha256((root/name).read_bytes()).hexdigest()!=digest:raise SystemExit('fixture hash mismatch: '+name)
with tempfile.TemporaryDirectory(prefix='cc-fixture-repro-') as d:
 d=Path(d)
 for name in ['generate.py','frozen-vectors.json']:shutil.copyfile(root/name,d/name)
 subprocess.run([sys.executable,str(d/'generate.py')],check=True,stdout=subprocess.DEVNULL)
 for name in ['records.json','queries.json','manifest.json']:
  if (root/name).read_bytes()!=(d/name).read_bytes():raise SystemExit('non-deterministic fixture: '+name)
print('fixture hashes and deterministic generation verified')
