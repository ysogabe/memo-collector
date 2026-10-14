#!/usr/bin/env python3
"""Opt-in PRD performance gate. Unknown/missing measurements never become zero/pass."""
import argparse
import json
import math
import re
from pathlib import Path


def number(value):
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or value < 0:
        raise ValueError('missing or invalid measurement')
    return value


def assess(report):
    report = report.get('measurement', report)
    checks = []
    def add(name, value, limit, measured=True):
        try:
            value = number(value)
            checks.append({'name': name, 'value': value, 'limit': limit, 'passed': value <= limit, 'measured': measured})
        except ValueError:
            checks.append({'name': name, 'value': None, 'limit': limit, 'passed': False, 'measured': False})
    if 'conditions' in report:
        expected = report.get('captureCountPerCondition')
        valid_count = isinstance(expected, int) and not isinstance(expected, bool) and expected >= 10
        checks.append({'name': 'captureSampleCountAtLeast10', 'passed': valid_count, 'measured': valid_count})
        for name, row in report['conditions'].items():
            add(name + '.releaseToSavedP90Ms', row.get('releaseToSaved', {}).get('p90Ms'), 2000)
            add(name + '.peakPhysicalMB', row.get('capturePhysicalPeakMB'), 10000)
            reliable = valid_count and row.get('saved') == expected and row.get('indexed') == expected and row.get('releaseToSaved', {}).get('count') == expected
            checks.append({'name': name + '.savedAndIndexedAll', 'passed': reliable, 'measured': reliable})
        if set(report['conditions']) != {'without_triage', 'with_triage'}:
            checks.append({'name': 'requiredCaptureConditions', 'passed': False, 'measured': False})
        add('idleAfterD1UnloadPhysicalMB', report.get('memory', {}).get('afterIntentUnload', {}).get('physicalMB'), 4000)
    elif report.get('schema') == 'cc-e2e-app-idle/1':
        add('idleCPUPercent', report.get('cpu_percent_from_cpu_time'), 1)
        physical = report.get('physical_footprint_mb')
        if physical is None:
            match = re.search(r'\bphys_footprint:\s*([0-9.]+)\s*(KB|MB|GB)\b', report.get('footprint_cmd', ''))
            if match:
                # footprint's displayed binary units, conservatively converted to decimal MB.
                physical = float(match.group(1)) * {'KB': 1024 / 1e6, 'MB': 1024**2 / 1e6, 'GB': 1024**3 / 1e6}[match.group(2)]
        add('idlePhysicalMB', physical, 4000)
        if report.get('models_ready') is not True:
            checks.append({'name': 'modelsPrepared', 'passed': False, 'measured': False})
    else:
        raise ValueError('unsupported report; use actual coordinator capture.json or app-idle.json')
    return {'schema': 'cc-e2e-acceptance/1', 'passed': bool(checks) and all(c['passed'] for c in checks),
            'checks': checks, 'scope': 'fixture capture/d1-unload memory or actual app idle CPU; real hotkey/microphone/toast checks remain separate'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('report', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = assess(json.loads(args.report.read_text()))
    if args.output:
        args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)
