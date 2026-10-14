#!/bin/bash
# Opt-in live model + MCP + PoC quality / latency job. Missing models fail.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
: "${CC_MODELS_DIR:?prepared fixed Core ML model root is required}"
out=${CC_SEARCH_EVAL_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/cc-live-search.XXXXXX")}
export CC_SEARCH_EVAL_OUTPUT="$out"
unset CC_SEARCH_CONTRACT_ONLY
"$root/scripts/eval-search.sh" --models "$CC_MODELS_DIR" --refresh --live-queries --poc "$@"
python3 "$root/evals/search/quality_gate.py" "$root/evals/search/live-model-baseline.json" "$out/baseline.json"
printf 'Live quality / latency report: %s\n' "$out/baseline.json"
