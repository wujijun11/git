"""Independent 64-tone FFT check; generated PCM is evidence, never a ROM source.
Requires Python 3 + numpy. No plotting package is needed for the static SVG.
"""
import argparse
import csv
import json
import math
from pathlib import Path

import numpy as np

FS = 48000
N = 262144
BASE = 36
COUNT = 64
VELOCITY = 100


def frequency_table(rom):
    midi = [int(x, 16) for x in (rom / "midi.hex").read_text().split()]
    velocity = [int(x, 16) for x in (rom / "velocity.hex").read_text().split()][VELOCITY]
    rows = []
    for i in range(COUNT):
        note = BASE + i
        theory = 440 * 2 ** ((note - 69) / 12)
        # Independently compute FTW and check the actual ROM matches 48 kHz.
        ftw = round(theory * 2**32 / FS)
        if midi[note] != ftw:
            raise ValueError(f"MIDI ROM mismatch at note {note}")
        amplitude = 32767 * 0.75 * (velocity / 32768) * 2  # existing MASTER_SHIFT=1
        rows.append(dict(index=i, midi_note=note, source=63,
                         theoretical_hz=theory, ftw=ftw, quantized_hz=ftw * FS / 2**32,
                         quantization_error_hz=ftw * FS / 2**32 - theory,
                         expected_left_peak=amplitude * (0.75 if i % 2 == 0 else 0.25),
                         expected_right_peak=amplitude * (0.25 if i % 2 == 0 else 0.75)))
    return rows


def write_csv(path, rows):
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)


def analyze(samples, table):
    if samples.shape != (N, 2) or not np.isfinite(samples).all():
        raise ValueError(f"Expected {N} continuous stereo samples; got {samples.shape}")
    if not np.equal(samples, np.rint(samples)).all():
        raise ValueError("PCM values must be integer sample codes")
    window = np.hanning(N)
    freq = np.fft.rfftfreq(4 * N, 1 / FS)
    spectra = []
    peaks = []
    channel_stats = []
    failures = []
    for channel, name in enumerate(("left", "right")):
        x = samples[:, channel]
        clipped = int(np.count_nonzero((x >= 8388607) | (x <= -8388608)))
        out_of_range = int(np.count_nonzero((x > 8388607) | (x < -8388608)))
        peak = float(np.max(np.abs(x)))
        channel_stats.append(dict(channel=name, min=int(x.min()), max=int(x.max()),
                                  rms=float(np.sqrt(np.mean(x*x))), clipping_samples=clipped,
                                  out_of_range_samples=out_of_range,
                                  peak_dbfs=20 * math.log10(max(peak, 1) / 8388608),
                                  dc=float(x.mean())))
        if clipped:
            failures.append(f"{name}: {clipped} samples touch/exceed the PCM rails")
        amplitude = 2 * np.abs(np.fft.rfft((x - x.mean()) * window, n=4*N)) / window.sum()
        spectra.append(amplitude)
        for row in table:
            target = row["quantized_hz"]
            indices = np.flatnonzero(np.abs(freq - target) <= 0.75)
            k = int(indices[np.argmax(amplitude[indices])])
            measured = float(freq[k])
            measured_amp = float(amplitude[k])
            expected_amp = row[f"expected_{name}_peak"]
            # Floor excludes Hann's main lobe and stays inside the nearest-note gap.
            distance = np.abs(freq-target)
            floor_band = (distance >= 4*FS/N) & (distance <= max(1.0, target*0.02))
            floor = max(float(np.median(amplitude[floor_band])), 1e-12)
            contrast = 20*math.log10(max(measured_amp, 1e-12)/floor)
            frequency_ok = abs(measured-target) <= 0.20
            amplitude_ok = 0.8 <= measured_amp/expected_amp <= 1.2
            peak_ok = amplitude[k] > amplitude[k-1] and amplitude[k] > amplitude[k+1]
            passed = frequency_ok and amplitude_ok and peak_ok and contrast >= 20
            peaks.append(dict(channel=name, midi_note=row["midi_note"],
                              theoretical_hz=row["theoretical_hz"], quantized_hz=target,
                              measured_hz=measured, error_hz=measured-target,
                              measured_peak=measured_amp, expected_peak=expected_amp,
                              amplitude_ratio=measured_amp/expected_amp,
                              local_contrast_db=contrast, passed=bool(passed)))
            if not passed:
                failures.append(f"{name} note {row['midi_note']}: peak/frequency/amplitude/contrast")
    return peaks, channel_stats, failures, freq, spectra


def plot_svg(path, freq, spectra, table):
    # Log-frequency, peak dBFS; max pooling preserves narrow peaks when drawing.
    width, height = 1500, 680
    left, top, pw, ph = 75, 65, 1390, 535
    low, high = 55, 3000
    def xpos(f):
        return left + math.log(f/low)/math.log(high/low)*pw
    def ypos(db):
        return top + (0-max(-120, min(0, db)))/120*ph
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
             '<rect width="100%" height="100%" fill="white"/>',
             '<g font-family="Arial,sans-serif" font-size="14" fill="#243247">',
             '<text x="75" y="28" font-size="22">64 simultaneous sine voices - simulated Philips I2S PCM</text>',
             '<text x="75" y="49">48 kHz | N=262144 | Hann | true bin spacing 0.183105 Hz | 4x zero padding (not extra resolution)</text>']
    for db in range(-120, 1, 20):
        y = ypos(db)
        parts.append(f'<path d="M{left} {y} H{left+pw}" stroke="#dce3eb"/><text x="12" y="{y+5}">{db} dBFS</text>')
    for f in (65, 100, 200, 440, 880, 1760, 2500):
        x = xpos(f)
        parts.append(f'<path d="M{x} {top} V{top+ph}" stroke="#e5e9ef"/><text x="{x-12}" y="{top+ph+22}">{f}</text>')
    for row in table:
        x = xpos(row["theoretical_hz"])
        parts.append(f'<path d="M{x:.2f} {top} V{top+ph}" stroke="#d8dcdf" stroke-dasharray="2 5"/>')
    edges = np.geomspace(low, high, int(pw)+1)
    for amplitude, color in zip(spectra, ("#0868ac", "#dc6a22")):
        points = []
        for j in range(len(edges)-1):
            a,b = np.searchsorted(freq, edges[j:j+2])
            level = float(np.max(amplitude[a:max(a+1,b)]))
            db = 20*math.log10(max(level/8388608, 1e-9))
            points.append(f'{left+j:.1f},{ypos(db):.1f}')
        parts.append(f'<polyline fill="none" stroke="{color}" stroke-width="1" points="{" ".join(points)}"/>')
    parts += ['<text x="75" y="653" fill="#0868ac">Blue: left</text>',
              '<text x="180" y="653" fill="#dc6a22">Orange: right</text>',
              '<text x="320" y="653">Dashed lines: 64 theoretical targets. DAC measurements remain pending. Frequency axis: Hz (log).</text>',
              '</g></svg>']
    path.write_text("\n".join(parts), encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", type=Path, default=Path("sim/live64_results"))
    parser.add_argument("--rom", type=Path, default=Path("rtl/audio/rom"))
    parser.add_argument("--table-only", action="store_true")
    args = parser.parse_args()
    args.results.mkdir(parents=True, exist_ok=True)
    table = frequency_table(args.rom)
    write_csv(args.results / "frequencies64.csv", table)
    if args.table_only:
        return
    meta = json.loads((args.results / "capture_meta.json").read_text())
    required = dict(sample_rate=FS, samples=N, base_note=BASE, voices=64, velocity=100,
                    timbre=0, gain=2048, bend=0, vibrato=0, fx_enabled=False,
                    note_ons=64, note_offs=64, done_events=64, steady_underrun_delta=0)
    if any(meta.get(key) != value for key, value in required.items()):
        raise ValueError("Capture metadata does not match the 64-tone neutral contract")
    raw = np.loadtxt(args.results / "pcm_live64.csv", delimiter=",", skiprows=1)
    if raw.shape != (N, 3) or not np.array_equal(raw[:, 0], np.arange(N)):
        raise ValueError("PCM sample indices missing, duplicated or out of order")
    peaks, channels, failures, freq, spectra = analyze(raw[:, 1:], table)
    write_csv(args.results / "fft_peaks64.csv", peaks)
    plot_svg(args.results / "spectrum64.svg", freq, spectra, table)
    report = dict(kind="RTL simulation, NOT DAC measurement", passed=not failures,
                  sample_rate=FS, samples=N, seconds=N/FS, window="Hann",
                  true_bin_hz=FS/N, zero_padding_factor=4,
                  padded_bin_hz=FS/(4*N), frequency_tolerance_hz=0.20,
                  amplitude_ratio_limits=[0.8,1.2], minimum_local_contrast_db=20,
                  expected_peaks_per_channel=64,
                  passed_left=sum(p["passed"] for p in peaks if p["channel"]=="left"),
                  passed_right=sum(p["passed"] for p in peaks if p["channel"]=="right"),
                  max_frequency_error_hz=max(abs(p["error_hz"]) for p in peaks),
                  amplitude_ratio_min=min(p["amplitude_ratio"] for p in peaks),
                  amplitude_ratio_max=max(p["amplitude_ratio"] for p in peaks),
                  minimum_measured_contrast_db=min(p["local_contrast_db"] for p in peaks),
                  channels=channels, failures=failures)
    (args.results / "fft_summary.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))
    if failures:
        raise SystemExit("LIVE64 FFT FAILED")
    print("LIVE64 FFT PASSED: left=64/64 right=64/64 clipping=0")


if __name__ == "__main__":
    main()
