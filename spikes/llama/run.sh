#!/bin/bash
# macOS; separate synthetic benchmark only. Requires prepared Core ML/GGUF files.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
: "${CC_MODELS_DIR:?prepare Core ML models first}"
: "${DIGUP_MODELS:?directory containing the two verified GGUF files}"
out=${CC_RUNTIME_RESULTS:-$(mktemp -d "${TMPDIR:-/tmp}/cc-runtime-results.XXXXXX")}
mkdir -p "$out"
verify() { local actual; actual=$(shasum -a 256 "$DIGUP_MODELS/$1" | cut -d' ' -f1); [[ "$actual" == "$2" ]] || { echo "hash mismatch: $1" >&2; exit 1; }; }
verify embeddinggemma-2-Q8_0.gguf 2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135
verify mmproj-embeddinggemma-2-Q8_0.gguf c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f
checkout=$(mktemp -d "${TMPDIR:-/tmp}/cc-digup-benchmark.XXXXXX")
git clone https://github.com/ARahim3/DigUp.git "$checkout"
git -C "$checkout" checkout -b codex/runtime-benchmark f9b8106ffb8308b4f48b76149d270f7c2e6b4918
(cd "$checkout" && scripts/build-llama.sh)
git -C "$checkout" apply "$root/spikes/llama/digup-benchmark.patch"
mkdir -p "$checkout/Sources/digup-bench"
cp "$root/spikes/llama/DigUpBenchmark.swift" "$checkout/Sources/digup-bench/main.swift"
cp "$root/spikes/llama/DigUpBenchmarkPackage.swift" "$checkout/Package.swift"
(cd "$checkout" && swift build --product digup-bench)
bin=$(cd "$checkout" && swift build --show-bin-path)
# Prime caches, then measure serial fresh processes. No OS cache is deleted.
"$bin/digup-bench" "$root/spikes/llama/inputs.json" "$out/llama-prime.json" 2> "$out/llama-prime.log"
for units in cpuAndGPU cpuAndNeuralEngine; do
  CC_RUNTIME_PRIME=1 CC_RUNTIME_BENCH_INPUTS="$root/spikes/llama/inputs.json" CC_RUNTIME_BENCH_OUTPUT="$out/coreml-prime.json" \
    CC_EMBEDDING_COMPUTE_UNITS="$units" swift test --package-path "$root/Packages/ContextCaptureKit" --filter RuntimeBenchmarkTests > "$out/coreml-prime-$units.log" 2>&1
done
# Serial launches: overlapping processes distort latency and footprint.
"$bin/digup-bench" "$root/spikes/llama/inputs.json" "$out/llama.json" 2> "$out/llama.log"
"$bin/digup-bench" "$root/spikes/llama/inputs.json" "$out/llama-query.json" --text-only 2> "$out/llama-query.log"
for mode in gpu ane gpu-query; do
  units=cpuAndGPU; text_only=0
  [[ "$mode" != ane ]] || units=cpuAndNeuralEngine
  [[ "$mode" != gpu-query ]] || text_only=1
  CC_RUNTIME_BENCH_INPUTS="$root/spikes/llama/inputs.json" CC_RUNTIME_BENCH_OUTPUT="$out/coreml-$mode.json" \
    CC_EMBEDDING_COMPUTE_UNITS="$units" CC_RUNTIME_TEXT_ONLY="$text_only" \
    swift test --package-path "$root/Packages/ContextCaptureKit" --filter RuntimeBenchmarkTests > "$out/coreml-$mode.log" 2>&1
done
python3 "$root/spikes/llama/summarize.py" "$out/llama.json" "$out/llama-query.json" "$out/coreml-gpu.json" "$out/coreml-ane.json" "$out/coreml-gpu-query.json"
printf 'Raw synthetic vectors and logs: %s\nTask-owned DigUp checkout: %s\n' "$out" "$checkout"
