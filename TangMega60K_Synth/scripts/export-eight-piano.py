"""Verify actual ModelSim PCM; export WAV and loudness-matched comparisons.
The optional real recording is a labelled reference only, never mixed into
HDL-generated output. All listening gains are recorded in the report.
"""
import argparse
import json
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).parent/'piano_model'))
from refine_eight import render_profile, bank_for_note, frequency
from render_model import read_wav, write_wav

FS=48000


def load_pcm(path):
    data=np.loadtxt(path, delimiter=',', skiprows=1, dtype=np.int64)
    assert np.array_equal(data[:,0], np.arange(len(data)))
    assert np.max(abs(data[:,1:])) < 8388607, 'PCM clipping'
    return data[:,1:]


def rms(x):
    return float(np.sqrt(np.mean(x.astype(float)**2)))


def pitch(x, note):
    mono=x[4800:24000].mean(axis=1).astype(float)
    spec=abs(np.fft.rfft(mono*np.hanning(len(mono)), n=262144))
    hz=np.fft.rfftfreq(262144, 1/FS)
    bins=np.flatnonzero(abs(hz-frequency(note))<frequency(note)*.02)
    k=bins[np.argmax(spec[bins])]
    a=np.log(np.maximum(spec[k-1:k+2],1e-30))
    d=.5*(a[0]-a[2])/(a[0]-2*a[1]+a[2])
    return float((k+np.clip(d,-.5,.5))*FS/262144)


def spectral_error(reference, candidate):
    # Per-channel level normalization removes the existing voice-id panning
    # from this spectral diagnostic. Listening files retain the real panning.
    a=reference[:48000]/np.maximum(np.sqrt(np.mean(reference[4800:24000]**2,axis=0)),1e-15)
    b=candidate[:48000]/np.maximum(np.sqrt(np.mean(candidate[4800:24000]**2,axis=0)),1e-15)
    scores={}
    for size in (1024,2048,8192):
        aa=np.stack([abs(np.fft.rfft(a[i:i+size]*np.hanning(size)[:,None],axis=0))
                     for i in range(0,min(len(a),len(b))-size+1,size//4)])
        bb=np.stack([abs(np.fft.rfft(b[i:i+size]*np.hanning(size)[:,None],axis=0))
                     for i in range(0,min(len(a),len(b))-size+1,size//4)])
        scores[str(size)]=float(np.linalg.norm(aa-bb)/np.linalg.norm(aa))
    return scores


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--input', type=Path, required=True)
    p.add_argument('--model', type=Path, required=True)
    p.add_argument('--baseline', type=Path)
    p.add_argument('--references', type=Path)
    a=p.parse_args(); model=json.loads(a.model.read_text())
    root=a.input
    for sub in ('raw','listen'):
        (root/sub).mkdir(exist_ok=True)
    report=dict(source='ModelSim HDL PCM, not DAC measurements', notes={}, lane_bit_exact={},
                clipping_samples=0, pure_fm_retained=True, source_audio_mixed_into_synthesis=False)
    for profile in model['profiles']:
        note=profile['root_midi']
        pcm=load_pcm(root/f'lane_{note}.csv')
        expected=render_profile(profile, frames=len(pcm))
        assert np.array_equal(pcm,expected), f'Lane {note} differs from fixed model; max {np.max(abs(pcm-expected))}'
        report['lane_bit_exact'][str(note)]=len(pcm)
    clips={}
    for note in range(60,85):
        pcm=load_pcm(root/f'note_{note}.csv')
        assert np.any(pcm!=0) and np.max(abs(pcm[-1200:]))<=16
        f=pitch(pcm,note)
        assert abs(1200*np.log2(f/frequency(note)))<35, (note,f)
        x=pcm/8388608.; clips[note]=x
        report['notes'][str(note)]=dict(profile=bank_for_note(note), frames=len(pcm),
             peak_pcm=int(np.max(abs(pcm))), fundamental_hz=f,
             cents_from_equal_temperament=float(1200*np.log2(f/frequency(note))))
        write_wav(root/'raw'/f'note_{note}.wav',x,FS)
    # One gain for the entire new keyboard, based on A4; no per-key flattening.
    gain=.08/max(rms(clips[69][4800:24000]),1e-12)
    gain=min(gain, .75/max(np.max(abs(x)) for x in clips.values()))
    report['keyboard_listening_gain']=gain
    for note,x in clips.items():
        write_wav(root/'listen'/f'note_{note}.wav', x*gain, FS)
    gap=np.zeros((7200,2))
    write_wav(root/'listen'/'C4_C6_selection.wav', np.concatenate([v for note in (60,64,67,69,72,76,79,84)
                            for v in (clips[note]*gain,gap)]), FS)
    write_wav(root/'listen'/'all_25_keys.wav',np.concatenate([v for note in range(60,85)
                            for v in (clips[note]*gain,gap)]), FS)
    if a.baseline:
        old={note:load_pcm(a.baseline/f'note_{note}.csv')/8388608. for note in range(60,85)}
        old_gain=1/max(rms(old[69][4800:24000]),1e-12)
        new_gain=1/max(rms(clips[69][4800:24000]),1e-12)
        both_peak=max(max(np.max(abs(x))*old_gain for x in old.values()),
                      max(np.max(abs(x))*new_gain for x in clips.values()))
        common=min(.08,.75/both_peak)
        old_gain*=common; new_gain*=common
        report['AB_gains']=dict(old=old_gain,new=new_gain,match_window='A4 100-500 ms RMS; one gain per whole version')
        for note in (60,69,72,84):
            assert abs(len(old[note])-len(clips[note]))<=2
            write_wav(root/'listen'/f'compare_{note}_old_then_new.wav',
                      np.concatenate([old[note]*old_gain,gap,clips[note]*new_gain]),FS)
        write_wav(root/'listen'/'A4_old.wav',old[69]*old_gain,FS)
        write_wav(root/'listen'/'A4_new.wav',clips[69]*new_gain,FS)
        if a.references:
            report['reference_spectral_comparison']={}
            for profile in model['profiles']:
                note=profile['root_midi']; ref,_=read_wav(a.references/profile['source'])
                ref=ref[profile['trim_samples']:profile['trim_samples']+len(clips[note])].copy()
                # A labelled recording excerpt with the same 1 s hold and
                # 100 ms fade for listening only, not used by the synthesizer.
                ref[48000:52800]*=np.linspace(1,0,4800)[:,None]; ref[52800:]=0
                ref_gain=common/max(rms(ref[4800:24000]),1e-12)
                ref_gain=min(ref_gain,.75/np.max(abs(ref)))
                write_wav(root/'listen'/f'reference_{note}.wav',ref*ref_gain,FS)
                report['reference_spectral_comparison'][str(note)]=dict(
                    old=spectral_error(ref,old[note]),new=spectral_error(ref,clips[note]),
                    reference_listening_gain=ref_gain)
                if note==69:
                    write_wav(root/'listen'/'A4_old_new_reference.wav',
                        np.concatenate([old[note]*old_gain,gap,clips[note]*new_gain,gap,ref*ref_gain]),FS)
            report['metric_limit']='Same-reference fitting comparison with per-channel RMS normalization to remove fixed panning; not an independent perceptual test or realism score.'
    (root/'validation.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    rows=[[n,frequency(n),report['notes'][str(n)]['fundamental_hz'],
           report['notes'][str(n)]['cents_from_equal_temperament'],bank_for_note(n)] for n in range(60,85)]
    np.savetxt(root/'frequencies_25.csv',rows,delimiter=',',
               header='midi,theoretical_hz,measured_pcm_hz,cents_error,profile_bank',comments='')
    print(json.dumps({k:v for k,v in report.items() if k!='notes'},indent=2))
    print('EIGHT PCM PASSED: bit-exact four regions, 25 notes, complete releases, no clipping')


if __name__=='__main__':
    main()
