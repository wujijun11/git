"""Check physical GAO CSV sampled by sys_clk; timestamps are export settings.
Use row indices for cycles, never infer measured oscillator frequency from CSV.
"""
import csv
import argparse
import json
from pathlib import Path

def check(path, max_underruns=0):
    lines = Path(path).read_text(encoding='utf-8-sig').splitlines()
    header = next(i for i, line in enumerate(lines) if line.startswith('time unit:'))
    rows = list(csv.DictReader(lines[header:], skipinitialspace=True))
    valid = [(i, r) for i, r in enumerate(rows) if r['rst_n'].strip() in ('0', '1')]
    assert len(valid) >= 4000, 'Incomplete capture'
    for _, r in valid:
        assert int(r['fault'], 16) == 0 and int(r['error'], 16) == 0
        assert int(r['underruns[31:0]'], 16) <= max_underruns, 'Unexpected underrun'
    rising = [(i, r) for (j, p), (i, r) in zip(valid, valid[1:])
              if p['bclk'] == '0' and r['bclk'] == '1']
    assert all(b[0]-a[0] == 16 for a, b in zip(rising, rising[1:])), 'BCLK period'
    last_ws = None
    bits = []
    words = []
    for _, r in rising:
        ws, bit = int(r['lrclk']), int(r['serial_data'])
        if ws != last_ws:
            if last_ws is not None and len(bits) == 32:
                assert bits[0] == 0 and not any(bits[25:]), 'I2S delay/padding'
                word = int(''.join(map(str, bits[1:25])), 2)
                words.append({'channel': last_ws, 'pcm': word-(1<<24) if word & (1<<23) else word})
            elif last_ws is not None and words:
                raise AssertionError('I2S slot length')
            last_ws, bits = ws, []
        bits.append(bit)
    assert len(words) >= 6 and any(w['pcm'] for w in words), 'Missing PCM'
    return dict(file=str(path), valid_samples=len(valid), bclk_period_cycles=16,
                sample_rate_if_clock_50MHz=50000000/1024,
                completed_runs=sorted({int(r['completed_runs[15:0]'],16) for _,r in valid}),
                active_count=sorted({int(r['active_count[6:0]'],16) for _,r in valid}),
                phases=sorted({int(r['phase[2:0]'],16) for _,r in valid}),
                underruns=sorted({int(r['underruns[31:0]'],16) for _,r in valid}),
                decoded_words=words, result='PASS')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--max-underruns', type=int, default=0,
                        help='Use 1 only when reviewing captures from before the priming fix')
    parser.add_argument('captures', nargs='+')
    args = parser.parse_args()
    print(json.dumps([check(p, args.max_underruns) for p in args.captures], indent=2))
