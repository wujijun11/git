"""Independent continuous geometry and layer connectivity verification."""
import json,math,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[3]/'ahct125/.deps'))
from shapely.geometry import Point,LineString,box
from shapely.ops import unary_union
from shapely.strtree import STRtree
HERE=Path(__file__).resolve().parent

def padshape(p):
    if p['shape']=='RECT':return box(p['x']-p['width']/2,p['y']-p['height']/2,p['x']+p['width']/2,p['y']+p['height']/2)
    assert abs(p['width']-p['height'])<.001
    return Point(p['x'],p['y']).buffer(p['width']/2,quad_segs=64)
def check(d):
    objs=[]
    for p in d['pads']:objs.append(dict(kind='pad',net=p['net'],ref=p['ref']+'.'+p['pin'],layers={1,2},g=padshape(p)))
    for i,t in enumerate(d['tracks']):objs.append(dict(kind='track',net=t['net'],ref=i,layers={t['layer']},g=LineString([t['a'],t['b']]).buffer(t['width']/2,quad_segs=64)))
    for i,v in enumerate(d['vias']):objs.append(dict(kind='via',net=v['net'],ref=i,layers={1,2},g=Point(v['x'],v['y']).buffer(v['diameter']/2,quad_segs=64)))
    errors=[];mingap=999;minhole=999;minedge=999
    gs=[o['g'] for o in objs];tree=STRtree(gs);threshold=.20
    for i,o in enumerate(objs):
        for k in tree.query(o['g'].buffer(.35)):
            j=int(k)
            if j>=i:continue
            b=objs[j]
            if not o['layers']&b['layers']:continue
            if o['net'] and o['net']==b['net']:continue
            gap=o['g'].distance(b['g']);mingap=min(mingap,gap)
            if gap<threshold-1e-5:errors.append(dict(type='copper',a=[o['kind'],o['ref'],o['net']],b=[b['kind'],b['ref'],b['net']],gap=gap))
        g=o['g'];x0,y0,x1,y1=g.bounds;gap=min(x0,y0,d['boardMm'][0]-x1,d['boardMm'][1]-y1);minedge=min(minedge,gap)
        if gap<.30-1e-5:errors.append(dict(type='edge',object=[o['kind'],o['ref']],gap=gap))
        for x,y,r in d['holes']:
            gap=g.distance(Point(x,y))-r;minhole=min(minhole,gap)
            if gap<.30-1e-5:errors.append(dict(type='hole',object=[o['kind'],o['ref']],gap=gap))
    nets=[]
    for net in sorted({o['net'] for o in objs if o['net']}):
        ns=[o for o in objs if o['net']==net];parent=list(range(len(ns)))
        def find(i):
            while parent[i]!=i:parent[i]=parent[parent[i]];i=parent[i]
            return i
        for i,o in enumerate(ns):
            for j,b in enumerate(ns[:i]):
                if o['layers']&b['layers'] and o['g'].distance(b['g'])<.00001:parent[find(i)]=find(j)
        parts=len({find(i) for i in range(len(ns))})
        nets.append(dict(net=net,pads=sum(o['kind']=='pad' for o in ns),components=parts))
        if parts!=1:errors.append(dict(type='connection',net=net,components=parts))
    out=dict(pass_all=not errors,pads=len(d['pads']),wired_pads=sum(bool(p['net']) for p in d['pads']),nc_pads=sum(not p['net'] for p in d['pads']),tracks=len(d['tracks']),vias=len(d['vias']),minimum_copper_gap_mm=mingap,minimum_hole_gap_mm=minhole,minimum_edge_gap_mm=minedge,nets=nets,errors=errors)
    return out
if __name__=='__main__':
    p=HERE/'routing_r2_verified.json';d=json.loads(p.read_text(encoding='utf8'));r=check(d)
    (HERE/'r2_geometry_check.json').write_text(json.dumps(r,indent=2),encoding='utf8')
    print(json.dumps({k:v for k,v in r.items() if k!='nets'},indent=2));sys.exit(0 if r['pass_all'] else 1)
