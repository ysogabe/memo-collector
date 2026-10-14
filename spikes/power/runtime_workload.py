#!/usr/bin/env python3
"""Serial prebuilt Release workloads, timestamped for the independent SoC sampler."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('--coreml-tests', required=True, type=Path, help='prebuilt Release CCEmbeddingTests.xctest')
parser.add_argument('--llama-bin', required=True, type=Path, help='prebuilt Release digup-bench')
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
models = Path(os.environ['DIGUP_MODELS'])
for name, expected in [
    ('embeddinggemma-2-Q8_0.gguf', '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135'),
    ('mmproj-embeddinggemma-2-Q8_0.gguf', 'c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f')]:
    with (models / name).open('rb') as file:
        hasher = hashlib.sha256()
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            hasher.update(chunk)
        actual = hasher.hexdigest()
    if actual != expected:
        raise SystemExit(f'GGUF hash mismatch: {name}')
if 'CC_MODELS_DIR' not in os.environ:
    raise SystemExit('CC_MODELS_DIR required')
args.output.mkdir(parents=True, exist_ok=True)
windows = {}
phases = args.output / 'phases.jsonl'
phases.write_text('')


def mark(phase):
    epoch = time.time()
    with phases.open('a') as file:
        file.write(json.dumps({'phase': phase, 'epochSeconds': epoch}) + '\n')
    return epoch


idle = mark('idle:start')
time.sleep(10)
windows['idle'] = [idle, mark('idle:end')]
for name, units in [('coreml-gpu', 'cpuAndGPU'), ('coreml-ane', 'cpuAndNeuralEngine'), ('llama', None)]:
    output = args.output / f'{name}.json'
    if output.exists():
        raise SystemExit(f'refusing stale measurement: {output}')
    env = dict(os.environ, CC_RUNTIME_BENCH_INPUTS=str(root / 'spikes/llama/inputs.json'),
               CC_RUNTIME_BENCH_OUTPUT=str(output), CC_RUNTIME_TEXT_ONLY='0')
    env.pop('CC_RUNTIME_PRIME', None)
    if units:
        env['CC_EMBEDDING_COMPUTE_UNITS'] = units
        command = ['/usr/bin/xcrun', 'xctest', '-XCTest',
                   'CCEmbeddingTests.RuntimeBenchmarkTests/testRuntimeBenchmark', str(args.coreml_tests.resolve())]
    else:
        command = [str(args.llama_bin.resolve()), env['CC_RUNTIME_BENCH_INPUTS'], str(output)]
    start = mark(name + ':start')
    with (args.output / f'{name}.log').open('w') as log:
        subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    end = mark(name + ':end')
    result = json.loads(output.read_text())  # A skip or absent output fails.
    if len(result['rows']) != 232 or any(len(row['milliseconds']) != 3 for row in result['rows']):
        raise SystemExit(f'incomplete workload: {name}')
    windows[name] = [start, end]
    print(name, round(end - start, 3), 'seconds', flush=True)
    (args.output / 'windows.json').write_text(json.dumps(windows, indent=2) + '\n')
