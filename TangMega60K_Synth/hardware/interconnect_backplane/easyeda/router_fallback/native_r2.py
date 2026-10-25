"""Read exact, latest native CAD records without changing a running editor."""
import json, math
from pathlib import Path

HERE=Path(__file__).resolve().parent
SOURCE=HERE.parent/'TangMega60K-Backplane-R2-SameSide'
MM=.0254

def records(path):
    docs={};info={};doc=None
    for line in Path(path).read_text(encoding='utf8').splitlines():
        if '||' not in line: continue
        h,b=line.split('||',1); h=json.loads(h)
        try: v=json.JSONDecoder().raw_decode(b)[0]
        except (ValueError,TypeError): v=None
        if h['type']=='DOCHEAD':
            doc=v['uuid'];info[doc]=v;docs[doc]={}
        docs[doc][h['type'],h.get('id','HEAD')]=(h,v)
    return {k:[(h,v) for h,v in d.values() if v is not None] for k,d in docs.items()},info

def read_pads(path=SOURCE/'pcb/PCB1.epcb2'):
    docs,info=records(path)
    uid=next(k for k,v in info.items() if v['docType']=='PCB');rows=docs[uid]
    attrs={};nets={}
    for h,v in rows:
        if h['type']=='ATTR':attrs.setdefault(v.get('parentId'),{})[v['key']]=v['value']
        elif h['type']=='PAD_NET':
            _,cid,n,pid=json.loads(h['id']);nets[cid,str(n)]=v['padNet']
    pads=[]
    for h,c in rows:
        if h['type']!='COMPONENT':continue
        cid=h['id'];a=attrs[cid];fp=a['Footprint'];angle=math.radians(c['angle'])
        for ph,p in docs[fp]:
            if ph['type']!='PAD':continue
            x=c['x']+p['centerX']*math.cos(angle)-p['centerY']*math.sin(angle)
            y=c['y']+p['centerX']*math.sin(angle)+p['centerY']*math.cos(angle)
            s=p['defaultPad'];w=s['width']*MM;ht=s['height']*MM
            if round(c['angle'])%180==90:w,ht=ht,w
            pads.append(dict(ref=a['Designator'],pin=str(p['num']),net=nets.get((cid,str(p['num'])),''),
                x=x*MM,y=-y*MM,width=w,height=ht,shape=s['padType'],drill=p['hole']['width']*MM))
    holes=[]
    for h,p in rows:
        if h['type']=='PAD' and not p.get('plated',True):
            holes.append([p['centerX']*MM,-p['centerY']*MM,p['hole']['width']*MM/2])
    assert len(pads)==69 and sum(bool(p['net']) for p in pads)==42
    return pads,holes

if __name__=='__main__':
    p,h=read_pads();print(json.dumps(dict(pads=p,holes=h),indent=2))
