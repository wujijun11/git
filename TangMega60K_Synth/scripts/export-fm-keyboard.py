"""Convert 25 actual V2/FM ModelSim PCM clips to 24-bit WAV and check pitch.

Individual raw WAVs have bit-identical samples to the CSV. Listening WAVs
all share ONE global gain, so their relative loudness is preserved. This is
not a recording from the I2S DAC or a replacement software sound generator.
"""
import argparse
import csv
import json
import math
import wave
from pathlib import Path

import numpy as np

FS = 48000
FIRST_NOTE = 60
LAST_NOTE = 84
PCM_LIMIT = 1 << 23
NOTE_NAMES = ("C", "Csharp", "D", "Dsharp", "E", "F", "Fsharp", "G",
              "Gsharp", "A", "Asharp", "B")


def note_name(midi):
    return NOTE_NAMES[midi % 12] + str(midi // 12 - 1)


def read_pcm(path):
    data = np.loadtxt(path, delimiter=",", skiprows=1, dtype=np.int64)
    if data.ndim != 2 or data.shape[1] != 3:
        raise AssertionError(f"bad PCM CSV shape: {path}")
    if not np.array_equal(data[:, 0], np.arange(len(data))):
        raise AssertionError(f"missing/duplicate PCM sample index: {path}")
    pcm = data[:, 1:]
    if np.max(np.abs(pcm)) >= PCM_LIMIT - 1:
        raise AssertionError(f"clipped 24-bit PCM: {path}")
    if np.count_nonzero(pcm) == 0:
        raise AssertionError(f"silent note: {path}")
    return pcm


def write_wav24(path, samples):
    """Write signed interleaved two-channel little-endian PCM24, no resampling."""
    path.parent.mkdir(parents=True, exist_ok=True)
    pcm = np.asarray(samples, dtype=np.int64)
    if pcm.ndim != 2 or pcm.shape[1] != 2 or np.max(np.abs(pcm)) >= PCM_LIMIT:
        raise AssertionError(f"invalid PCM24 output: {path}")
    words = pcm.astype("<i4", copy=False).reshape(-1).view(np.uint8).reshape(-1, 4)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(3)
        wav.setframerate(FS)
        wav.writeframes(words[:, :3].tobytes())


def pitch_measure(pcm, midi):
    mono = pcm.mean(axis=1).astype(np.float64)
    peak = float(np.max(np.abs(mono)))
    onset_candidates = np.flatnonzero(np.abs(mono) > max(4.0, peak * 0.004))
    if len(onset_candidates) == 0:
        raise AssertionError(f"no sound onset: MIDI {midi}")
    onset = int(onset_candidates[0])
    # Remain wholly inside the 160-ms held note, after transient attack.
    start = onset + int(0.035 * FS)
    end = onset + int(0.140 * FS)
    if end >= len(mono):
        raise AssertionError(f"note too short for pitch window: MIDI {midi}")
    signal = mono[start:end] - np.mean(mono[start:end])
    nfft = 1 << 18
    spectrum = np.abs(np.fft.rfft(signal * np.hanning(len(signal)), n=nfft))
    hz = np.fft.rfftfreq(nfft, 1.0 / FS)
    target = 440.0 * 2.0 ** ((midi - 69) / 12.0)
    band = np.flatnonzero((hz > target * 0.97) & (hz < target * 1.03))
    bin_number = int(band[np.argmax(spectrum[band])])
    # Quadratic interpolation around the local FFT peak reduces bin error.
    a, b, c = spectrum[bin_number - 1:bin_number + 2]
    denominator = a - 2.0 * b + c
    offset = 0.0 if denominator == 0 else float(0.5 * (a - c) / denominator)
    estimated = (bin_number + offset) * FS / nfft
    cents = 1200.0 * math.log2(estimated / target)
    strongest = float(np.max(spectrum[(hz > 200) & (hz < 5000)]))
    fundamental_db = 20.0 * math.log10(max(float(b), 1e-9) / max(strongest, 1e-9))
    if abs(cents) > 18.0:
        raise AssertionError(f"MIDI {midi} pitch {estimated:.2f}Hz vs {target:.2f}Hz ({cents:+.1f} cents)")
    if fundamental_db < -15.0:
        raise AssertionError(f"MIDI {midi} fundamental too weak: {fundamental_db:.1f} dB below strongest peak")
    return {
        "target_hz": round(target, 4), "measured_hz": round(estimated, 4),
        "error_cents": round(cents, 4), "fundamental_relative_db": round(fundamental_db, 2),
        "onset_sample": onset, "analysis_window_samples": [start, end],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="ModelSim output directory")
    parser.add_argument("--output", type=Path, help="WAV/report directory; defaults to --input")
    parser.add_argument("--comparison-gain", type=float,
                        help="Optional second set of WAVs with a specified common gain; does not alter RTL")
    args = parser.parse_args()
    source = args.input
    destination = args.output or source
    destination.mkdir(parents=True, exist_ok=True)
    with (source / "manifest.csv").open(newline="", encoding="utf-8") as stream:
        manifest = list(csv.DictReader(stream))
    expected = list(range(FIRST_NOTE, LAST_NOTE + 1))
    if [int(row["midi"]) for row in manifest] != expected:
        raise AssertionError("ModelSim manifest is not the complete ordered MIDI 60-84 set")
    if any(int(row["fx"]) != 0 or int(row["velocity"]) != 100 for row in manifest):
        raise AssertionError("audition must use dry FM, velocity 100")
    if not (source / "modelsim.log").is_file() or "FM KEYBOARD PASSED:" not in (source / "modelsim.log").read_text(errors="replace"):
        raise AssertionError("no successful HDL simulation log")

    clips = {}
    report = {
        "source": "ModelSim V2 event-to-FM HDL PCM; not DAC output",
        "scope": "25 sequential notes C4-C6; VOICE_COUNT=4 for fast audition, NOT 64-note concurrency verification",
        "sample_rate_hz": FS, "wav_bits": 24, "timbre": 3, "velocity": 100,
        "delay_enabled": False, "gain": 2048, "bend_cents": 0, "vibrato_cents": 0,
        "clipped_samples": 0, "notes": [],
    }
    for midi, row in zip(expected, manifest):
        pcm = read_pcm(source / f"note_{midi:02d}.csv")
        if len(pcm) != int(row["frames"]):
            raise AssertionError(f"frame count differs from HDL manifest: MIDI {midi}")
        if int(row["done_count"]) != midi - FIRST_NOTE + 1:
            raise AssertionError(f"voice was not fully released/recycled: MIDI {midi}")
        clips[midi] = pcm
        info = pitch_measure(pcm, midi)
        info.update({"midi": midi, "name": note_name(midi), "frames": len(pcm),
                     "pcm_peak": int(np.max(np.abs(pcm))),
                     "rms_pcm": round(float(np.sqrt(np.mean(pcm.astype(np.float64) ** 2))), 2)})
        report["notes"].append(info)
        write_wav24(destination / "raw" / f"note_{midi:02d}_{note_name(midi)}.wav", pcm)

    all_peak = max(int(np.max(np.abs(pcm))) for pcm in clips.values())
    gain = 0.65 * (PCM_LIMIT - 1) / all_peak
    report["listening_gain_applied_to_every_note"] = round(float(gain), 5)
    report["max_abs_pitch_error_cents"] = max(abs(row["error_cents"]) for row in report["notes"])
    rendered = []
    for midi in expected:
        audible = np.rint(clips[midi] * gain).astype(np.int64)
        write_wav24(destination / "listen" / f"note_{midi:02d}_{note_name(midi)}.wav", audible)
        rendered.append(audible)
    sequence = np.concatenate(rendered, axis=0)
    write_wav24(destination / "listen" / "00_C4_to_C6_25_notes.wav", sequence)
    report["sequence_duration_seconds"] = round(len(sequence) / FS, 3)
    report["sequence_order"] = [note_name(midi) for midi in expected]
    if args.comparison_gain is not None:
        common_gain = args.comparison_gain
        if not math.isfinite(common_gain) or common_gain <= 0 or all_peak * common_gain >= PCM_LIMIT:
            raise AssertionError("comparison gain must be positive, finite, and unclipped")
        compared = []
        for midi in expected:
            audible = np.rint(clips[midi] * common_gain).astype(np.int64)
            write_wav24(destination / "listen_matched" / f"note_{midi:02d}_{note_name(midi)}.wav", audible)
            compared.append(audible)
        write_wav24(destination / "listen_matched" / "00_C4_to_C6_25_notes.wav",
                    np.concatenate(compared, axis=0))
        report["comparison_gain_applied_to_every_note"] = float(common_gain)
    (destination / "analysis.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"FM KEYBOARD ANALYSIS PASSED: 25 dry FM notes, max pitch error {report['max_abs_pitch_error_cents']:.4f} cents, no clipping")
    print(f"Audition: {destination / 'listen' / '00_C4_to_C6_25_notes.wav'}")
    for row in report["notes"]:
        print(f"MIDI {row['midi']:2d} {row['name']:8s} target {row['target_hz']:8.3f} Hz, measured {row['measured_hz']:8.3f} Hz, {row['error_cents']:+7.4f} cents")


if __name__ == "__main__":
    main()
