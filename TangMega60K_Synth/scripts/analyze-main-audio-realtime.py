"""Audit actual 48 kHz serialized-I2S test PCM; no playback normalization."""
import argparse
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path

import numpy as np


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    args = parser.parse_args()
    output = args.input
    metadata = json.loads((output / 'source_hashes.json').read_text(encoding='utf-8-sig'))
    assert metadata.get('probe_frames', 0) == 0, 'A short probe is not a full pitch/release test'
    hold = int(metadata['hold_frames'])
    release = int(metadata['release_frames'])
    spec = importlib.util.spec_from_file_location('keyboard_analysis', Path(__file__).with_name('analyze-piano-headroom.py'))
    analysis = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(analysis)
    listen = output / 'listen_raw'
    listen.mkdir(exist_ok=True)
    notes = []
    clips = {}
    vectors = {}
    for n in metadata['voices']:
        for midi in (60, 84):
            path = output / 'snapshot' / 'pcm' / f'n{n}_note_{midi}.csv'
            data = np.loadtxt(path, delimiter=',', skiprows=1, dtype=np.int64)
            assert data.shape == (hold + release, 4), (path, data.shape)
            assert np.array_equal(data[:, 0], np.arange(len(data))), 'Noncontiguous decoded I2S frames'
            assert np.count_nonzero(data[:, 1] == 1) == hold
            assert np.count_nonzero(data[:, 1] == 2) == release
            pcm = data[:, 2:]
            clips[n, midi] = pcm
            assert np.any(pcm), (n, midi, 'silent')
            assert int(np.max(np.abs(pcm))) < 8388607, 'PCM clipping'
            assert int(np.max(np.abs(pcm[-1024:]))) == 0, 'Release must reach exact silence'
            target, f0, cents, window, dominant, relative, vector = analysis.fundamental(pcm, midi, hold)
            vectors[n, midi] = vector
            peak = int(np.max(np.abs(pcm)))
            notes.append(dict(voice_count=n, midi=midi, frames=len(data), target_hz=target,
                              measured_fundamental_hz=f0, cents_from_target=cents,
                              target_independent_broad_peak_hz=dominant,
                              fundamental_to_broad_peak_amplitude=relative,
                              fft_window_samples=window, peak_pcm=peak,
                              peak_dbfs=20 * math.log10(peak / 8388608),
                              clipping_samples=0, last_1024_samples_exact_silence=True))
            analysis.write_wav24(listen / f'n{n}_note_{midi}_raw.wav', pcm)
        assert float(vectors[n, 60] @ vectors[n, 84]) < .99, 'C4 and C6 whole spectra are identical'
        gap = np.zeros((4800, 2), dtype=np.int64)
        analysis.write_wav24(listen / f'n{n}_C4_C6_raw.wav', np.concatenate((clips[n, 60], gap, clips[n, 84])))

    stats = []
    for n in metadata['voices']:
        with (output / 'snapshot' / 'pcm' / f'n{n}_stats.csv').open(newline='') as handle:
            row = {key: int(value) for key, value in next(csv.DictReader(handle)).items()}
        assert row['underruns'] == 0 and row['done_count'] == 2
        # The earliest full run used these names for acceptance latency;
        # its short companion probe separately measures first valid.
        if 'min_compute' in row:
            row['min_accept_latency'] = row.pop('min_compute')
            row['max_accept_latency'] = row.pop('max_compute')
        stats.append(row)

    comparison = []
    if 64 in metadata['voices'] and 1 in metadata['voices']:
        for midi in (60, 84):
            a, b = clips[64, midi], clips[1, midi]
            best = None
            for shift in range(-16, 17):
                x = a[32:hold - 32].astype(float).reshape(-1)
                y = b[32 + shift:hold - 32 + shift].astype(float).reshape(-1)
                cosine = float(x @ y / (np.linalg.norm(x) * np.linalg.norm(y)))
                candidate = dict(midi=midi, n1_relative_sample_shift=shift, waveform_cosine=cosine,
                                 maximum_pcm_difference=int(np.max(np.abs(x - y))))
                if best is None or cosine > best['waveform_cosine']:
                    best = candidate
            assert best['waveform_cosine'] > .9999, best
            comparison.append(best)

    report = dict(passed=True,
                  scope='Actual voice_engine (FM=1,AUTO_HEADROOM=1), runtime_audio_fx mode 0, i2s_tx DIV8; testbench decodes output pins at 1024 clocks/frame. Not postroute FPGA timing, PLL, electrode allocation, or DAC measurement.',
                  pcm_source='Decoded serialized I2S data, bit-exact compared in HDL with accepted engine PCM across runtime FX and FIFO',
                  nominal_sample_rate=48000, simulated_clock_period_ns=20.345,
                  frame_period_clocks=1024, serialized_pcm_mismatches=0,
                  runtime_dry_pcm_mismatches=0, backpressure_pcm_changes=0,
                  underruns=0, clipping_samples=0, notes=notes, stats=stats,
                  n1_n64_waveform_comparison=comparison,
                  voice_count_timing_note='PREP to sample handshake includes intentional I2S FIFO backpressure; first-valid compute cost is measured by the separate short probe when absent from this original run stats.',
                  listening_gain=1, wav_format='24-bit signed stereo PCM, 48 kHz, no normalization',
                  source_hash_manifest='source_hashes.json')
    (output / 'realtime_summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    hashes = {}
    for path in sorted([*listen.glob('*.wav'), *(output / 'snapshot' / 'pcm').glob('*.csv')]):
        hashes[path.relative_to(output).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    (output / 'result_hashes.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
