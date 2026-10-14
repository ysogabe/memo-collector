#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
: "${CC_MODELS_DIR:?existing prepared models directory is required}"
python3 -m unittest discover -s "$root/spikes/worker" -p 'test_*.py' -v
swift build --package-path "$root/evals/search/Runner" --disable-keychain --product cc-query-worker
bin=$(swift build --package-path "$root/evals/search/Runner" --show-bin-path)
python3 "$root/spikes/worker/benchmark.py" "$bin/cc-query-worker"
