"""Reproducible Q2.14 Goertzel coefficients: no sampled music/PCM."""
import math
from pathlib import Path

root = Path(__file__).resolve().parents[1]
out = root / 'rtl/visual/goertzel_1024_64.hex'
out.write_text(''.join(f'{round(32768 * math.cos(2 * math.pi * k / 1024)) & 0xffff:04x}\n'
                       for k in range(1, 65)), encoding='ascii')
print(out)
