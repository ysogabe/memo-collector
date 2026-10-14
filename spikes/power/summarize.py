#!/usr/bin/env python3
"""Read labelled powermetrics counters; correlate fully contained sampling intervals."""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import re
import statistics

POWER = re.compile(r'\s*(CPU|GPU|ANE) Power:\s*([0-9.]+)\s*(mW|W)\s*')
RESIDENCY = re.compile(r'^\s*([^\n:]+ active residency):\s*([0-9.]+)%', re.M)
HEADER = re.compile(r'^\s*\(([^)]+)\)\s*\(([0-9.]+)ms elapsed\)')


def parse(text):
    samples = []
    for block in re.split(r'\*\*\* Sampled system activity', text):
        powers, residencies = {}, {}
        gpu_sampler, section = None, 'processor'
        for line in block.splitlines():
            if line.startswith('**** GPU usage'):
                section = 'gpu'
            elif line.startswith('**** Processor usage'):
                section = 'processor'
            match = POWER.fullmatch(line)
            if not match:
                continue
            name, value, unit = match.groups()
            value = float(value) / (1000 if unit == 'mW' else 1)
            if not math.isfinite(value) or value < 0:
                raise ValueError('invalid power')
            if section == 'gpu' and name == 'GPU':
                if gpu_sampler is not None:
                    raise ValueError('duplicate GPU sampler counter')
                gpu_sampler = value
                continue
            if name in powers:
                raise ValueError('duplicate processor counter or missing sample boundary')
            powers[name] = value
        for name, value in RESIDENCY.findall(block):
            value = float(value)
            if not 0 <= value <= 100:
                raise ValueError('invalid residency')
            residencies[name.strip()] = value
        if not powers:
            continue
        elapsed = re.search(r'\(([0-9.]+)ms elapsed\)', block)
        interval = float(elapsed.group(1)) / 1000 if elapsed else None
        if interval is not None and (not math.isfinite(interval) or interval <= 0):
            raise ValueError('invalid sampling interval')
        header, epoch = HEADER.match(block), None
        if header:
            try:
                epoch = datetime.strptime(header.group(1), '%a %b %d %H:%M:%S %Y %z').timestamp()
            except ValueError:
                pass  # Unknown timestamp format can be summarized, but cannot be aligned.
        samples.append({'powerWatts': powers, 'gpuSamplerPowerWatts': gpu_sampler,
                        'activeResidencyPercent': residencies, 'intervalSeconds': interval,
                        'epochSeconds': epoch})
    if not samples:
        raise ValueError('no recognized power sample; retain raw output and adapt to actual OS format')
    return samples


def select_window(samples, start, end, margin=1):
    """Sample time denotes interval end; exclude boundary samples and timestamp rounding."""
    if not all(math.isfinite(v) for v in (start, end, margin)) or margin < 0 or end <= start + 2 * margin:
        raise ValueError('invalid measurement window')
    if any(s['epochSeconds'] is None or s['intervalSeconds'] is None for s in samples):
        raise ValueError('timestamp and duration required for phase correlation')
    rows = [s for s in samples if s['epochSeconds'] - s['intervalSeconds'] >= start + margin
            and s['epochSeconds'] <= end - margin]
    if not rows:
        raise ValueError('no fully contained samples in measurement window')
    result = summarize(rows)
    result['window'] = {'startEpochSeconds': start, 'endEpochSeconds': end,
                        'boundaryMarginSeconds': margin, 'wallSeconds': end - start,
                        'sampledSeconds': sum(s['intervalSeconds'] for s in rows)}
    return result


def summarize(samples):
    if not samples:
        raise ValueError('no samples')
    result = {'sampleCount': len(samples), 'channels': {}, 'activeResidency': {}, 'notes': [
        'SoC estimates, not app-attributed power; compare workload against idle on the SAME device.',
        'Missing counters are unavailable, not zero. ANE power is not ANE utilization.',
        'meanWatts is the arithmetic sample mean; estimatedJoules integrates the reported intervals.']}
    for name in ['CPU', 'GPU', 'ANE']:
        rows = [s for s in samples if name in s['powerWatts']]
        values = [s['powerWatts'][name] for s in rows]
        if not values:
            result['channels'][name] = {'available': False}
            continue
        complete = all(s['intervalSeconds'] is not None for s in rows)
        duration = sum(s['intervalSeconds'] for s in rows) if complete else None
        energy = sum(s['powerWatts'][name] * s['intervalSeconds'] for s in rows) if complete else None
        result['channels'][name] = {'available': True, 'samples': len(values),
                                   'meanWatts': statistics.mean(values), 'maxWatts': max(values),
                                   'durationSeconds': duration, 'estimatedJoules': energy}
    gpu = [s['gpuSamplerPowerWatts'] for s in samples if s['gpuSamplerPowerWatts'] is not None]
    if gpu:
        result['gpuSamplerPower'] = {'samples': len(gpu), 'meanWatts': statistics.mean(gpu),
                                    'maxWatts': max(gpu), 'scope': 'GPU usage section; separate from processor GPU Power'}
    names = sorted({name for s in samples for name in s['activeResidencyPercent']})
    for name in names:
        values = [s['activeResidencyPercent'][name] for s in samples if name in s['activeResidencyPercent']]
        result['activeResidency'][name] = {'samples': len(values), 'meanPercent': statistics.mean(values),
                                         'maxPercent': max(values)}
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('raw_power_text', type=Path)
    parser.add_argument('output_json', type=Path)
    parser.add_argument('--windows', type=Path, help='JSON object: phase -> [startEpochSeconds, endEpochSeconds]')
    args = parser.parse_args()
    samples = parse(args.raw_power_text.read_text(errors='replace'))
    result = summarize(samples)
    if args.windows:
        windows = json.loads(args.windows.read_text())
        result['windows'] = {name: select_window(samples, *bounds) for name, bounds in windows.items()}
    args.output_json.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'activeResidency'}, indent=2))
