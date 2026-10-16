# Context Capture アイコン案

image_gen.imagegen で作成した比較用の5案。生成プロンプトは prompts.json。

1. 青: キャプチャ枠＋音声波形
2. オレンジ: 紙のメモ＋音声波形
3. 紫: ウインドウの重なり＋吹き出し
4. 紺: キャプチャリング＋録音ドット
5. 緑: 吹き出し＋キャプチャ枠

比較案の原本はラスタ画像として保存。採用した緑の案は外周・余白を整え、各サイズを生成してAppIconへ組み込み。
緑の案を採用。05-appicon-master.png をアプリの AppIcon に反映。
透過版は組み込み image_gen で生成し、macOS アイコン用の外周・サイズを正規化。
05-speech-viewfinder-transparent.png は透過生成の原本、master が組み込み用。
