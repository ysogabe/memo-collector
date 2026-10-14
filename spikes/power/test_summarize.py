import unittest
from summarize import parse,summarize
class PowerTests(unittest.TestCase):
 def test_units_duration_and_available_counters(self):
  sample='*** Sampled system activity (example) (1000.0ms elapsed) ***\nCPU Power: 1000 mW\nGPU Power: 0.5 W\nANE Power: 0 mW\n**** GPU usage ****\nGPU HW active residency: 20.0%\nGPU Power: 510 mW\n'
  r=summarize(parse(sample+sample))
  self.assertEqual(r['channels']['CPU']['estimatedJoules'],2)
  self.assertEqual(r['channels']['GPU']['meanWatts'],.5)
  self.assertEqual(r['gpuSamplerPower']['meanWatts'],.51)
  self.assertEqual(r['activeResidency']['GPU HW active residency']['meanPercent'],20)
 def test_missing_counters_and_duration_are_unavailable(self):
  r=summarize(parse('CPU Power: 12 mW\n'))
  self.assertFalse(r['channels']['ANE']['available']);self.assertIsNone(r['channels']['CPU']['estimatedJoules'])
 def test_unrecognized_and_duplicate_samples_fail(self):
  for text in ['sudo: a password is required','CPU Power: 3 mW\nCPU Power: 4 mW\n']:
   with self.assertRaises(ValueError):parse(text)

class PhaseTests(unittest.TestCase):
 def test_timezone_and_fully_contained_intervals(self):
  from summarize import select_window
  samples=parse(''.join(f'*** Sampled system activity (Wed Oct 14 21:32:{second:02d} 2026 +0900) (1000ms elapsed) ***\nCPU Power: 1 W\n' for second in range(31,37)))
  start=samples[0]['epochSeconds']
  self.assertEqual(start,1791981151)
  result=select_window(samples,start,start+5,margin=1)
  self.assertEqual(result['sampleCount'],3)
  self.assertEqual(result['channels']['CPU']['estimatedJoules'],3)
 def test_cannot_align_unknown_time_or_empty_window(self):
  from summarize import select_window
  with self.assertRaises(ValueError):select_window(parse('CPU Power: 1 W\n'),0,10)
  samples=parse('*** Sampled system activity (Wed Oct 14 21:32:31 2026 +0900) (1000ms elapsed) ***\nCPU Power: 1 W\n')
  with self.assertRaises(ValueError):select_window(samples,0,10)
 def test_invalid_interval_fails(self):
  with self.assertRaises(ValueError):parse('*** Sampled system activity (example) (0ms elapsed) ***\nCPU Power: 1 W\n')

if __name__=='__main__':unittest.main()
