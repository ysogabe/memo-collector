#!/usr/bin/env python3
"""Sequential Release comparison. Never builds or changes the product configuration."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

PRESETS = {
    'baseline': {'encoder': 'ane', 'decoder': 'ane', 'quiet': 0},
    'encoder-gpu': {'encoder': 'gpu', 'decoder': 'ane', 'quiet': 0},
    'decoder-gpu': {'encoder': 'ane', 'decoder': 'gpu', 'quiet': 0},
    'quiet-750': {'encoder': 'ane', 'decoder': 'ane', 'quiet': 750},
}


def plan(phase, candidate=None):
    if phase == 'screen':
        return [('baseline', 10), ('encoder-gpu', 10), ('quiet-750', 10), ('decoder-gpu', 10)]
    if candidate not in PRESETS or candidate == 'baseline':
        raise ValueError('confirmation requires a candidate')
    # ABBAAB, both condition orders for each preset; full quality on 30 fixtures first.
    return [('baseline', 30), (candidate, 30), (candidate, 10), ('baseline', 10), ('baseline', 10), (candidate, 10)]


def summarize(report, preset, expected_count, expected_order):
    config = report['configuration']
    expected = PRESETS[preset]
    names = {'ane': 'cpuAndNeuralEngine', 'gpu': 'cpuAndGPU'}
    if config != dict(audioEncoderAllowedComputeUnits=names[expected['encoder']],
                      textDecoderAllowedComputeUnits=names[expected['decoder']],
                      quietMilliseconds=expected['quiet'], conditionOrder=expected_order):
        raise ValueError('runner did not apply the requested configuration')
    if report['captureCountPerCondition'] != expected_count or set(report['conditions']) != {'without_triage', 'with_triage'}:
        raise ValueError('wrong measurement count/conditions')
    conditions = {}
    for name, c in report['conditions'].items():
        rows = c['captures']
        if c['saved'] != expected_count or c['indexed'] != expected_count or len(rows) != expected_count:
            raise ValueError('capture/index results incomplete')
        conditions[name] = dict(p90Ms=c['releaseToSaved']['p90Ms'], meanCER=c['meanCER'],
                                capturePhysicalPeakMB=c['capturePhysicalPeakMB'],
                                indexDeliveryP90Ms=c['savedToTriageEventDelivery']['index']['p90Ms'],
                                postBurstIndexDrainMs=c['postBurstIndexDrainMs'],
                                wallSeconds=c['wallSeconds'], cpuSeconds=c['cpuSeconds'],
                                encoderP90Ms=sorted(r['stt']['encodingSeconds'] * 1000 for r in rows)[int((expected_count * 9 + 9) // 10) - 1],
                                maxFallbacks=max(r['stt']['fallbacks'] for r in rows),
                                maxThermal=max(r['thermalBefore'] for r in rows))
    return dict(preset=preset, captureCountPerCondition=expected_count, configuration=config,
                thermalStart=report['thermalStart'], thermalEnd=report['thermalState'], conditions=conditions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=['screen', 'confirm'], required=True)
    parser.add_argument('--candidate', choices=list(PRESETS))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    trials = plan(args.phase, args.candidate)
    if not os.environ.get('CC_MODELS_DIR'):
        parser.error('CC_MODELS_DIR with prepared models is required')
    root = Path(__file__).resolve().parents[1]
    output = args.output or Path(tempfile.mkdtemp(prefix='cc-capture-stability-'))
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'summary.json').exists() or any(output.glob('trial-*')):
        parser.error('output already contains measurements; preserve them and choose a fresh directory')
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    report = dict(schemaVersion=1, phase=args.phase, sourceCommit=source, trials=[],
                  scope='M3 fixture hardware and real models; no real mic/screen/toast; no automatic adoption')
    for i, (preset, count) in enumerate(trials):
        folder = output / f'trial-{i+1:02d}-{preset}'
        folder.mkdir()
        folder = folder.resolve()
        order = ['without_triage', 'with_triage'] if i % 2 == 0 else ['with_triage', 'without_triage']
        p = PRESETS[preset]
        env = dict(os.environ, CC_CAPTURE_SKIP_BUILD='1', CC_PERF_ASSERT='0',
                   CC_CAPTURE_BENCH_OUTPUT=str(folder), CC_CAPTURE_BENCH_LIMIT=str(count),
                   CC_CAPTURE_STT_ENCODER=p['encoder'], CC_CAPTURE_STT_DECODER=p['decoder'],
                   CC_CAPTURE_QUIET_MS=str(p['quiet']), CC_CAPTURE_CONDITION_ORDER=','.join(order))
        with (folder / 'runner.log').open('w') as log:
            subprocess.run([str(root / 'scripts/capture-model-evaluation.sh')], cwd=root, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        raw = (folder / 'capture.json').read_bytes()
        row = summarize(json.loads(raw), preset, count, order)
        row['rawSHA256'] = hashlib.sha256(raw).hexdigest()
        row['rawRelativePath'] = str(folder.relative_to(output.resolve()) / 'capture.json')
        # Retain failing performance gates; continue the remaining comparative trials.
        with (folder / 'gate.log').open('w') as log:
            gate = subprocess.run(['python3', str(root / 'scripts/e2e-acceptance.py'), str(folder / 'capture.json'),
                                   '--output', str(folder / 'acceptance.json')], stdout=log, stderr=subprocess.STDOUT)
        if gate.returncode not in (0, 1):
            raise RuntimeError('acceptance evaluator failed to execute')
        row['performancePassed'] = json.loads((folder / 'acceptance.json').read_text())['passed']
        row['qualityPassed'] = all(c['meanCER'] <= .09 for c in row['conditions'].values())
        report['trials'].append(row)
        (output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{i+1}/{len(trials)} {preset}: concurrent P90 {row['conditions']['with_triage']['p90Ms']:.1f}ms; "
              f"CER {row['conditions']['with_triage']['meanCER']:.4f}; performance {row['performancePassed']}", flush=True)
    print(f'Comparison: {output / "summary.json"}', flush=True)


if __name__ == '__main__':
    main()
