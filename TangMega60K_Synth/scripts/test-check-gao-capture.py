"""Regression tests for old and 48 kHz GAO CSV exports."""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = Path(__file__).with_name('check-gao-capture.py')
spec = importlib.util.spec_from_file_location('check_gao_capture', SCRIPT)
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class GAOCaptureTests(unittest.TestCase):
    def test_existing_50_mhz_exports_unchanged(self):
        folder = ROOT / 'docs' / 'hardware' / 'gao-20260923'
        expected = json.loads((folder / 'zero_underrun_results.json').read_text())
        for name, reference in zip(('zero_underrun_run15.csv', 'zero_underrun_later.csv'), expected):
            result = checker.check(folder / name)
            self.assertEqual(Path(result.pop('file')), folder / name)
            reference.pop('file')
            self.assertEqual(result, reference)

    def augmented_capture(self, pll='1', valid='1', good='1', cycles='4B0000'):
        """Attach new GAO columns to a real capture to exercise parser logic."""
        source = (ROOT / 'docs' / 'hardware' / 'gao-20260923' /
                  'zero_underrun_run15.csv').read_text(encoding='utf-8-sig').splitlines()
        header = next(i for i, line in enumerate(source) if line.startswith('time unit:'))
        source[header] += 'pll_locked, clock_valid, clock_good, measured_cycles[25:0]'
        for i in range(header + 1, len(source)):
            if source[i]:
                source[i] += f'{pll}, {valid}, {good}, {cycles}'
        tmp = tempfile.TemporaryDirectory()
        path = Path(tmp.name) / 'capture.csv'
        path.write_text('\n'.join(source), encoding='utf-8')
        self.addCleanup(tmp.cleanup)
        return path

    def test_48_khz_clock_monitor(self):
        result = checker.check(self.augmented_capture(), audio_clock_hz=49_152_000)
        self.assertEqual(result['sample_rate_if_clock_hz'], 48_000)
        self.assertEqual(result['clock_monitor']['measured_cycles'], [4_915_200])
        self.assertEqual(result['clock_monitor']['result'], 'PASS')

    def test_48_khz_requires_explicit_clock_setting(self):
        with self.assertRaisesRegex(AssertionError, 'audio-clock-hz 49152000'):
            checker.check(self.augmented_capture())

    def test_48_khz_rejects_bad_status_and_frequency(self):
        with self.assertRaisesRegex(AssertionError, 'Clock ratio monitor failed'):
            checker.check(self.augmented_capture(good='0'), audio_clock_hz=49_152_000)
        with self.assertRaisesRegex(AssertionError, 'Audio clock ratio mismatch'):
            checker.check(self.augmented_capture(cycles='4B0003'), audio_clock_hz=49_152_000)


if __name__ == '__main__':
    unittest.main()
