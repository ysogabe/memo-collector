#!/bin/zsh
# Wave 4 e2e: 本物の 3 モデルを 1 プロセスに載せた計測（docs/e2e/report.md）。結果は docs/e2e/results/<timestamp>-*.json。
#
#   (a) swift test -c release で E2ETests（キャプチャ経路・トリアージ・メモリ・d1 の数値一致・ガード・意図・検索）
#   (b) d1 の数値一致: SwiftPM（swift test -c release）と Xcode（xcodebuild test -configuration Release）で
#       CCIntentTests/D1NumericsTests を回し、PyTorch 参照との差と、2 つのビルドの間の差を記録
#   (c) アプリのアイドル CPU: Release ビルドのアプリを一時データで起動 → モデル準備の完了を待つ → 60 秒待つ →
#       60 秒間 1 秒ごとに ps -o %cpu と CPU 時間を取る → 終了させる
#
# 使い方:
#   CC_MODELS_DIR=/path/to/models scripts/e2e.sh            # 全部
#   CC_E2E_STEPS="a b" scripts/e2e.sh                       # 一部だけ（a / b / c）
# 環境変数:
#   CC_MODELS_DIR       モデルの置き場（既定: メイン作業ツリーの spikes/dev-models）。**読み取りのみ**（manifest を書かない）
#   CC_E2E_ROUNDS       (a) の周回数（既定 3）
#   CC_E2E_LIMIT        (a) の 1 周の件数（既定 30）
#   CC_E2E_MAX_LOAD     計測を始める前に 1 分平均の load average がこれ未満になるまで待つ（既定 3.0、最大 CC_E2E_LOAD_WAIT 秒）
#   CC_E2E_LOAD_WAIT    上の待ちの上限秒（既定 600）
#   CC_E2E_IDLE_SETTLE  (c) モデル準備の後に待つ秒（既定 60）
#   CC_E2E_IDLE_SAMPLES (c) 取る回数（1 秒ごと、既定 60）
#   CC_E2E_CONFIG       (a) の結果ファイル名の構成名（既定 swiftpm-release）
#   CC_E2E_MLX_CACHE_LIMIT_MB  (a) の実験: MLX のキャッシュ上限（製品は未設定）。CC_E2E_CONFIG も変えること
set -euo pipefail

root=${0:A:h:h}
pkg=$root/Packages/ContextCaptureKit
results=$root/docs/e2e/results
work=${${TMPDIR:-/tmp}%/}/cc-e2e-work
mkdir -p $results $work

export CC_MODELS_DIR=${CC_MODELS_DIR:-/Users/yoshio/works/60-misc/memo-collector/spikes/dev-models}
steps=(${=CC_E2E_STEPS:-a b c})
stamp=$(date +%Y%m%d-%H%M%S)
max_load=${CC_E2E_MAX_LOAD:-3.0}
load_wait=${CC_E2E_LOAD_WAIT:-600}

step() { print -P "%B==> $1%b" }
load1() { sysctl -n vm.loadavg | awk '{print $2}' }

# 1 分平均の load average が下がるまで待つ（上限つき）。待った秒数と最終値を出す。
wait_for_quiet() {
  local waited=0
  while (( $(load1) >= max_load )) && (( waited < load_wait )); do
    (( waited % 60 == 0 )) && print "  load average $(load1) >= $max_load; 待機中（${waited}s）"
    sleep 10
    (( waited += 10 ))
  done
  print "  load average $(load1)（${waited}s 待った）: $(uptime)"
}

# モデルの置き場に書き込みが無いことを確かめるための印。
models_stamp=$work/models-stamp-$stamp
touch $models_stamp
check_models_untouched() {
  local changed
  changed=$(find $CC_MODELS_DIR -newer $models_stamp 2>/dev/null | head -n 5)
  if [[ -n $changed ]]; then
    print "⚠️ CC_MODELS_DIR に書き込みがあった:"; print $changed
  else
    print "  CC_MODELS_DIR への書き込みなし"
  fi
}

swift_test_flags=(-c release --disable-keychain -Xswiftc -enable-testing)

# ---------------------------------------------------------------- (a)
if (( ${steps[(Ie)a]} )); then
  step "(a) E2ETests（swift test -c release）"
  (cd $pkg && swift build $swift_test_flags --build-tests >| $work/a-build.log 2>&1) || { tail -n 30 $work/a-build.log; exit 1 }
  wait_for_quiet
  a_config=${CC_E2E_CONFIG:-swiftpm-release}
  out=$results/$stamp-$a_config.json
  if ! (cd $pkg && CC_RUN_E2E=1 CC_E2E_CONFIG=$a_config CC_E2E_OUT=$out swift test $swift_test_flags --filter 'E2ETests' >| $work/a-test.log 2>&1); then
    grep -E "error|failed" $work/a-test.log | tail -n 30
    print "(a) failed. log: $work/a-test.log"; exit 1
  fi
  grep -E "E2E (round|results)" $work/a-test.log || true
  [[ -f $out ]] || { print "(a) 結果が無い（skip された？）: $work/a-test.log"; exit 1 }
  check_models_untouched
fi

# ---------------------------------------------------------------- (b)
if (( ${steps[(Ie)b]} )); then
  step "(b) d1 の数値一致: SwiftPM Release"
  spm_json=$work/$stamp-d1-swiftpm.json
  wait_for_quiet
  if ! (cd $pkg && CC_D1_RESULTS_OUT=$spm_json swift test $swift_test_flags --filter 'CCIntentTests.D1NumericsTests' >| $work/b-spm.log 2>&1); then
    grep -E "error|failed" $work/b-spm.log | tail -n 30; print "log: $work/b-spm.log"; exit 1
  fi
  [[ -f $spm_json ]] || { print "SwiftPM 版の結果が無い（モデルが無くて skip？）"; exit 1 }

  step "(b) d1 の数値一致: Xcode（xcodebuild test -configuration Release）"
  xc_json=$work/$stamp-d1-xcode.json
  derived=$root/DerivedData/e2e-kit
  # xcodebuild はテストランナーへ環境変数をそのまま渡さない。TEST_RUNNER_ 接頭辞を付けたものだけが（接頭辞を外して）渡る。
  # Release ではテスト対象が @testable import できるよう ENABLE_TESTABILITY=YES を付ける（SwiftPM 側の -enable-testing と同じ）。
  (cd $pkg && xcodebuild build-for-testing \
      -scheme ContextCaptureKit-Package -destination 'platform=macOS' -configuration Release \
      -derivedDataPath $derived -skipMacroValidation -skipPackagePluginValidation \
      ENABLE_TESTABILITY=YES >| $work/b-xcode-build.log 2>&1) || { grep -E "error:" $work/b-xcode-build.log | tail -n 30; exit 1 }
  wait_for_quiet
  if ! (cd $pkg && TEST_RUNNER_CC_MODELS_DIR=$CC_MODELS_DIR TEST_RUNNER_CC_D1_RESULTS_OUT=$xc_json xcodebuild test-without-building \
      -scheme ContextCaptureKit-Package -destination 'platform=macOS' -configuration Release \
      -derivedDataPath $derived -skipMacroValidation -skipPackagePluginValidation \
      -only-testing:CCIntentTests/D1NumericsTests >| $work/b-xcode-test.log 2>&1); then
    grep -E "error|failed|\*\* TEST" $work/b-xcode-test.log | tail -n 30; print "log: $work/b-xcode-test.log"; exit 1
  fi
  [[ -f $xc_json ]] || { print "Xcode 版の結果が無い（TEST_RUNNER_ で環境変数が渡っていない？）"; exit 1 }
  metallibs=$(find $derived/Build/Products/Release -name default.metallib 2>/dev/null | head -n 3 | tr '\n' ' ')

  /usr/bin/python3 - $spm_json $xc_json $results/$stamp-d1-parity.json "$metallibs" "$(uptime)" <<'PY'
import json, sys
spm, xc = (json.load(open(p)) for p in sys.argv[1:3])
def rows(d): return {r["id"]: r for r in d["rows"]}
a, b = rows(spm), rows(xc)
di = max(abs(x - y) for k in a for x, y in zip(a[k]["intent"], b[k]["intent"]))
dd = max(abs(a[k]["datetime"] - b[k]["datetime"]) for k in a)
argmax = lambda p: max(range(len(p)), key=lambda i: p[i])
same_top1 = sum(argmax(a[k]["intent"]) == argmax(b[k]["intent"]) for k in a)
keys = ["intent_max_abs_dp_vs_chain", "datetime_max_abs_dp_vs_chain", "intent_max_abs_dp_vs_tree",
        "intent_top1_agree_chain", "datetime_top1_agree_chain", "accuracy_dev", "accuracy_holdout",
        "token_mismatch_rows", "latency", "load_s", "mlx_active_after_load_mb"]
out = {
    "schema": "cc-e2e-d1-parity/1",
    "uptime": sys.argv[5],
    "tolerance": 0.05,
    "swiftpm_release": {k: spm.get(k) for k in keys},
    "xcode_release": {k: xc.get(k) for k in keys},
    "xcode_metallib": sys.argv[4].strip(),
    "swiftpm_vs_xcode": {"intent_max_abs_diff": di, "datetime_max_abs_diff": dd, "intent_top1_same": f"{same_top1}/{len(a)}"},
}
json.dump(out, open(sys.argv[3], "w"), ensure_ascii=False, indent=2, sort_keys=True)
print(json.dumps({k: out[k] for k in ["swiftpm_vs_xcode"]}, ensure_ascii=False))
for name in ["swiftpm_release", "xcode_release"]:
    o = out[name]
    print(f"  {name}: intent max|Δp| {o['intent_max_abs_dp_vs_chain']:.4f} datetime {o['datetime_max_abs_dp_vs_chain']:.4f} "
          f"top1 {o['intent_top1_agree_chain']} dev {o['accuracy_dev']} holdout {o['accuracy_holdout']}")
PY
  check_models_untouched
fi

# ---------------------------------------------------------------- (c)
if (( ${steps[(Ie)c]} )); then
  step "(c) アプリのアイドル CPU（Release ビルド）"
  derived=$root/DerivedData/e2e-app
  (cd $root/app && xcodegen generate --quiet)
  # Release は既定で universal（x86_64 も）を作るが、CCEmbedding の Float16 が x86_64 macOS で使えずビルドが落ちる
  # （製品側の問題として報告済み）。計測は Apple Silicon の arm64 だけで行う。
  (cd $root/app && xcodebuild -project ContextCapture.xcodeproj -scheme ContextCapture -configuration Release \
      -derivedDataPath $derived -skipMacroValidation -skipPackagePluginValidation \
      ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build >| $work/c-build.log 2>&1) \
    || { grep -E "error:" $work/c-build.log | tail -n 30; exit 1 }
  app=$derived/Build/Products/Release/ContextCapture.app
  bin=$app/Contents/MacOS/ContextCapture
  data=$work/app-data-$stamp
  mkdir -p $data
  settle=${CC_E2E_IDLE_SETTLE:-60}
  samples=${CC_E2E_IDLE_SAMPLES:-60}

  # オンボーディングを出さない: 設定（UserDefaults の JSON 1 本）を **引数ドメイン**で渡す。
  # `-ContextCapture.settings.v1 <hex>` はこのプロセスの間だけ効き、ユーザーの defaults には書かない。
  # オンボーディングを飛ばすと ModelPreparationPipeline（manifest を書きうる）も走らない。
  settings_hex=$(printf '%s' '{"onboardingCompleted":true}' | xxd -p | tr -d '\n')

  if pgrep -x ContextCapture >/dev/null; then
    print "⚠️ 別の ContextCapture が動いている（計測は新しいプロセスだけを見る）: $(pgrep -x ContextCapture | tr '\n' ' ')"
  fi
  log_file=$work/c-app-$stamp.log
  /usr/bin/log stream --style compact --level info --predicate 'subsystem == "dev.ysogabe.ContextCapture"' >| $log_file 2>&1 &
  log_pid=$!
  wait_for_quiet
  launched_at=$(date +%s)
  open -n -a $app --env CC_DATA_DIR=$data --env CC_MODELS_DIR=$CC_MODELS_DIR --args -ContextCapture.settings.v1 "<$settings_hex>"
  pid=""
  for _ in {1..60}; do
    pid=$(pgrep -n -f "$bin" || true)
    [[ -n $pid ]] && break
    sleep 0.5
  done
  [[ -n $pid ]] || { kill $log_pid; print "アプリが起動しない"; exit 1 }
  print "  pid $pid（データ: $data）"
  # 環境変数が本当に渡ったか確かめる（渡っていないと既定のデータ置き場 ~/Library/Application Support/ContextCapture を使ってしまう）。
  # ps eww の環境と、アプリ自身が起動時にログへ書く「data: <dataRoot>」の両方を見る。どちらでも確かめられなければ計測をやめる。
  env_ok=0
  if ps eww -o command= -p $pid | grep -q "CC_DATA_DIR=$data"; then env_ok=1; fi
  for _ in {1..20}; do
    grep -qF -e "data: $data " $log_file && { env_ok=$(( env_ok + 2 )); break }
    sleep 0.5
  done
  if (( env_ok == 0 )); then
    print "⚠️ 起動したプロセスに CC_DATA_DIR が渡っていない。計測をやめて、このプロセス（$pid）だけを終了する"
    kill -TERM $pid 2>/dev/null || true
    kill $log_pid 2>/dev/null || true
    exit 1
  fi
  print "  CC_DATA_DIR の確認: ps eww=$(( env_ok & 1 )) log=$(( env_ok >> 1 ))"

  # モデル準備の完了 = 「search readiness: ready」（Whisper の読み込み → 埋め込みの準備の後に出る）。上限 10 分。
  ready=0
  for _ in {1..600}; do
    if grep -q "search readiness: ready" $log_file; then ready=1; break; fi
    if ! kill -0 $pid 2>/dev/null; then break; fi
    sleep 1
  done
  ready_after=$(( $(date +%s) - launched_at ))
  print "  ready=$ready（起動から ${ready_after}s）"
  print "  settle ${settle}s"
  sleep $settle

  cpu_samples=()
  cputime() { ps -o time= -p $pid | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }' }
  t0=$(cputime); w0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  for _ in {1..$samples}; do
    cpu_samples+=($(ps -o %cpu= -p $pid | tr -d ' '))
    sleep 1
  done
  t1=$(cputime); w1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  footprint_out=$(footprint -p $pid 2>/dev/null | grep -E "Footprint|phys_footprint" | head -n 3 | tr '\n' ' ' || true)
  rss_kb=$(ps -o rss= -p $pid | tr -d ' ')
  kill -TERM $pid 2>/dev/null || true
  sleep 2
  kill -0 $pid 2>/dev/null && kill -KILL $pid 2>/dev/null || true
  kill $log_pid 2>/dev/null || true

  /usr/bin/python3 - $results/$stamp-app-idle.json "$ready" "$ready_after" "$settle" "$t0" "$t1" "$w0" "$w1" "$footprint_out" "$rss_kb" \
      "$(uptime)" "$app" $log_file "$pid:$env_ok" ${cpu_samples[@]} <<'PY'
import json, sys, re
(out, ready, ready_after, settle, t0, t1, w0, w1, footprint, rss_kb, up, app, log_file, pid_env), samples = sys.argv[1:15], [float(x) for x in sys.argv[15:]]
cpu_time = float(t1) - float(t0); wall = float(w1) - float(w0)
log = open(log_file, errors="replace").read()
interesting = [l for l in log.splitlines() if re.search(r"whisper ready|embedder (ready|prepared)|search readiness|hotkey|failed|error", l)]
res = {
    "schema": "cc-e2e-app-idle/1",
    "app": app, "uptime": up,
    "pid": int(pid_env.split(":")[0]),
    "cc_data_dir_verified": {"ps_eww": bool(int(pid_env.split(":")[1]) & 1), "app_log": bool(int(pid_env.split(":")[1]) & 2)},
    "models_ready": ready == "1", "ready_after_launch_s": int(ready_after), "settle_s": int(settle),
    "ps_pcpu_samples": samples,
    "ps_pcpu_mean": sum(samples) / len(samples) if samples else None,
    "ps_pcpu_max": max(samples) if samples else None,
    "cpu_time_start_s": float(t0), "cpu_time_end_s": float(t1), "cpu_time_resolution_s": 0.01,
    "cpu_time_delta_s": cpu_time, "wall_s": wall,
    "cpu_percent_from_cpu_time": 100 * cpu_time / wall if wall > 0 else None,
    "footprint_cmd": footprint.strip(), "rss_mb_reference_only": int(rss_kb or 0) / 1024,
    "note": "ps の %cpu は最大 1 分の減衰平均（man ps）。区間の平均は CPU 時間の差 / 経過時間（cpu_percent_from_cpu_time）を正とする。",
    "log_excerpt": interesting[-40:],
}
json.dump(res, open(out, "w"), ensure_ascii=False, indent=2)
print(f"  idle CPU: ps mean {res['ps_pcpu_mean']:.2f}% max {res['ps_pcpu_max']:.2f}% / cpu-time {res['cpu_percent_from_cpu_time']:.2f}% ({cpu_time:.2f}s / {wall:.1f}s)")
print(f"  footprint: {res['footprint_cmd']}")
PY
  check_models_untouched
fi

# ---------------------------------------------------------------- MLX の Metal カーネル（default.metallib）の同一性
# SwiftPM のテスト・Xcode のテスト・アプリ本体の 3 つが同じ metallib なら、(b) の数値はアプリ本体にもそのまま当てはまる。
metallib_list=(
  "swiftpm_test:$pkg/.build/out/Products/Release/CCIntentTests.xctest/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
  "xcode_test:$root/DerivedData/e2e-kit/Build/Products/Release/CCIntentTests.xctest/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
  "app_release:$root/DerivedData/e2e-app/Build/Products/Release/ContextCapture.app/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
)
step "metallib の sha256"
/usr/bin/python3 - $results/$stamp-metallib.json $metallib_list <<'PY'
import hashlib, json, os, sys
out = {}
for item in sys.argv[2:]:
    name, path = item.split(":", 1)
    out[name] = {"path": path, "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest() if os.path.exists(path) else None,
                 "mtime": os.path.getmtime(path) if os.path.exists(path) else None}
shas = {v["sha256"] for v in out.values() if v["sha256"]}
res = {"schema": "cc-e2e-metallib/1", "builds": out, "all_identical": len(shas) == 1 and all(v["sha256"] for v in out.values())}
json.dump(res, open(sys.argv[1], "w"), indent=2)
for k, v in out.items(): print(f"  {k}: {v['sha256']}")
print(f"  all_identical: {res['all_identical']}")
PY

step "e2e: done（$results/$stamp-*.json）"
