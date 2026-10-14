#!/usr/bin/env python3
"""Deterministic, authored synthetic data; reads no user records or media."""
import hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parent
# Each topic is isolated to one split; all related records and query paraphrases follow it.
TOPICS=[
('search','日本語検索','検索','SwiftUI','SQLite の日本語検索にキーワード検索を足す方式を比較する','曖昧なメモを日本語で探す設計','6','API検索'),
('audio','音声転写','音声','WhisperKit','音声認識で固有名詞の文字起こし誤りを修正する辞書を作る','話した言葉を正確に文字にする方法','60','transcribe'),
('calendar','予定登録','予定','Calendar','来週の打ち合わせの日時と会議室をカレンダーへ登録する','次の会議を忘れないよう予定表に入れる','18','createEvent'),
('battery','低電力','電池','CoreML','バッテリー駆動の低電力モードでは過去の埋め込み処理を後回しにする','電池を長持ちさせながら索引を作る','25','ANE'),
('privacy','秘密保護','秘密','Vision','画面に含まれる秘密情報を検出してマスク画像だけを渡す','パスワードの写ったスクショを安全に共有する','31','scanSecrets'),
('database','世代切替','索引','GRDB','埋め込み索引の世代を保ち再構築が失敗しても旧世代に戻す','検索モデル変更中も元のデータを守る','41','setEmbedding'),
('network','通信再試行','通信','URLSession','HTTP の接続が切れたら回数上限付きの指数バックオフで再試行する','一時的な通信失敗から自動で回復させる','51','URLSession'),
('queue','ジョブ再開','再開','Swift','非同期ジョブを保存しアプリの再起動後に未完了の要求を再開する','アプリが落ちても処理の続きをやる','61','resumePending'),
('image','画像縮小','画像','CoreGraphics','画像を bicubic で縮小し前処理の画素値を参照と一致させる','スクショを小さくして埋め込みの品質を保つ','72','resizeBicubic'),
('ranking','順位融合','順位','SQLite','意味検索と全文検索の順位を RRF で融合して検索品質を比較する','単語の一致と意味の近さを両立して探す','82','RRF'),
('memory','メモリ解放','解放','Metal','使っていない推論モデルを解放しプロセスの物理メモリを計測する','常駐アプリのメモリ消費を減らす','92','unload'),
('error','エラー診断','障害','Xcode','ERR_TOKEN_EXPIRED の原因と期限切れセッションの更新を調査する','ログインが突然切れるエラーの対処','102','ERR_TOKEN_EXPIRED'),
('record','即時記録','記録','ContextCapture','ホットキーで画面と声のメモを素早く保存する','見ている画面に一言音声でメモを付ける','112','captureFrontmost'),
('guard','画像手渡し','確認','MCP','needs_review の画像は確認が済むまでエージェントに渡さない','確認が必要な画像の外部公開を止める','122','needs_review'),
('model','モデル取得','取得','HuggingFace','固定 revision のモデルを取得し sha256 を検証してから使う','ダウンロードした推論モデルが正しいか確認する','132','sha256'),
('tests','回帰評価','評価','XCTest','検索の正解集合を固定して Recall と MRR の回帰を検出する','検索ロジック更新で品質が落ちないか測る','142','Recall@3'),
]
def ulid(n):
    alphabet='0123456789ABCDEFGHJKMNPQRSTVWXYZ'
    return '01JSEARCH'+''.join(alphabet[(n>>(5*i))&31] for i in range(16,-1,-1))
def dump(path,data):
    path.write_text(json.dumps(data,ensure_ascii=False,indent=2,sort_keys=True)+'\n')
records=[]; queries=[]
for i,(group,title,short,app,text,paraphrase,number,api) in enumerate(TOPICS):
    split='dev' if i<8 else 'holdout'
    ids=[]
    for j in range(3):
        rid=ulid(i*3+j+1); ids.append(rid)
        annotation=[text+'。'+api+' の実装を読む。',title+'の比較資料。先行方式と新方式を検証する。','完了した'+title+'の過去メモ。'+text][j]
        records.append({'group':group,'split':split,'screen':None,'record':{
            'id':rid,'captured_at':f'2026-10-{1+i:02d}T{8+j:02d}:00:00+09:00',
            'app':{'name':app,'bundle_id':'example.synthetic.'+group},
            'window':{'title':title+f' · Issue #{number}'+(' 過去資料' if j==2 else ''),'frame':None},
            'url':f'https://github.com/example-fixtures/{group}/issues/{number}',
            'extra':{},'screenshot':None,'masked_screenshot':None,'audio':None,
            'annotation':{'text':annotation,'stt_engine':'synthetic','edited':False},
            'triage':None,'guard':{'status':'clear','findings':[]},'handoff':[],'notes':[],
            'status':['inbox','done','archived'][j]}})
    noise=title.replace('検索','検策').replace('転写','転舎').replace('低電力','低電カ').replace('秘密','秘蜜').replace('世代','世帯').replace('通信','通心').replace('ジョブ','ジョプ').replace('画像','画象').replace('順位','順立').replace('メモリ','メモリー').replace('エラー','エラ一').replace('記録','記緑').replace('手渡し','手渡レ').replace('モデル','モデノレ').replace('評価','評値')
    cases=[(title,[0,1],['exact','japanese']), (paraphrase,[0,1],['paraphrase','japanese']),
           (short,[0,1],['short','japanese']), (api,[0],['identifier','mixed']),
           (f'https://github.com/example-fixtures/{group}/issues/{number}',[0,1],['url','exact']),
           (f'{group} #{number}',[0,1],['issue','exact']),
           (noise+'の検証',[0,1],['noise','ocr_stt']),
           (title,[0,1,2],['archived','filter']),
           (title[:3],[0,1],['japanese_substring','exact']),
           (''.join(chr(ord(c)+0xFEE0) if '!'<=c<='~' else c for c in api),[0],['width','identifier'])]
    for j,(q,positive,tags) in enumerate(cases):
        queries.append({'id':f'{group}-{j+1:02d}','text':q,'relevant':[{'recordID':ids[k],'grade':2 if k==0 else 1} for k in positive],
                        'tags':tags,'group':group,'split':split,'includeArchived':j==7})
for split in ['dev','holdout']:
    negatives = ['ペンギンが砂漠で踊る写真','ERR_MISSING_Z9Q8X7','https://example.invalid/unknown/999999','#999999','量子化されていない火星の植木鉢','全く存在しないプロジェクト Q7J9V3','未登録の領収書 987654321','NO_SUCH_API_7319'] if split=='dev' else ['海底にある架空の恐竜牧場','ERR_ABSENT_W2K4B6','https://example.invalid/absent/888888','#888888','金星の空飛ぶ味噌汁','未発見のソフトウェア X8C6M4','存在しない請求番号 123456789','NONEXISTENT_FUNCTION_8421']
    for i,q in enumerate(negatives):
        queries.append({'id':f'none-{split}-{i}','text':q,'relevant':[],'tags':['no_answer'],
                        'group':f'none-{split}-{i}','split':split,'includeArchived':False})
dump(ROOT/'records.json',{'schemaVersion':1,'corpusID':'search-ja-v2','records':records})
dump(ROOT/'queries.json',{'schemaVersion':1,'corpusID':'search-ja-v2','queries':queries})
manifest={'schemaVersion':1,'corpusID':'search-ja-v2','seed':0,'provenance':'Authored synthetic Japanese text; no personal records, screenshots, audio, or upstream evaluation data copied.',
          'license':'CC0-1.0','generator':'generate.py','records':len(records),'queries':len(queries),
          'files':{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in ['records.json','queries.json']},
          'splitPolicy':'Topic groups, their records and all paraphrases belong to exactly one dev/holdout split.'}
dump(ROOT/'manifest.json',manifest)
print(f'{len(records)} records, {len(queries)} queries')
