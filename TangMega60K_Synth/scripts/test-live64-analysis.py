"""Synthetic fixtures verify the FFT checker rejects missing tones and clipping.
These are analyzer unit tests, NOT RTL verification evidence.
"""
import importlib.util
import json
from pathlib import Path

import numpy as np

spec = importlib.util.spec_from_file_location("live64_fft", Path(__file__).with_name("analyze-live64.py"))
fft = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fft)
project = Path(__file__).resolve().parent.parent
table = fft.frequency_table(project / "rtl/audio/rom")
t = np.arange(fft.N)/fft.FS
samples = np.zeros((fft.N, 2))
first = None
for row in table:
    tone = np.sin(2*np.pi*row["quantized_hz"]*t)[:, None] * np.array(
        [row["expected_left_peak"], row["expected_right_peak"]])
    samples += tone
    if first is None:
        first = tone

def rejected(x):
    return bool(fft.analyze(np.rint(x), table)[2])

tests = {
    "synthetic_64_tones_accepted": not rejected(samples),
    "missing_lowest_tone_rejected": rejected(samples-first),
    "half_gain_rejected": rejected(samples/2),
    "silence_rejected": rejected(np.zeros_like(samples)),
}
clipped = samples.copy()
clipped[100, 0] = 8388607
tests["single_rail_sample_rejected"] = rejected(clipped)
result = project / "sim/live64_results/analyzer_tests.json"
result.parent.mkdir(parents=True, exist_ok=True)
result.write_text(json.dumps(tests, indent=2), encoding="utf-8")
print(json.dumps(tests, indent=2))
if not all(tests.values()):
    raise SystemExit("FFT ANALYZER UNIT TEST FAILED")
print("FFT ANALYZER UNIT TESTS PASSED (synthetic fixtures only)")
