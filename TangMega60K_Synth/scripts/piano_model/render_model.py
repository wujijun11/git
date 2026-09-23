"""Render a parameter-only sinusoidal model. No source audio is read here.

x_c[n] = sum_k I_k,c[n] cos(phase_k[n]) - Q_k,c[n] sin(phase_k[n]).
I/Q are slowly varying, piecewise-linear control values, not PCM waveforms.
"""
import argparse
import hashlib
import json
from pathlib import Path
import wave
import numpy as np

def read_wav(path):
    with wave.open(str(path),'rb') as w:
        assert w.getsampwidth()==3 and w.getnchannels()==2
        fs=w.getframerate(); b=w.readframes(w.getnframes())
    a=np.frombuffer(b,np.uint8).reshape(-1,3).astype(np.int64)
    v=a[:,0]+(a[:,1]<<8)+(a[:,2]<<16)
    v=np.where(v&0x800000,v-0x1000000,v)
    return v.reshape(-1,2)/8388608.,fs

def write_wav(path,x,fs):
    assert np.isfinite(x).all() and np.max(np.abs(x))<1, 'No silent clipping permitted'
    v=np.rint(x*8388608).astype(np.int64)
    assert v.min()>=-8388608 and v.max()<=8388607
    u=v.reshape(-1)&0xffffff
    b=np.stack([u&255,(u>>8)&255,(u>>16)&255],1).astype(np.uint8).tobytes()
    with wave.open(str(path),'wb') as w:
        w.setnchannels(2); w.setsampwidth(3); w.setframerate(fs); w.writeframes(b)
    y,fs2=read_wav(path)
    assert fs2==fs and np.array_equal(y*8388608,v)
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def render(model,fixed=False):
    fs=model['sample_rate']; count=model['frames']; n=np.arange(count,dtype=np.int64)
    assert fs>0 and count>1 and model['format']=='piano_iq_control_model_v1'
    out=np.zeros((count,2),dtype=np.float64 if not fixed else np.int64)
    table=np.rint(32767*np.sin(2*np.pi*np.arange(1024)/1024)).astype(np.int64)
    for part in model['partials']:
        controls=np.asarray(part['controls'],dtype=float)
        idx=controls[:,0].astype(np.int64)
        f=part['frequency_hz']
        assert controls.ndim==2 and controls.shape[1]==5 and len(idx)>=2
        assert np.isfinite(controls).all() and np.all(controls[:,0]==idx)
        assert idx[0]==0 and idx[-1]==count-1 and np.all(np.diff(idx)>0)
        assert np.max(abs(controls[:,1:]))<1 and 0<f<fs/2
        if fixed:
            ftw=round(f/fs*2**32)
            address=((n*ftw)&0xffffffff)>>22
            sn=table[address]; cs=table[(address+256)&1023]
            q=np.rint(controls[:,1:]*2**23).astype(np.int64)
            j=np.clip(np.searchsorted(idx,n,side='right')-1,0,len(idx)-2)
            span=idx[j+1]-idx[j]; elapsed=n-idx[j]
            for channel in range(2):
                i=2*channel
                iq=q[j,i:i+2]+((q[j+1,i:i+2]-q[j,i:i+2])*elapsed[:,None])//span[:,None]
                out[:,channel]+=(iq[:,0]*cs-iq[:,1]*sn+16384)>>15
        else:
            angle=2*np.pi*f*n/fs; cs=np.cos(angle); sn=np.sin(angle)
            for channel in range(2):
                i=1+2*channel
                ii=np.interp(n,idx,controls[:,i]); qq=np.interp(n,idx,controls[:,i+1])
                out[:,channel]+=ii*cs-qq*sn
    return out/2**23 if fixed else out

def main():
    p=argparse.ArgumentParser(); p.add_argument('--model',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True); p.add_argument('--fixed',action='store_true')
    a=p.parse_args(); m=json.loads(a.model.read_text(encoding='utf8'))
    x=render(m,a.fixed); a.output.parent.mkdir(parents=True,exist_ok=True)
    digest=write_wav(a.output,x,m['sample_rate'])
    print(json.dumps({'wav':str(a.output),'sha256':digest,'partials':len(m['partials']),
                     'source_audio_read':False,'fixed_point_numerical_model':a.fixed,'HDL_simulation':False}))

if __name__=='__main__': main()
