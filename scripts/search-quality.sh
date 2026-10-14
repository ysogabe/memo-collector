#!/bin/bash
# Actual model-free retrieval and quality gate. Never opens CC_DATA_DIR or models.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runner="$root/evals/search/Runner"
out=${CC_SEARCH_QA_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/cc-search-quality.XXXXXX")}
mkdir -p "$out"
python3 "$root/evals/search/verify-fixtures.py"
python3 -m unittest discover -s "$root/evals/search/tests" -p 'test_*.py' -v
export CC_SEARCH_CONTRACT_ONLY=1
swift test --package-path "$runner" --disable-keychain
bin=$(swift build --package-path "$runner" --show-bin-path)
"$bin/cc-search-contract" "$root/evals/search" "$out/contract.json"
python3 "$root/evals/search/quality_gate.py" "$root/evals/search/golden-quality.json" "$out/contract.json"
printf 'Fresh quality report: %s\n' "$out/contract.json"
