#!/bin/zsh
# 全 QA コマンドの入口（docs/plans/mvp-implementation.md §4）。1 つでも落ちたら非 0 で終わる。
#   1) Packages/ContextCaptureKit: swift build && swift test
#      （Swift 6.4 の SwiftPM は mlx-swift の default.metallib をビルドするので、MLX の Metal テストもこれで走る）
#   2) app: xcodegen generate && xcodebuild -scheme ContextCapture -configuration Debug build
# モデルが必要なテストは CC_MODELS_DIR にモデルが無ければ XCTSkip する。例:
#   CC_MODELS_DIR=$PWD/spikes/runtime/models scripts/check.sh
# 環境変数:
#   CC_CHECK_SKIP_APP=1  … 2) を飛ばす（パッケージだけ確かめたいとき）
#   CC_TEST_FILTER=<regex> … swift test --filter に渡す
set -euo pipefail

root=${0:A:h:h}
pkg=$root/Packages/ContextCaptureKit
derived=$root/DerivedData
logs=$derived/check-logs
mkdir -p $logs

step() { print -P "%B==> $1%b" }

step "[1/2] ContextCaptureKit: swift build"
(cd $pkg && swift build --disable-keychain)

step "[1/2] ContextCaptureKit: swift test"
test_args=(--disable-keychain)
[[ -n ${CC_TEST_FILTER:-} ]] && test_args+=(--filter $CC_TEST_FILTER)
(cd $pkg && swift test $test_args)

if [[ ${CC_CHECK_SKIP_APP:-0} == 1 ]]; then
  step "[2/2] app: CC_CHECK_SKIP_APP=1 のため省略"
else
  step "[2/2] app: xcodegen generate"
  (cd $root/app && xcodegen generate --quiet)

  step "[2/2] app: xcodebuild build (Debug)"
  log=$logs/app-build.log
  if ! (cd $root/app && xcodebuild \
        -project ContextCapture.xcodeproj \
        -scheme ContextCapture \
        -configuration Debug \
        -derivedDataPath $derived \
        -skipMacroValidation -skipPackagePluginValidation \
        build >| $log 2>&1); then
    grep -E "error:|\*\* BUILD" $log | tail -n 40 || true
    print "xcodebuild failed. full log: $log"
    exit 1
  fi
  grep -E "\*\* BUILD" $log
  print "app: $derived/Build/Products/Debug/ContextCapture.app"

  step "[2/2] app: xcodebuild test（AppCoordinator の状態機械など）"
  log=$logs/app-test.log
  if ! (cd $root/app && xcodebuild \
        -project ContextCapture.xcodeproj \
        -scheme ContextCapture \
        -derivedDataPath $derived \
        -skipMacroValidation -skipPackagePluginValidation \
        test >| $log 2>&1); then
    grep -E "error:|failed|\*\* TEST" $log | tail -n 40 || true
    print "xcodebuild test failed. full log: $log"
    exit 1
  fi
  grep -E "Executed [0-9]+ tests|\*\* TEST" $log | tail -n 2
fi

step "check.sh: all green"
