"""Audit actual 25-key ModelSim PCM and export unnormalized 24-bit WAVs.

This checks the synthesis engine's MIDI inputs, not physical electrode wiring.
No listening gain or per-key normalization is applied to the generated audio.
"""
import argparse
import csv
import json
import math
import wave
from pathlib import Path

import numpy as np

FS = 48000
FULL_SCALE = 8388608


def write_wav24(path, pcm):
    samples = np.asarray(pcm, dtype=np.int32)
    assert samples.ndim == 2 and samples.shape[1] == 2
    assert np.max(np.abs(samples.astype(np.int64))) < FULL_SCALE
    raw = samples.astype('<i4').reshape(-1).view(np.uint8).reshape(-1, 4)[:, :3].tobytes()
    with wave.open(str(path), 'wb') as output:
        output.setnchannels(2)
        output.setsampwidth(3)
        output.setframerate(FS)
        output.writeframes(raw)


def fundamental(pcm, note, hold_frames):
    # Exclude the piano's first transient; at least 12,288 held frames gives
    # a 200 ms measurement window. Shorter smoke runs still keep 70+ ms.
    end = min(hold_frames - 512, 15360)
    start = min(4800, end // 3)
    signal = pcm[start:end].mean(axis=1).astype(float)
    assert len(signal) >= 2048, 'Not enough held piano PCM for frequency audit'
    target = 440.0 * 2 ** ((note - 69) / 12)
    fft_size = 262144
    spectrum = np.abs(np.fft.rfft(signal * np.hanning(len(signal)), n=fft_size))
    frequencies = np.fft.rfftfreq(fft_size, 1 / FS)
    candidates = np.flatnonzero(np.abs(frequencies - target) < target * .02)
    index = int(candidates[np.argmax(spectrum[candidates])])
    def interpolated_hz(peak_index):
        log_peak = np.log(np.maximum(spectrum[peak_index - 1:peak_index + 2], 1e-30))
        offset = .5 * (log_peak[0] - log_peak[2]) / (log_peak[0] - 2 * log_peak[1] + log_peak[2])
        return (peak_index + float(np.clip(offset, -.5, .5))) * FS / fft_size

    measured = interpolated_hz(index)
    cents = 1200 * math.log2(measured / target)
    assert abs(cents) < 35, (note, measured, cents)
    assert spectrum[index] > spectrum[index - 1] and spectrum[index] > spectrum[index + 1], (note, 'no local peak')
    # This search is independent of the expected MIDI pitch. Some piano
    # profiles have a stronger second harmonic, so its frequency need not
    # follow the MIDI sequence monotonically. Do not mistake it for F0.
    broad_band = np.flatnonzero((frequencies >= 100) & (frequencies <= 5000))
    strongest_index = int(broad_band[np.argmax(spectrum[broad_band])])
    relative_peak = float(spectrum[index] / spectrum[strongest_index])
    assert relative_peak >= .1, (note, 'expected pitch only a weak spur', relative_peak)
    broad_vector = spectrum[broad_band]
    broad_vector = broad_vector / np.linalg.norm(broad_vector)
    return target, measured, cents, [start, end], interpolated_hz(strongest_index), relative_peak, broad_vector


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--hold-frames', type=int, default=16384)
    parser.add_argument('--release-frames', type=int, default=6000)
    args = parser.parse_args()
    output = args.input
    audio_dir = output / 'listen_raw'
    audio_dir.mkdir(exist_ok=True)
    with (output / 'pcm' / 'manifest.csv').open(newline='', encoding='utf-8-sig') as handle:
        manifest = list(csv.DictReader(handle))
    assert len(manifest) == 25, 'Incomplete 25-note event manifest'
    notes = []
    clips = {}
    independent_spectra = []
    for index, note in enumerate(range(60, 85)):
        path = output / 'pcm' / f'note_{note}.csv'
        data = np.loadtxt(path, delimiter=',', skiprows=1, dtype=np.int64)
        assert data.shape == (args.hold_frames + args.release_frames, 3), (note, data.shape)
        assert np.array_equal(data[:, 0], np.arange(len(data))), (note, 'noncontiguous frames')
        pcm = data[:, 1:]
        assert np.any(pcm), (note, 'silent')
        clipped = int(np.count_nonzero((pcm >= 8388607) | (pcm <= -8388608)))
        assert clipped == 0, (note, 'PCM clipping')
        assert int(np.max(np.abs(pcm[-1200:]))) <= 16, (note, 'release did not reach silence')
        row = manifest[index]
        assert int(row['midi']) == note and int(row['frames']) == len(data)
        assert int(row['events']) == 2 * (index + 1) and int(row['done_count']) == index + 1
        assert int(row['fx']) == 0 and int(row['velocity']) == 100
        target, measured, cents, window, strongest_hz, relative_peak, spectrum = fundamental(pcm, note, args.hold_frames)
        independent_spectra.append(spectrum)
        peak = int(np.max(np.abs(pcm)))
        rms = float(np.sqrt(np.mean(pcm[:args.hold_frames].astype(float) ** 2)))
        notes.append(dict(midi=note, target_hz=target, fundamental_hz=measured,
                          cents_from_equal_temperament=cents, fft_window_samples=window,
                          broad_spectrum_dominant_hz=strongest_hz,
                          fundamental_to_broad_dominant_amplitude=relative_peak,
                          peak_pcm=peak, peak_dbfs=20 * math.log10(peak / FULL_SCALE),
                          rms_pcm=rms, hold_rms_dbfs=20 * math.log10(rms / FULL_SCALE),
                          frames=len(data), clipping_samples=clipped, release_silent=True))
        clips[note] = pcm
        write_wav24(audio_dir / f'note_{note}_raw.wav', pcm)
    values = [row['fundamental_hz'] for row in notes]
    assert all(right > left for left, right in zip(values, values[1:])), '25 notes are not strictly increasing'
    assert len(set(round(value, 3) for value in values)) == 25, 'Duplicate note frequency'
    # Detect an unchanged waveform even if expected-pitch local searches
    # happen to locate its harmonics or spurs. Gain changes cannot make two
    # normalized magnitude spectra different in this test.
    vectors = np.stack(independent_spectra)
    correlations = vectors @ vectors.T
    np.fill_diagonal(correlations, -np.inf)
    closest = np.unravel_index(int(np.argmax(correlations)), correlations.shape)
    max_correlation = float(correlations[closest])
    assert max_correlation < .999, ('near-identical whole spectra', closest, max_correlation)
    gap = np.zeros((4800, 2), dtype=np.int64)
    write_wav24(audio_dir / 'all_25_keys_raw.wav', np.concatenate([part for note in range(60, 85) for part in (clips[note], gap)]))
    write_wav24(audio_dir / 'C4_C6_selection_raw.wav', np.concatenate([part for note in (60, 64, 67, 69, 72, 76, 79, 84) for part in (clips[note], gap)]))
    metadata = json.loads((output / 'source_hashes.json').read_text(encoding='utf-8-sig'))
    dominant_values = [row['broad_spectrum_dominant_hz'] for row in notes]
    report = dict(kind='ModelSim HDL PCM; not DAC or physical electrode measurements',
                  passed=True, timbre=2, auto_headroom=1, velocity=100, sample_rate=FS,
                  voice_count_in_sequential_test=4, note_count=25, events=50, releases=25,
                  monotonic=True, unique_fundamentals=25, clipping_samples=0,
                  broad_peak_search_hz=[100, 5000],
                  unique_broad_dominant_peaks=len(set(round(value, 3) for value in dominant_values)),
                  broad_dominant_peaks_monotonic=all(right > left for left, right in zip(dominant_values, dominant_values[1:])),
                  broad_peak_interpretation='The first piano region has a stronger second harmonic; broad dominant peak is not always the fundamental.',
                  min_fundamental_to_broad_dominant_amplitude=min(row['fundamental_to_broad_dominant_amplitude'] for row in notes),
                  independent_full_spectrum_comparisons=300,
                  max_pairwise_normalized_spectral_cosine=max_correlation,
                  closest_spectral_pair_midi=[60 + int(closest[0]), 60 + int(closest[1])],
                  minimum_pairwise_normalized_spectral_l2=math.sqrt(max(0, 2 - 2 * max_correlation)),
                  max_abs_cents=max(abs(row['cents_from_equal_temperament']) for row in notes),
                  min_peak_dbfs=min(row['peak_dbfs'] for row in notes),
                  max_peak_dbfs=max(row['peak_dbfs'] for row in notes),
                  listening_gain=1.0, wav_format='24-bit signed stereo PCM, 48 kHz; no normalization',
                  fixed_expression=dict(gain_q1_11=2048, bend_cents=0, vibrato_depth_cents=0),
                  source_hash_manifest='source_hashes.json',
                  snapshot_scope_note=metadata.get('snapshot_scope_note', ''),
                  c6_to_c4_ratio=values[-1] / values[0], notes=notes)
    (output / 'keyboard_summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    with (output / 'keyboard_summary.csv').open('w', newline='', encoding='utf-8-sig') as handle:
        writer = csv.DictWriter(handle, fieldnames=list(notes[0]))
        writer.writeheader()
        writer.writerows(notes)
    print(json.dumps({key: value for key, value in report.items() if key != 'notes'}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
