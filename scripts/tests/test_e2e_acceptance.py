import importlib.util
from pathlib import Path
import unittest
spec = importlib.util.spec_from_file_location('gate', Path(__file__).resolve().parents[1] / 'e2e-acceptance.py')
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

class AcceptanceTests(unittest.TestCase):
    def capture(self):
        return {'captureCountPerCondition': 10, 'conditions': {name: {'saved': 10, 'indexed': 10, 'releaseToSaved': {'p90Ms': 1999, 'count': 10}, 'capturePhysicalPeakMB': 4000}
                for name in ['without_triage', 'with_triage']}, 'memory': {'afterIntentUnload': {'physicalMB': 1000}}}
    def test_boundary_and_slow_concurrent_capture(self):
        report = self.capture()
        self.assertTrue(gate.assess(report)['passed'])
        report['conditions']['with_triage']['releaseToSaved']['p90Ms'] = 2000
        self.assertTrue(gate.assess(report)['passed'])
        report['conditions']['with_triage']['releaseToSaved']['p90Ms'] = 2001
        self.assertFalse(gate.assess(report)['passed'])
    def test_absent_nan_and_boolean_measurements_fail(self):
        for value in [None, float('nan'), True, -1]:
            report = self.capture()
            report['memory']['afterIntentUnload']['physicalMB'] = value
            self.assertFalse(gate.assess(report)['passed'])
        report = self.capture()
        del report['conditions']['with_triage']
        self.assertFalse(gate.assess(report)['passed'])
    def test_idle_unprepared_or_over_budget_fails(self):
        report = {'schema': 'cc-e2e-app-idle/1', 'cpu_percent_from_cpu_time': .1, 'models_ready': True, 'physical_footprint_mb': 200}
        self.assertTrue(gate.assess(report)['passed'])
        report['cpu_percent_from_cpu_time'] = 1.01
        self.assertFalse(gate.assess(report)['passed'])
        report['cpu_percent_from_cpu_time'] = 0
        report['models_ready'] = False
        self.assertFalse(gate.assess(report)['passed'])
    def test_zero_captures_or_unindexed_records_fail(self):
        report = self.capture()
        report['conditions']['with_triage']['indexed'] = 9
        self.assertFalse(gate.assess(report)['passed'])
        report = self.capture()
        report['captureCountPerCondition'] = 0
        self.assertFalse(gate.assess(report)['passed'])
    def test_old_idle_footprint_format_and_missing_memory(self):
        report = {'schema': 'cc-e2e-app-idle/1', 'cpu_percent_from_cpu_time': 0, 'models_ready': True,
                  'footprint_cmd': 'phys_footprint: 196 MB phys_footprint_peak: 2889 MB'}
        self.assertTrue(gate.assess(report)['passed'])
        del report['footprint_cmd']
        self.assertFalse(gate.assess(report)['passed'])
    def test_legacy_incomplete_report_is_not_accepted(self):
        with self.assertRaises(ValueError):gate.assess({})

if __name__ == '__main__':unittest.main()
