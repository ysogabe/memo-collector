# #8 / #10 の電力・GPU/ANE counter 計測

2026-10-14、M3 24GiB / macOS 27.0.1 / AC電源で測定した。`sudo -n` は認証を要求したため、macOS の標準管理者認証を使った。rootで実行したのは Apple の固定system binary `powermetrics` のみ。モデル、アプリ、テストは通常ユーザーで実行し、電源設定は変更していない。

**M4 32GB はユーザー指定により対象外。M4 の利用を採用判断やタスク完了の前提にしない。** 結果は [post-merge report](../../docs/research/post-merge-runtime-validation.md) を参照。

## 再現

まずコンパイルを完了させる。取得済みモデルを指定し、別terminalで下記の sampler と workload を動かす。管理者認証は OS/terminal で行い、パスワードをログやチャットへ記録しない。

```sh
# 1秒sample、10〜900 sampleに制限。workloadはrootで実行しない。
spikes/power/capture.sh /tmp/cc-power-workload 240

# 同じMacの通常ユーザーの別terminal。最初に10秒のidleを記録する。
# coreml-tests と llama-bin は事前にビルドした Release のパス。
CC_MODELS_DIR=/path/to/models DIGUP_MODELS=/path/to/gguf \
python3 spikes/power/runtime_workload.py \
  --coreml-tests /path/to/Release/CCEmbeddingTests.xctest \
  --llama-bin /path/to/Release/digup-bench --output /tmp/cc-runtime-workload

python3 spikes/power/summarize.py /tmp/cc-power-workload/powermetrics.txt \
  /tmp/cc-power-workload/phase-power.json --windows /tmp/cc-runtime-workload/windows.json
```

モデルの固定revision、nativeパッチ、入力条件は [llama README](../llama/README.md)。Core ML は `swift build -c release --build-tests -Xswiftc -enable-testing`、native は比較用 checkout で `swift build -c release --product digup-bench`。Swift 6.4 の `swift build --show-bin-path -c release` で出力先を確認する。workload は GGUF の2ファイルを SHA256 検証し、232入力×3回を確認する。存在する結果ファイルへの再測定は拒否する。

実際の capture coordinator は次で測れる。最初のビルドと測定を分け、コンパイル中の電力を含めない。

```sh
CC_MODELS_DIR=/path/to/models CC_CAPTURE_BUILD_ONLY=1 scripts/capture-model-evaluation.sh
CC_MODELS_DIR=/path/to/models CC_CAPTURE_SKIP_BUILD=1 \
  CC_CAPTURE_BENCH_OUTPUT=/tmp/cc-capture CC_CAPTURE_BENCH_LIMIT=10 scripts/capture-model-evaluation.sh
```

capture の開始/モデル準備終了/2条件/終了は `capture.json.phases.jsonl` に UNIX epoch で記録される。`runtime_workload.py` の `windows.json` と同じ形の JSON object（phase名 → `[開始epoch, 終了epoch]`）を用意し、`summarize.py --windows` へ渡す。samplerを先に開始し、全phaseを含めて終了する。欠落した時刻・intervalやsampleが無いwindowはエラー。時刻の秒丸めと境界の混在を避け、**1秒marginの内側に全intervalが入るsampleだけ**を集計する。

## 数値の意味

CPU/GPU/ANE powerは **SoC全体の推定値**。同じMacのidleを併記し、背景processの影響を残す。異なる端末へ優劣を外挿しない。reported interval を積分した estimated joules は採取できた区間だけの値で、アプリ専用のenergyや欠落区間の推計ではない。arithmetic sample mean、sampled秒数、wall秒数、最大値を記録する。

parser は実際の mW/W label と interval を換算し、未出力counterを0にしない。macOS 27 の processor section と GPU section は同名の GPU Power を別に出し、数値が少し異なるため別々に保持する。CPU/GPU active residency はOSのlabelごとに残す。**ANE power は ANE 利用率ではない**。今回のOSはANE利用率を提供しない。process CPU seconds / wall time も併記し、GPU/ANE時間をCPU時間に加算しない。

`python3 -m unittest discover -s spikes/power -p 'test_*.py'` は6件のformat/単位/時刻/boundary/欠落契約を検証する。合成契約テストに加え、今回のmacOSの実sample（capture 180件、runtime 240件）でも parser の適合を確認した。生データと重みは `/tmp` に留め、SHA256と集計結果をGitへ保存する。
