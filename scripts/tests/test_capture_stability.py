import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('capture_stability', Path(__file__).parents[1] / 'capture-stability.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CaptureStabilityContracts(unittest.TestCase):
    def report(self):
        condition = dict(saved=10, indexed=10, captures=[dict(stt=dict(encodingSeconds=1, fallbacks=0), thermalBefore=0)] * 10,
                         meanCER=.05, releaseToSaved=dict(p90Ms=1500), capturePhysicalPeakMB=3900,
                         savedToTriageEventDelivery=dict(index=dict(p90Ms=2000)), postBurstIndexDrainMs=1000,
                         wallSeconds=30, cpuSeconds=15)
        return dict(configuration=dict(audioEncoderAllowedComputeUnits='cpuAndNeuralEngine', textDecoderAllowedComputeUnits='cpuAndNeuralEngine',
                                       quietMilliseconds=0, conditionOrder=['without_triage', 'with_triage']),
                    captureCountPerCondition=10, thermalStart=0, thermalState=0,
                    conditions=dict(without_triage=copy.deepcopy(condition), with_triage=copy.deepcopy(condition)))

    def test_confirmation_alternates_and_includes_all_fixture_quality(self):
        trials = module.plan('confirm', 'quiet-750')
        self.assertEqual([p for p, n in trials], ['baseline', 'quiet-750', 'quiet-750', 'baseline', 'baseline', 'quiet-750'])
        self.assertEqual([n for p, n in trials], [30, 30, 10, 10, 10, 10])
        with self.assertRaises(ValueError):
            module.plan('confirm', 'baseline')

    def test_requested_configuration_must_match_actual_report(self):
        with self.assertRaises(ValueError):
            module.summarize(self.report(), 'encoder-gpu', 10, ['without_triage', 'with_triage'])
        with self.assertRaises(ValueError):
            module.summarize(self.report(), 'baseline', 10, ['with_triage', 'without_triage'])

    def test_missing_measurements_and_incomplete_index_fail(self):
        report = self.report(); report['conditions']['with_triage']['indexed'] = 9
        with self.assertRaises(ValueError):
            module.summarize(report, 'baseline', 10, ['without_triage', 'with_triage'])
        report = self.report(); report['conditions']['with_triage']['captures'].pop()
        with self.assertRaises(ValueError):
            module.summarize(report, 'baseline', 10, ['without_triage', 'with_triage'])

    def test_quality_and_stt_details_are_preserved(self):
        row = module.summarize(self.report(), 'baseline', 10, ['without_triage', 'with_triage'])
        self.assertEqual(row['conditions']['with_triage']['encoderP90Ms'], 1000)
        self.assertEqual(row['conditions']['with_triage']['meanCER'], .05)
        self.assertEqual(row['conditions']['with_triage']['indexDeliveryP90Ms'], 2000)
