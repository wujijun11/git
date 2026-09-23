"""Four note-region, eight-partial piano. OFFLINE parameter fitting only.

Each lane still uses 512x260 parameter bits: four partials x four regions x
32 segments. No recorded PCM, residual or convolution IR enters the ROM.
Source: Alexander Holm, Salamander Grand Piano v3, CC BY 3.0.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request
import numpy as np
from render_model import read_wav, write_wav, render
from convert_polar import pack

FS = 48000
ROOTS = [(60, 'C4v12'), (69, 'A4v12'), (72, 'C5v12'), (84, 'C6v12')]
COMMIT = '3382bf9496bba2486f5ab0de55a264d1dfc38404'
URL = f'https://raw.githubusercontent.com/sfzinstruments/SalamanderGrandPiano/{COMMIT}/Samples/'
SENTINEL = dict(end=1048575, a=[0, 0], da=[0, 0], theta=[0, 0], dtheta=[0, 0])


def frequency(note):
    return 440 * 2 ** ((note - 69) / 12)


def bank_for_note(note):
    # Boundaries are geometric midpoints of the reference notes, rounded up.
    return 0 if note < 65 else 1 if note < 71 else 2 if note < 78 else 3


def fetch(root):
    import soundfile as sf  # Only needed to decode the reference FLAC files.
    root.mkdir(parents=True, exist_ok=True)
    for _, name in ROOTS:
        dest = root / (name + '.wav')
        if dest.exists():
            continue
        flac = root / (name + '.flac')
        if not flac.exists():
            with urllib.request.urlopen(URL + name + '.flac', timeout=60) as response:
                flac.write_bytes(response.read())
        x, rate = sf.read(flac, dtype='int32', always_2d=True)
        assert rate == FS and x.shape[1] == 2
        sf.write(dest, x, rate, subtype='PCM_24')
        back, _ = sf.read(dest, dtype='int32', always_2d=True)
        assert np.array_equal(x, back)


def peak(hz, power, center, radius):
    ids = np.flatnonzero(abs(hz - center) < radius)
    k = ids[np.argmax(power[ids])]
    y = np.log(np.maximum(power[k-1:k+2], 1e-30))
    d = .5 * (y[0] - y[2]) / (y[0] - 2*y[1] + y[2])
    return float(hz[k] + np.clip(d, -.5, .5) * (hz[1] - hz[0]))


def knots_for_budget(t, amp, phase, budget=32):
    # Fit complex amplitude, so a phase error at an inaudibly small amplitude
    # cannot consume all knots. At most 31 segments plus one zero sentinel.
    chosen = [0, len(t)-1]
    target = amp * np.exp(1j * phase)
    while len(chosen) < budget:
        worst, index = -1., None
        for lo, hi in zip(chosen, chosen[1:]):
            if hi <= lo + 1:
                continue
            u = ((t[lo+1:hi] - t[lo]) / (t[hi] - t[lo]))[:, None]
            aa = amp[lo] + u * (amp[hi] - amp[lo])
            pp = phase[lo] + u * (phase[hi] - phase[lo])
            errors = np.max(abs(aa * np.exp(1j*pp) - target[lo+1:hi]), axis=1)
            # Extra attention to the first 150 ms; these knots describe a
            # short attack, not a stored audio transient.
            errors *= np.where(t[lo+1:hi] < .15*FS, 1.5, 1.)
            j = int(np.argmax(errors))
            if errors[j] > worst:
                worst, index = float(errors[j]), lo + 1 + j
        if index is None:
            break
        chosen.append(index)
        chosen.sort()
    return np.asarray(chosen)


def segments_from_track(t, envelope, scale):
    amp = abs(envelope) * scale
    phase = np.unwrap(np.angle(envelope), axis=0)
    phase[0] = phase[1]
    ids = knots_for_budget(t, amp, phase)
    a = np.rint(amp[ids] * 2**27).astype(np.int64) << 8
    theta = np.rint(phase[ids] * 2**32 / (2*np.pi)).astype(np.int64)
    segments = []
    for j in range(len(ids)-1):
        lo, hi = int(t[ids[j]]), int(t[ids[j+1]])
        segments.append(dict(start=lo, end=hi, a=a[j].tolist(),
                             da=np.rint((a[j+1]-a[j])/(hi-lo)).astype(np.int64).tolist(),
                             theta=(theta[j] & 0xffffffff).tolist(),
                             dtheta=np.rint((theta[j+1]-theta[j])/(hi-lo)).astype(np.int64).tolist()))
    segments.append(dict(start=int(t[-1]), **SENTINEL))
    return segments


def analyze_reference(path, note):
    x, fs = read_wav(path)
    assert fs == FS
    # Remove the reference recording's leading silence. A 1 ms generated
    # attack starts at sample zero; the engine applies its existing 2 ms gate.
    onset = int(np.flatnonzero(np.max(abs(x), axis=1) > np.max(abs(x))*.005)[0])
    trim = max(0, onset-48)
    x = x[trim:min(len(x), trim+12*FS+1)].copy()
    x[-min(4800, len(x)):]*=np.linspace(1, 0, min(4800, len(x)))[:, None]
    n = np.arange(len(x))
    # Fine FFT is offline only. Search radius stays below half the fundamental.
    part = x[int(.03*FS):int(1.03*FS)]
    hz = np.fft.rfftfreq(524288, 1/FS)
    power = np.sum(abs(np.fft.rfft(part*np.hanning(len(part))[:, None], n=524288, axis=0))**2, axis=1)
    f0 = frequency(note)
    orders = np.arange(1, 7)
    centers = np.array([peak(hz, power, k*f0, f0*.28) for k in orders])
    coeff = np.linalg.lstsq(np.stack([np.ones(6), orders**2], axis=1), (centers/orders)**2, rcond=None)[0]
    base, stiff = np.sqrt(max(coeff[0], 1)), max(0., float(coeff[1]/coeff[0]))
    pad = FS//4
    size = 1 << int(np.ceil(np.log2(len(x)+2*pad)))
    padded = np.zeros((size, 2)); padded[pad:pad+len(x)] = x
    X = np.fft.fft(padded, axis=0)
    allhz = np.fft.fftfreq(size, 1/FS)
    t = np.unique(np.r_[np.arange(0, min(7200, len(x)), 48),
                         np.arange(7200, len(x), 240), len(x)-1]).astype(int)
    tracks = []
    for order in range(1, 17):
        predicted = base * order * np.sqrt(1+stiff*order**2)
        if predicted > 19000:
            break
        f = peak(hz, power, predicted, f0*.28)
        mask = np.exp(-.5*np.minimum(abs((allhz-f)/65), 100)**4)
        mask[allhz <= 0] = 0
        isolated = 2*np.fft.ifft(X*mask[:, None], axis=0)[pad:pad+len(x)]
        env = isolated*np.exp(-2j*np.pi*f*n/FS)[:, None]
        env *= np.minimum(n/48., 1)[:, None]
        env[-4800:] *= np.linspace(1, 0, 4800)[:, None]
        env[-1] = 0
        # Balance sustained energy and early brightness; keep core pitch modes.
        early = float(np.mean(abs(env[:4800])**2))
        body = float(np.mean(abs(env[4800:24000])**2))
        score = (early*.7+body*.3)*min(order, 10)**1.2
        tracks.append(dict(order=order, frequency_hz=f, envelope=env[t], score=score))
    chosen = tracks[:4] + sorted(tracks[4:], key=lambda v: v['score'], reverse=True)[:4]
    chosen.sort(key=lambda v: v['order'])
    return x, t, chosen, trim


def render_profile(profile, note=None, frames=None):
    count = profile['frames'] if frames is None else frames
    midi = profile['root_midi'] if note is None else note
    n = np.arange(count, dtype=np.int64)
    base = round(frequency(midi)*2**32/FS)
    sine = np.rint(np.sin(np.arange(1024)*2*np.pi/1024)*32767).astype(np.int64)
    result = np.zeros((count, 2), np.int64)
    for part in profile['partials']:
        ftw = (base*part['ratio_q22']+2**21) >> 22
        if ftw >= 0x73333333:
            continue
        phase = (n*ftw)&0xffffffff
        for seg in part['segments']:
            lo, hi = seg['start'], min(seg['end'], count)
            if hi <= lo:
                continue
            age = np.arange(hi-lo, dtype=np.int64)
            for ch in range(2):
                amp = np.clip(seg['a'][ch]+age*seg['da'][ch], 0, 2**35-1) >> 8
                angle = phase[lo:hi]+seg['theta'][ch]+age*seg['dtheta'][ch]+2**30
                result[lo:hi, ch] += (amp*sine[(angle&0xffffffff)>>22]+2**26) >> 27
    return result


def export_rom(model, directory):
    directory.mkdir(parents=True, exist_ok=True)
    assert len(model['profiles']) == 4
    for lane in (0, 1):
        words = []
        for partial in range(lane, 8, 2):
            for profile in model['profiles']:
                assert len(profile['partials']) == 8
                segs = profile['partials'][partial]['segments']
                assert len(segs) <= 32 and segs[0]['start'] == 0
                assert all(x['end'] == y['start'] for x, y in zip(segs, segs[1:]))
                assert segs[-1]['end'] == 1048575 and segs[-1]['a'] == [0, 0]
                words.extend(pack(s) for s in segs)
                words.extend([pack(SENTINEL)]*(32-len(segs)))
        assert len(words) == 512
        (directory/f'polar_lane{lane}.hex').write_text('\n'.join(words)+'\n', encoding='ascii')
    ratios = [p['ratio_q22'] for bank in model['profiles'] for p in bank['partials']]
    assert len(ratios) == 32 and all(0 < r < 2**27 for r in ratios)
    (directory/'polar_ratios.hex').write_text('\n'.join(f'{r:07x}' for r in ratios)+'\n', encoding='ascii')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--references', type=Path)
    parser.add_argument('--download', action='store_true')
    parser.add_argument('--legacy-model', type=Path, default=Path('assets/audio/piano_a4_iq.json'))
    parser.add_argument('--model', type=Path, required=True)
    parser.add_argument('--rom', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.references:
        if args.download:
            fetch(args.references)
        analyses = [analyze_reference(args.references/(name+'.wav'), note) for note, name in ROOTS]
        old = render(json.loads(args.legacy_model.read_text()))
        target_rms = np.sqrt(np.mean(old[:24000]**2))
        model = dict(format='piano_eight_regions_v2', sample_rate=FS, segments_per_partial=32,
                     source_work='Salamander Grand Piano v3 / Alexander Holm / CC BY 3.0',
                     source_revision=COMMIT, license_url='https://creativecommons.org/licenses/by/3.0/',
                     method='Eight generated sinusoids; four reference regions; amplitude/phase coefficient ROM',
                     bank_start_midi=[0,65,71,78], profiles=[])
        for (note, name), (x, t, tracks, trim) in zip(ROOTS, analyses):
            # Match the old A4 level per root region; preserve the engine's
            # velocity curve, envelope gate, panning and master scaling.
            energy = sum(float(np.mean(abs(tr['envelope'][t<24000])**2)) for tr in tracks)/2
            scale = float(target_rms/np.sqrt(energy))
            profile = dict(root_midi=note, source=name+'.wav', frames=len(x),
                           source_sha256=hashlib.sha256((args.references/(name+'.wav')).read_bytes()).hexdigest(),
                           trim_samples=trim, parameter_gain=scale, partials=[])
            for tr in tracks:
                profile['partials'].append(dict(order=tr['order'], frequency_hz=tr['frequency_hz'],
                    ratio_q22=round(tr['frequency_hz']/frequency(note)*2**22),
                    segments=segments_from_track(t, tr['envelope'], scale)))
            bound = np.sum([np.max(np.array([s['a'] for s in p['segments']]),axis=0)/2**35
                            for p in profile['partials']],axis=0)
            assert np.max(bound) < .95, bound
            profile['amplitude_bound'] = bound.tolist()
            model['profiles'].append(profile)
            print(name, 'orders', [p['order'] for p in profile['partials']], 'bound', bound, flush=True)
        args.model.parent.mkdir(parents=True, exist_ok=True)
        args.model.write_text(json.dumps(model, indent=2), encoding='utf8')
    else:
        model = json.loads(args.model.read_text())
    if args.rom:
        export_rom(model, args.rom)
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
        for profile in model['profiles']:
            y = render_profile(profile)/32768.
            write_wav(args.output/(profile['source'][:-4]+'_numeric.wav'), y, FS)
    print('PARAMETER MODEL READY; numeric previews are NOT HDL simulation or DAC recordings', flush=True)


if __name__ == '__main__':
    main()
