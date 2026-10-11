"""Independent geometric preflight; this does NOT replace native PCB DRC."""
from pathlib import Path
import json,math,zipfile,collections
ROOT=Path(__file__).parent
EPS=1e-8

def edges(p):return list(zip(p,p[1:]+p[:1]))
def cross(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
def point_seg(p,a,b):
    dx,dy=b[0]-a[0],b[1]-a[1];d=dx*dx+dy*dy
    t=0 if d<EPS else max(0,min(1,((p[0]-a[0])*dx+(p[1]-a[1])*dy)/d))
    return math.hypot(p[0]-(a[0]+t*dx),p[1]-(a[1]+t*dy))
def seg_dist(a,b,c,d):
    if cross(a,b,c)*cross(a,b,d)<=EPS and cross(c,d,a)*cross(c,d,b)<=EPS:
        if max(min(a[0],b[0]),min(c[0],d[0]))<=min(max(a[0],b[0]),max(c[0],d[0]))+EPS and max(min(a[1],b[1]),min(c[1],d[1]))<=min(max(a[1],b[1]),max(c[1],d[1]))+EPS:return 0.0
    return min(point_seg(a,c,d),point_seg(b,c,d),point_seg(c,a,b),point_seg(d,a,b))
def inside(pt,poly):
    x,y=pt;value=False
    for a,b in edges(poly):
        if point_seg(pt,a,b)<EPS:return True
        if (a[1]>y)!=(b[1]>y) and x<(b[0]-a[0])*(y-a[1])/(b[1]-a[1])+a[0]:value=not value
    return value
def pt_poly(pt,poly):return 0.0 if inside(pt,poly) else min(point_seg(pt,a,b) for a,b in edges(poly))
def line_poly(a,b,poly):return 0.0 if inside(a,poly) or inside(b,poly) else min(seg_dist(a,b,c,d) for c,d in edges(poly))
def poly_poly(a,b):return 0.0 if inside(a[0],b) or inside(b[0],a) else min(seg_dist(p,q,r,s) for p,q in edges(a) for r,s in edges(b))
def square(center,r):
    x,y=center;return [[x-r,y-r],[x+r,y-r],[x+r,y+r],[x-r,y+r]]
def pad_line(p,a,b):return line_poly(a,b,square(p['xy'],p['r'])) if p['square'] else point_seg(p['xy'],a,b)-p['r']
def pad_pad(a,b):
    if a['square'] and b['square']:return poly_poly(square(a['xy'],a['r']),square(b['xy'],b['r']))
    if a['square']:return pt_poly(b['xy'],square(a['xy'],a['r']))-b['r']
    if b['square']:return pt_poly(a['xy'],square(b['xy'],b['r']))-a['r']
    return math.dist(a['xy'],b['xy'])-a['r']-b['r']

def main():
    m=json.loads((ROOT/'design_manifest.json').read_text(encoding='utf-8'));ks=m['keys']
    assert [k['midi'] for k in ks]==list(range(60,85))
    assert len(set(k['net'] for k in ks))==25
    assert [sum(k['connector']==j for k in ks) for j in ['J1','J2','J3']]==[8,8,9]
    assert sum(k['color']=='white' for k in ks)==15
    assert [k['ele'] for k in ks]==list(range(8))+list(range(8))+list(range(9))
    for k in ks:
        assert pt_poly(k['top_trace_mm'][0],k['electrode_polygon_mm'])<EPS
        assert k['top_trace_mm'][-1]==k['transfer_mm']==k['bottom_route_mm'][0]
        assert k['bottom_route_mm'][-1]==k['connector_pin_mm']
    copper=[];pads=[];fills=[]
    for k in ks:
        for layer,key in [(1,'top_trace_mm'),(2,'bottom_route_mm')]:
            for a,b in zip(k[key],k[key][1:]):copper.append(dict(net=k['net'],layer=layer,a=a,b=b,r=.09))
        pads.extend([dict(net=k['net'],xy=k['transfer_mm'],r=m['transfer_pads']['outer_mm']/2,square=False),dict(net=k['net'],xy=k['connector_pin_mm'],r=.9,square=k['pin']==1)])
        fills.append(dict(net=k['net'],poly=k['electrode_polygon_mm']))
    minima={};counts=collections.Counter()
    def observe(kind,d,refs):
        counts[kind]+=1
        if kind not in minima or d<minima[kind]['clearance_mm']:minima[kind]=dict(clearance_mm=round(d,6),refs=refs)
    for i,t in enumerate(copper):
        for u in copper[i+1:]:
            if t['layer']==u['layer'] and t['net']!=u['net']:observe('different_net_trace_trace',seg_dist(t['a'],t['b'],u['a'],u['b'])-t['r']-u['r'],[t['net'],u['net'],t['layer']])
        for p in pads:
            if t['net']!=p['net']:observe('different_net_trace_pad',pad_line(p,t['a'],t['b'])-t['r'],[t['net'],p['net'],t['layer']])
        if t['layer']==1:
            for f in fills:
                if t['net']!=f['net']:observe('different_net_trace_electrode',line_poly(t['a'],t['b'],f['poly'])-t['r'],[t['net'],f['net']])
    for i,p in enumerate(pads):
        for q in pads[i+1:]:
            if p['net']!=q['net']:observe('different_net_pad_pad',pad_pad(p,q),[p['net'],q['net']])
        for f in fills:
            if p['net']!=f['net']:
                d=poly_poly(square(p['xy'],p['r']),f['poly']) if p['square'] else pt_poly(p['xy'],f['poly'])-p['r']
                observe('different_net_pad_electrode',d,[p['net'],f['net']])
    for i,f in enumerate(fills):
        for g in fills[i+1:]:observe('different_net_electrode_electrode',poly_poly(f['poly'],g['poly']),[f['net'],g['net']])
    for x,y in m['mounting_holes']['centers_mm']:
        h=dict(net='',xy=[x,y],r=1.6,square=False)
        for p in pads:observe('npth_to_pad',pad_pad(h,p),[h['xy'],p['net']])
        for t in copper:observe('npth_to_trace',pad_line(h,t['a'],t['b'])-t['r'],[h['xy'],t['net'],t['layer']])
        for f in fills:observe('npth_to_electrode',pt_poly(h['xy'],f['poly'])-1.6,[h['xy'],f['net']])
    assert all(v['clearance_mm']>=.1524 for v in minima.values()),minima
    archive=ROOT/(m['name']+'.epro2')
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        r=z.read(m['name']+'.epru').decode('utf-8')
        data=[(json.loads(a),json.loads(b.rstrip('|'))) for a,_,b in (v.partition('||') for v in r.splitlines())]
    ct=collections.Counter(h['type'] for h,b in data)
    assert ct['FILL']==25 and ct['PAD']==56 and ct['DOCHEAD']==2
    assert not any(b.get('netName') in {'GND','3V3','VCC','SCL','SDA'} for h,b in data)
    assert not any(h['type']=='FILL' and b['layerId'] in {5,6,7,8} for h,b in data)
    assert min(b['fontSize']*25.4/1000 for h,b in data if h['type']=='STRING')>=.999999
    assert min(b['strokeWidth']*25.4/1000 for h,b in data if h['type']=='STRING')>=.149999
    report=dict(status='PASS: independent geometry preflight only',native_drc='NOT RUN',native_gerber='NOT EXPORTED',key_mapping='PASS',continuous_connections='PASS',minimum_required_spacing_mm=.1524,checked_counts=dict(counts),minimum_clearances=minima,native_record_counts=dict(ct),notes=['Checks use manifest geometry and closed electrode polygons, not native editor connectivity results.','Round electrode polygon corners approximate 1.5 mm radius with 8 chords per quadrant.','No claim of measured MPR121 touch response, EMC performance or complete-system latency.','The 0.8/0.3 mm transfer pads require native mask-tenting validation.','Native STRING minimum height is 1.0 mm and minimum stroke is 0.15 mm.'])
    (ROOT/'geometry_preflight.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__':main()
