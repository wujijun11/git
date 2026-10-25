"""Two-layer router with reserved endpoint vias and exact collinear compression.
No EDA application automation. Output must pass independent geometry validation.
"""
import json,math,heapq,time,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[3]/'ahct125/.deps'))
import numpy as np
from native_r2 import read_pads,HERE

PADS,HOLES=read_pads();BY={(p['ref'],p['pin']):p for p in PADS}
W,H=190.,50.; STEP=.10; NX=int(W/STEP)+1;NY=int(H/STEP)+1
CLEAR=.22;GUARD=.085;VR=.4;TRACKS=[];VIAS=[];ESC={};END={};CONNECTIONS=[]
def q(p):return tuple(round(v/STEP)*STEP for v in p)
def xy(ref,pin):p=BY[ref,str(pin)];return p['x'],p['y']
def seg(net,l,a,b,w):
    if math.dist(a,b)>1e-8:TRACKS.append(dict(net=net,layer=l,a=list(a),b=list(b),width=w))
def via(net,p):
    if not any(v['net']==net and math.dist((v['x'],v['y']),p)<1e-6 for v in VIAS):VIAS.append(dict(net=net,x=p[0],y=p[1],diameter=VR*2,drill=.3))
def region(x0,y0,x1,y1):
    a=max(0,int(math.floor(x0/STEP)));b=max(0,int(math.floor(y0/STEP)))
    c=min(NX-1,int(math.ceil(x1/STEP)));d=min(NY-1,int(math.ceil(y1/STEP)))
    return a,b,c,d,np.arange(a,c+1)[None,:]*STEP,np.arange(b,d+1)[:,None]*STEP
def circle(m,x,y,r):
    a,b,c,d,X,Y=region(x-r,y-r,x+r,y+r);m[b:d+1,a:c+1]|=(X-x)**2+(Y-y)**2<=r*r
def capsule(m,a,b,r):
    x0,y0,x1,y1,X,Y=region(min(a[0],b[0])-r,min(a[1],b[1])-r,max(a[0],b[0])+r,max(a[1],b[1])+r)
    dx=b[0]-a[0];dy=b[1]-a[1];dd=dx*dx+dy*dy
    t=np.clip(((X-a[0])*dx+(Y-a[1])*dy)/(dd or 1),0,1)
    m[y0:y1+1,x0:x1+1]|=(X-a[0]-t*dx)**2+(Y-a[1]-t*dy)**2<=r*r
def masks(net,half):
    m=np.zeros((2,NY,NX),dtype=bool);edge=.35+half+GUARD;k=math.ceil(edge/STEP)
    m[:,:k,:]=1;m[:,-k:,:]=1;m[:,:,:k]=1;m[:,:,-k:]=1
    for p in PADS:
        if p['net']==net:continue
        grow=half+CLEAR+GUARD
        if p['shape']=='RECT':
            a,b,c,d,X,Y=region(p['x']-p['width']/2-grow,p['y']-p['height']/2-grow,p['x']+p['width']/2+grow,p['y']+p['height']/2+grow)
            dx=np.maximum(np.abs(X-p['x'])-p['width']/2,0);dy=np.maximum(np.abs(Y-p['y'])-p['height']/2,0)
            m[:,b:d+1,a:c+1]|=dx*dx+dy*dy<=grow*grow
        else:
            for l in m:circle(l,p['x'],p['y'],max(p['width'],p['height'])/2+grow)
    for x,y,r in HOLES:
        for l in m:circle(l,x,y,r+half+.35+GUARD)
    for t in TRACKS:
        if t['net']!=net:capsule(m[t['layer']-1],t['a'],t['b'],t['width']/2+half+CLEAR+GUARD)
    for v in VIAS:
        if v['net']!=net:
            for l in m:circle(l,v['x'],v['y'],v['diameter']/2+half+CLEAR+GUARD)
    return m
def setup():
    for net,pins,y,l in [('LED_5V_AUX',[('J8',1),('J9',1)],48,1),('GND',[('J8',2),('J9',2)],42,2)]:
        a=xy(*pins[0]);b=xy(*pins[1]);seg(net,l,a,(a[0],y),1.8);seg(net,l,(a[0],y),(b[0],y),1.8);seg(net,l,(b[0],y),b,1.8)
    for p in PADS:
        if not p['net'] or p['ref'] in ('J8','J9'):continue
        y=(31.0 if p['y']<37.5 else 43.5) if p['ref']=='J1' else 34.5
        ep=q((p['x'],y));ESC[p['ref'],p['pin']]=ep
        w=.6 if p['net'] in ('GND','3V3_MPR') else .3
        seg(p['net'],1,(p['x'],p['y']),(p['x'],y),w);seg(p['net'],1,(p['x'],y),ep,w);via(p['net'],ep)
def pair(net,a,b,w):
    blocked=masks(net,w/2);vb=masks(net,VR); ax,ay=[round(x/STEP) for x in a];bx,by=[round(x/STEP) for x in b]
    D=np.full((2,NY,NX),np.inf);par={};Q=[]
    def heuristic(x,y):return abs(x-bx)+abs(y-by)
    for l in (0,1):
        if not blocked[l,ay,ax]:D[l,ay,ax]=0;heapq.heappush(Q,(heuristic(ax,ay),0,l,ax,ay))
    if not Q:raise RuntimeError(f'blocked source {net} {a}')
    target=None;visited=0
    while Q:
        f,g,l,x,y=heapq.heappop(Q)
        if g>D[l,y,x]+1e-7:continue
        visited+=1
        if (x,y)==(bx,by):target=(l,x,y);break
        for dx,dy in ((1,0),(-1,0),(0,1),(0,-1)):
            xx=x+dx;yy=y+dy
            if xx<0 or xx>=NX or yy<0 or yy>=NY or blocked[l,yy,xx]:continue
            ng=g+1+(0.012 if (l==0 and dx) or (l==1 and dy) else 0)
            if ng<D[l,yy,xx]-1e-7:
                D[l,yy,xx]=ng;par[l,xx,yy]=(l,x,y);heapq.heappush(Q,(ng+heuristic(xx,yy),ng,l,xx,yy))
        ol=1-l
        if not vb[0,y,x] and not vb[1,y,x] and g+35<D[ol,y,x]:
            D[ol,y,x]=g+35;par[ol,x,y]=(l,x,y);heapq.heappush(Q,(g+35+heuristic(x,y),g+35,ol,x,y))
    if target is None:raise RuntimeError(f'no path {net} {a}->{b}; searched {visited}')
    nodes=[target];cur=target
    while cur in par:cur=par[cur];nodes.append(cur)
    nodes.reverse();runs=[];r=[nodes[0]]
    for n in nodes[1:]:
        if n[0]!=r[-1][0]:runs.append(r);r=[n]
        else:r.append(n)
    runs.append(r)
    for i,r in enumerate(runs):
        keep=[r[0]]
        for j in range(1,len(r)-1):
            a0=r[j-1];b0=r[j];c0=r[j+1]
            if (b0[1]-a0[1],b0[2]-a0[2])!=(c0[1]-b0[1],c0[2]-b0[2]):keep.append(b0)
        keep.append(r[-1]);pts=[(n[1]*STEP,n[2]*STEP) for n in keep]
        if i==0: pts[0]=a
        if i==len(runs)-1: pts[-1]=b
        if i==0:pts[0]=a
        if i==len(runs)-1:pts[-1]=b
        for p0,p1 in zip(pts,pts[1:]):seg(net,r[0][0]+1,p0,p1,w)
        if i<len(runs)-1:via(net,pts[-1])
    CONNECTIONS.append(dict(net=net,a=a,b=b,visited=visited))
    print(net,a,'->',b,'searched',visited,flush=True)
def points(net):return [ESC.get((p['ref'],p['pin']),(p['x'],p['y'])) for p in PADS if p['net']==net]
def mst(net):
    pts=points(net);out=[];got=[pts.pop()]
    while pts:
        _,i,a,b=min((math.dist(a,b),i,a,b) for i,b in enumerate(pts) for a in got)
        pts.pop(i);got.append(b);out.append((a,b))
    return out
def main():
    start=time.time();setup();nets={p['net'] for p in PADS if p['net']}-{'LED_5V_AUX'}
    order=sorted(nets-{'GND','3V3_MPR'},key=lambda n:-sum(math.dist(a,b) for a,b in mst(n)))+['3V3_MPR','GND']
    try:
        for n in order:
            for a,b in mst(n):pair(n,a,b,.6 if n in ('GND','3V3_MPR') else .3)
        status='ROUTED; geometry verification required'
    except Exception as e:status='FAIL: '+str(e)
    # All endpoints/vias/segments are quantized identically in native mil units.
    qmil=lambda v:round(v/.0254,4)*.0254
    for t in TRACKS:
        t['a']=[qmil(v) for v in t['a']];t['b']=[qmil(v) for v in t['b']]
    for v in VIAS:v['x']=qmil(v['x']);v['y']=qmil(v['y'])
    out=dict(status=status,boardMm=[W,H],units='mm',clearance_mm=CLEAR,pads=PADS,holes=HOLES,tracks=TRACKS,vias=VIAS,connections=CONNECTIONS,seconds=time.time()-start)
    (HERE/'routing_r2_verified.json').write_text(json.dumps(out,indent=2),encoding='utf8')
    print(status,'tracks',len(TRACKS),'vias',len(VIAS),'seconds',out['seconds'])
if __name__=='__main__':main()
