#!/bin/zsh
# Evaluates synthetic search data in a temporary database; never opens CC_DATA_DIR.
set -euo pipefail
root=${0:A:h:h}
runner=$root/evals/search/Runner
out=${CC_SEARCH_EVAL_OUTPUT:-${TMPDIR:-/private/tmp}/cc-search-evaluation}
mkdir -p "$out"
swift build --package-path "$runner" --disable-keychain --product cc-eval-search
bin=$(swift build --package-path "$runner" --show-bin-path)
"$bin/cc-eval-search" \
  --fixtures "$root/evals/search" --cache "$out/coreml-vectors.json" \
  --output "$out/baseline.json" "$@"
