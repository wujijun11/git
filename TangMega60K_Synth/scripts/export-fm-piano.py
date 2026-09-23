"""Export actual FM V2 engine PCM and level-matched A4 comparisons."""
import argparse, json, sys
from pathlib import Path
import numpy as np
sys.path.insert(0,str(Path(__file__).parent/'piano_model'))
from render_model import read_wav,write_wav

FS=48000

def measure(x):
    start=int(.10*FS); end=int(.28*FS)
    sig=x[start:end,0]
    nfft=131072; spec=abs(np.fft.rfft(sig*np.hanning(len(sig)),n=nfft))**2
    hz=np.fft.rfftfreq(nfft,1/FS)
    subset=np.flatnonzero((hz>435)&(hz<445))
    pitch=float(hz[subset[np.argmax(spec[subset])]])
    return {'rms_100_280ms':float(np.sqrt(np.mean(x[start:end]**2))),
            'peak_hz':pitch,
            'above_2k_percent':float(100*spec[hz>2000].sum()/spec.sum()),
            'above_4k_percent':float(100*spec[hz>4000].sum()/spec.sum())}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--input',type=Path,required=True)
    ap.add_argument('--previous',type=Path,required=True)
    ap.add_argument('--reference',type=Path,required=True)
    a=ap.parse_args();root=a.input; (root/'raw').mkdir(exist_ok=True)
    (root/'listen').mkdir(exist_ok=True)
    clips={}
    for f in root.glob('clip_*.csv'):
        k=int(f.stem.split('_')[1].strip())
        if k not in (20,21,22,23):continue
        d=np.loadtxt(f,delimiter=',',skiprows=1,dtype=np.int64)
        assert np.array_equal(d[:,0],np.arange(len(d)))
        assert np.max(abs(d[:,1:]))<8388607 and np.any(d[:,1:]!=0)
        assert np.all(d[:3000,1:]==0) and np.max(abs(d[-1200:,1:]))<=16
        clips[k]=d[:,1:]
    assert set(clips)=={20,21,22,23}
    names={20:'01_fm_A4',21:'02_fm_soft',22:'03_fm_hard',23:'04_fm_64voices'}
    report={'source':'ModelSim HDL V2 output, NOT DAC recording',
            'bits':24,'sample_rate':FS,'clipped_samples':0,'clips':{}}
    for k,pcm in clips.items():
        name=names[k]
        write_wav(root/'raw'/(name+'.wav'),pcm/8388608,FS)
        report['clips'][name]={'frames':len(pcm),
            'raw_peak':int(np.max(abs(pcm))),**measure(pcm/8388608)}
    soft=report['clips']['02_fm_soft']; hard=report['clips']['03_fm_hard']
    assert hard['rms_100_280ms']>soft['rms_100_280ms']*1.5
    assert hard['above_2k_percent']>soft['above_2k_percent']*1.15, 'Velocity changed volume but not FM brightness'
    assert 438<report['clips']['01_fm_A4']['peak_hz']<442
    fm=clips[20][:FS//2]/8388608
    prior,fs=read_wav(a.previous); assert fs==FS
    prior=prior[:FS//2]
    reference,fs=read_wav(a.reference); assert fs==FS
    reference=np.concatenate([np.zeros((3840,2)),reference[:FS//2-3840]])
    pair={'previous_piano':prior,'two_operator_fm':fm,'real_reference_v12':reference}
    # Same measured RMS in the same time region; separate gains are disclosed.
    target=.08
    listen=[]
    for name,x in pair.items():
        m=measure(x); gain=target/max(m['rms_100_280ms'],1e-9)
        y=x*gain
        assert np.max(abs(y))<1,(name,gain)
        y[-480:]*=np.linspace(1,0,480)[:,None]
        write_wav(root/'listen'/(name+'.wav'),y,FS)
        report[name]={**m,'match_rms_gain':float(gain)}
        listen.append(y)
    fm_gain=report['two_operator_fm']['match_rms_gain']
    for key,name in ((20,'fm_A4_full'),(21,'fm_soft_full'),(22,'fm_hard_full')):
        full=clips[key]/8388608*fm_gain
        assert np.max(abs(full))<1
        write_wav(root/'listen'/(name+'.wav'),full,FS)
    sep=np.zeros((FS//5,2))
    write_wav(root/'listen'/'00_previous_FM_reference.wav',
              np.concatenate([listen[0],sep,listen[1],sep,listen[2]]),FS)
    report['preview_order']=['previous_piano','two_operator_fm','real_reference_v12']
    (root/'analysis.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
