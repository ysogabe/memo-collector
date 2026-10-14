#!/usr/bin/env python3
import json
from pathlib import Path
root=Path(__file__).resolve().parents[2]
records=json.loads((root/'evals/search/records.json').read_text())['records']
queries=json.loads((root/'evals/search/queries.json').read_text())['queries']
inputs=[{'id':'doc:'+x['record']['id'],'kind':'document','text':x['record']['annotation']['text'],'title':x['record']['window']['title']} for x in records]
inputs += [{'id':'query:'+q['id'],'kind':'query','text':q['text']} for q in queries]
for i in range(1,5):
 inputs += [{'id':f'image:s{i:02d}','kind':'image','image':f'poc/fixtures/screens/s{i:02d}.png'},
            {'id':f'fused:s{i:02d}','kind':'fused','image':f'poc/fixtures/screens/s{i:02d}.png','text':'この画面の内容を後で確認する','title':'検証用の画面'}]
(root/'spikes/llama/inputs.json').write_text(json.dumps({'schemaVersion':1,'inputs':inputs},ensure_ascii=False,indent=2)+'\n')
print(len(inputs),'inputs')
