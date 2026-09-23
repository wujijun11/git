"""I/Q -> amplitude/phase, stereo preserved. Offline slope ROM generation.
Two stereo amplitude multiplications per partial, versus four for stereo I/Q.
No PCM playback. Parameters derived from Alexander Holm, CC BY 3.0.
"""
import argparse,json,hashlib
from pathlib import Path
import numpy as np
from render_model import render,write_wav

TRIM=0
AMP_BITS=35 # 8 fractional guard bits in the amplitude accumulator
SLOTS=128

def select_knots(t,amp,phase,tolerance):
    chosen={0,len(t)-1}; stack=[(0,len(t)-1)]
    target=amp*np.exp(1j*phase)
    while stack:
        a,b=stack.pop()
        if b-a<=1: continue
        u=(t[a+1:b]-t[a])/(t[b]-t[a])
        aa=amp[a]+u[:,None]*(amp[b]-amp[a])
        pp=phase[a]+u[:,None]*(phase[b]-phase[a])
        err=np.max(abs(aa*np.exp(1j*pp)-target[a+1:b]),axis=1)
        j=int(np.argmax(err))+a+1
        if err[j-a-1]>tolerance:
            chosen.add(j); stack.extend([(a,j),(j,b)])
    return sorted(chosen)

def make_model(iq):
    fs=iq['sample_rate']; N=iq['frames']-TRIM; full=np.arange(N)+TRIM
    polar={'format':'piano_stereo_polar_v1','sample_rate':fs,'frames':N,
           'source_sha256':iq['source_sha256'],'source_work':iq['source_work'],
           'license_url':iq['license_url'],'source_url':iq['source_url'],
           'trim_samples':TRIM,'amplitude_fractional_bits':AMP_BITS,'partials':[]}
    for p in iq['partials']:
        c=np.asarray(p['controls']); z=np.stack([
            np.interp(full,c[:,0],c[:,1])+1j*np.interp(full,c[:,0],c[:,2]),
            np.interp(full,c[:,0],c[:,3])+1j*np.interp(full,c[:,0],c[:,4])],axis=1)
        amp=abs(z); phase=np.unwrap(np.angle(z),axis=0)
        # Phase is immaterial at zero amplitude; avoid a meaningless onset spin.
        phase[0]=phase[1]
        phase+=2*np.pi*p['frequency_hz']*TRIM/fs
        t=np.unique(np.r_[np.arange(0,N,16),c[:,0]-TRIM,N-1]).astype(int)
        t=t[(t>=0)&(t<N)]
        tolerance=max(float(amp.max())*.004,2e-6)
        ids=select_knots(t,amp[t],phase[t],tolerance)
        while len(ids)>SLOTS-1:
            tolerance*=1.15; ids=select_knots(t,amp[t],phase[t],tolerance)
        knots=t[ids]
        a=np.rint(amp[knots]*2**27).astype(np.int64)<<8
        th=np.rint(phase[knots]/(2*np.pi)*2**32).astype(np.int64)
        # Independently reset accumulated slopes at every boundary to bound drift.
        segments=[]
        for j in range(len(knots)-1):
            span=int(knots[j+1]-knots[j])
            da=np.rint((a[j+1]-a[j])/span).astype(np.int64)
            dt=np.rint((th[j+1]-th[j])/span).astype(np.int64)
            segments.append({'start':int(knots[j]),'end':int(knots[j+1]),
                             'a':[int(v) for v in a[j]],'da':[int(v) for v in da],
                             'theta':[int(v)&0xffffffff for v in th[j]],
                             'dtheta':[int(v) for v in dt]})
        segments.append({'start':int(knots[-1]),'end':1048575,'a':[0,0],'da':[0,0],
                         'theta':[0,0],'dtheta':[0,0]})
        polar['partials'].append({'frequency_hz':p['frequency_hz'],
            'ratio_q22':round(p['frequency_hz']/440*2**22),'segments':segments,
            'fitting_tolerance':tolerance})
    return polar

def render_polar(model):
    N=model['frames']; n=np.arange(N,dtype=np.int64); fs=model['sample_rate']
    sine=np.rint(np.sin(np.arange(1024)*2*np.pi/1024)*32767).astype(np.int64)
    result=np.zeros((N,2),np.int64)
    for p in model['partials']:
        ftw=(round(440*2**32/fs)*p['ratio_q22']+2**21)>>22
        phase=(n*ftw)&0xffffffff
        for seg in p['segments']:
            lo=seg['start']; hi=min(seg['end'],N)
            age=np.arange(hi-lo,dtype=np.int64)
            for ch in (0,1):
                amp=seg['a'][ch]+age*seg['da'][ch]
                amp=np.clip(amp,0,2**35-1)>>8
                offset=seg['theta'][ch]+age*seg['dtheta'][ch]
                addr=(((phase[lo:hi]+offset+2**30)&0xffffffff)>>22)
                result[lo:hi,ch]+=(amp*sine[addr]+2**26)>>27
    return result/32768.

def pack(seg):
    assert 0<=seg['end']<2**20
    for ch in (0,1):
        assert 0<=seg['a'][ch]<2**35
        assert -2**27<=seg['da'][ch]<2**27
        assert 0<=seg['theta'][ch]<2**32
        assert -2**31<=seg['dtheta'][ch]<2**31
    fields=[(seg['end'],20),(seg['a'][0]>>8,28),(seg['da'][0],28),
            (seg['theta'][0],32),(seg['dtheta'][0],32),
            (seg['a'][1]>>8,28),(seg['da'][1],28),
            (seg['theta'][1],32),(seg['dtheta'][1],32)]
    word=0
    for value,bits in fields: word=(word<<bits)|(value&((1<<bits)-1))
    return f'{word:065x}'

def main():
    p=argparse.ArgumentParser(); p.add_argument('--model',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True); p.add_argument('--rom',type=Path)
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    iq=json.loads(a.model.read_text()); m=make_model(iq)
    # Conservative sum of per-partial maxima bounds EVERY possible relative
    # carrier phase, including live pitch bend/transposition. No hidden 16-bit
    # per-voice saturation is required by this parameter set.
    bounds=np.sum([np.max(np.asarray([s['a'] for s in v['segments']]),axis=0)/2**35
                   for v in m['partials']],axis=0)
    assert np.max(bounds)<.99,bounds
    (a.output/'model_polar.json').write_text(json.dumps(m,indent=2),encoding='utf8')
    target=render(iq)[TRIM:]; y=render_polar(m)
    err=float(np.linalg.norm(y-target)/np.linalg.norm(target))
    correlation=float(np.corrcoef(y.ravel(),target.ravel())[0,1])
    assert err<.025,(err,correlation)
    write_wav(a.output/'polar_fixed_numeric.wav',y,48000)
    length=4*48000; gain=.5/max(abs(target[:length]).max(),abs(y[:length]).max())
    aa=target[:length].copy()*gain; bb=y[:length].copy()*gain
    for c in (aa,bb): c[-960:]*=np.linspace(1,0,960)[:,None]
    write_wav(a.output/'iq_then_polar.wav',np.concatenate([aa,np.zeros((24000,2)),bb]),48000)
    report={'relative_error_vs_iq':err,'correlation':correlation,
            'segments':[len(v['segments']) for v in m['partials']],
            'stereo_preserved':True,'partials':len(m['partials']),
            'conservative_amplitude_bound_per_channel':bounds.tolist(),
            'waveform_multiplications_per_partial_before':4,
            'waveform_multiplications_per_partial_after':2,
            'HDL_simulation':False,'common_preview_gain':float(gain)}
    (a.output/'polar_validation.json').write_text(json.dumps(report,indent=2),encoding='utf8')
    if a.rom:
        a.rom.mkdir(parents=True,exist_ok=True)
        sentinel={'end':1048575,'a':[0,0],'da':[0,0],'theta':[0,0],'dtheta':[0,0]}
        for lane in (0,1):
            words=[]
            for k in range(lane,8,2):
                records=m['partials'][k]['segments']
                assert len(records)<=SLOTS and records[0]['start']==0
                assert all(x['end']==y['start'] for x,y in zip(records,records[1:]))
                words += [pack(s) for s in records]+[pack(sentinel)]*(SLOTS-len(records))
            (a.rom/f'polar_lane{lane}.hex').write_text('\n'.join(words)+'\n',encoding='ascii')
        assert all(0<v['ratio_q22']<2**27 for v in m['partials'])
        (a.rom/'polar_ratios.hex').write_text('\n'.join(f"{v['ratio_q22']:07x}" for v in m['partials'])+'\n',encoding='ascii')
    print(json.dumps(report,indent=2))

if __name__=='__main__': main()
