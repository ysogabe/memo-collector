#!/bin/bash
# Actual capture coordinator with fixture hardware and real models, Release only.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${CC_MODELS_DIR:?prepared fixed models root is required}"
out=${CC_CAPTURE_BENCH_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/cc-capture-models.XXXXXX")}
mkdir -p "$out"
out=$(cd "$out" && pwd)
(cd "$root/app" && xcodegen generate --quiet)
if [[ ${CC_CAPTURE_SKIP_BUILD:-0} != 1 ]]; then
 xcodebuild -project "$root/app/ContextCapture.xcodeproj" -scheme ContextCapture \
 -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -destination 'platform=macOS' -derivedDataPath "$root/DerivedData" \
 -skipMacroValidation -skipPackagePluginValidation build-for-testing > "$out/xcode-build.log" 2>&1
fi
[[ ${CC_CAPTURE_BUILD_ONLY:-0} != 1 ]] || exit 0
measurement_stamp=$(mktemp "$out/measurement-start.XXXXXX")
TEST_RUNNER_CC_MODELS_DIR="$CC_MODELS_DIR" TEST_RUNNER_CC_RUN_CAPTURE_BENCH=1 \
 TEST_RUNNER_CC_CAPTURE_BENCH_OUT="$out/capture.json" TEST_RUNNER_CC_CAPTURE_BENCH_LIMIT="${CC_CAPTURE_BENCH_LIMIT:-10}" \
 xcodebuild -project "$root/app/ContextCapture.xcodeproj" -scheme ContextCapture \
 -configuration Release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -destination 'platform=macOS' -derivedDataPath "$root/DerivedData" \
 -skipMacroValidation -skipPackagePluginValidation \
 -only-testing:ContextCaptureTests/LiveCaptureBenchmarkTests test-without-building > "$out/xcode-test.log" 2>&1
[[ -s "$out/capture.json" && "$out/capture.json" -nt "$measurement_stamp" ]] || { echo 'measurement absent (skip is not success)' >&2; exit 1; }
printf 'Capture measurement: %s\n' "$out/capture.json"

if [[ ${CC_PERF_ASSERT:-0} == 1 ]]; then
 python3 "$root/scripts/e2e-acceptance.py" "$out/capture.json" --output "$out/acceptance.json"
fi
