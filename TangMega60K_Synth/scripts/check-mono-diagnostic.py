"""Check decoded external I2S PCM at the engine's 48 kHz sample rate."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "sim/mono_diagnostic_results"
PCM = np.genfromtxt(OUT / "decoded-pcm.csv", delimiter=",", names=True, dtype=np.int64)
FS = 48000
MIDI = [64, 65, 67, 62, 60, 64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 62, 62, 60]


def peak_near(signal, expected):
    signal = signal.astype(np.float64)
    signal -= np.mean(signal)
    fft = np.abs(np.fft.rfft(signal * np.hanning(len(signal)), 131072))
    freq = np.fft.rfftfreq(131072, 1 / FS)
    search = np.flatnonzero((freq > expected - 18) & (freq < expected + 18))
    k = search[np.argmax(fft[search])]
    a, b, c = np.log(np.maximum(fft[k - 1:k + 2], 1e-30))
    delta = 0.5 * (a - c) / (a - 2 * b + c)
    return (k + delta) * FS / 131072, float(fft[k]), fft, freq


rows = []
for index, midi in enumerate(MIDI):
    # HOLD excludes the release/gap. Skip 1000 samples (>20 ms) to allow the
    # unchanged sine attack and command/FIFO latency before frequency checks.
    group = PCM[(PCM["index"] == index) & (PCM["stage"] == 2)]
    if len(group) < 3500:
        raise AssertionError(f"Too little actual I2S PCM for index {index}: {len(group)}")
    left = group["left"][1000:3900]
    right = group["right"][1000:3900]
    f0 = 440 * 2 ** ((midi - 69) / 12)
    expected = f0 if index < 5 else f0 * (2.000011 if midi <= 64 else 2.004533)
    measured, amplitude, spectrum, freq = peak_near(left, expected)
    if abs(measured - expected) > 3:
        raise AssertionError(f"Wrong note index={index} MIDI={midi}: {measured:.3f} vs {expected:.3f} Hz")
    if index < 5:
        dominant = float(freq[np.argmax(spectrum[1:]) + 1])
        if abs(dominant - f0) > 3:
            raise AssertionError(f"Sine is not dominated by expected fundamental index={index}")
    peak = int(max(np.max(np.abs(group["left"])), np.max(np.abs(group["right"]))))
    rms = float(np.sqrt(np.mean(left.astype(float) ** 2)))
    if peak >= 8388607 or rms < 20000:
        raise AssertionError(f"Clipped or low digital level diagnostic index={index} peak={peak} RMS={rms}")
    if index < 5 and not np.array_equal(left, right * 3):
        # Per-channel mixer rounding can differ by 256 PCM counts at SHIFT=7.
        if np.max(np.abs(left - right * 3)) > 384:
            raise AssertionError(f"Unexpected sine stereo panning index={index}")
    rows.append({"index": index, "midi": midi, "timbre": "sine" if index < 5 else "additive piano",
                 "expectedPeakHz": round(expected, 4), "measuredPeakHz": round(measured, 4),
                 "peak24bit": peak, "leftRmsDbFS": round(20 * np.log10(rms / 8388608), 2),
                 "holdFrames": int(len(group))})

result = {"status": "PASS", "method": "decoded external Philips I2S; engine sample-domain Fs=48000; serial clock accelerated in simulation",
          "recordedAtUtc": datetime.now(timezone.utc).isoformat(),
          "decodedPcmSha256": hashlib.sha256((OUT / "decoded-pcm.csv").read_bytes()).hexdigest(),
          "decodedFrames": int(len(PCM)),
          "notes": 21, "waveforms": rows, "gainVsProductionDb": round(20 * np.log10(64), 5),
          "gainScaling": "HDL test checks every accepted sample against SHIFT=1 reference multiplied by 64",
          "clippedSamples": int(np.sum((np.abs(PCM["left"]) >= 8388607) | (np.abs(PCM["right"]) >= 8388607))),
          "physicalAudioValidated": False}
(OUT / "spectral-results.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"MONO DIAGNOSTIC PCM PASSED notes={len(rows)} changing_pitch=21 gain=+36.12360dB no_clipping=1 actual_I2S_decode=1")
for row in rows[:5]:
    print(f"Sine MIDI {row['midi']}: {row['measuredPeakHz']} Hz, RMS {row['leftRmsDbFS']} dBFS")
