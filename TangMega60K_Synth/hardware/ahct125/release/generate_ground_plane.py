"""Create a fixed lower GND fill with explicit 0.30mm clearances.

Run only with this project's EDA session closed. The native editor is reopened
afterward for full DRC and Gerber export. This does not assert physical testing.
The fill is divided into hole-free horizontal contours to avoid ambiguous FILL
hole semantics. Their exact union is checked against the intended copper.
"""
import json
import shutil
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'.deps'))
import shapely
from shapely import affinity
from shapely.geometry import Point, LineString, Polygon, box
from shapely.ops import unary_union

PROJECT = Path('C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1')
PCB = PROJECT/'pcb/PCB1.epcb2'
MM = .0254
CLEAR = .30

def compact(v):
    return json.dumps(v, ensure_ascii=False, separators=(',', ':'))

def records(path):
    for line in path.read_text(encoding='utf-8').splitlines():
        h, sep, payload = line.partition('||')
        if not sep:
            continue
        header = json.loads(h)
        try:
            body = json.JSONDecoder().raw_decode(payload)[0]
        except (ValueError, TypeError):
            body = None  # Embedded binary documents are preserved verbatim.
        yield line, header, body

rows = list(records(PCB))
doc = None
pcb_rows = []
for line,h,b in rows:
    if h['type']=='DOCHEAD':
        doc=b['docType']
    if doc=='PCB':
        pcb_rows.append((h,b))
assert pcb_rows and any(h['type']=='COMPONENT' for h,b in pcb_rows)
backup=ROOT/'verification/pcb-before-fixed-ground.epcb2'
backup.parent.mkdir(exist_ok=True)
if not backup.exists():
    shutil.copy2(PCB,backup)

blocked=[]
anchors=[]
for h,b in pcb_rows:
    if b is None:
        continue  # Deleted primitive tombstone.
    kind=h['type']
    if kind=='LINE' and b.get('layerId')==2 and b.get('netName')!='GND':
        pts=[(b['startX']*MM,-b['startY']*MM),(b['endX']*MM,-b['endY']*MM)]
        blocked.append(LineString(pts).buffer(b['width']*MM/2+CLEAR,quad_segs=24))
    elif kind=='VIA':
        p=Point(b['centerX']*MM,-b['centerY']*MM)
        if b['netName']=='GND':
            anchors.append(p)
        else:
            blocked.append(p.buffer(b['viaDiameter']*MM/2+CLEAR,quad_segs=24))
    elif kind=='PAD' and not b.get('plated',True):
        assert b['hole']['holeType']=='ROUND'
        blocked.append(Point(b['centerX']*MM,-b['centerY']*MM).buffer(b['hole']['width']*MM/2+CLEAR,quad_segs=48))

parts=json.loads((ROOT/'references/critical-layout.json').read_text(encoding='utf-8'))['value']['parts']
for comp in parts:
    for p in comp['pads']:
        if p['layer']!=12:
            continue
        x,y=p['x']*MM,-p['y']*MM
        if p['net']=='GND':
            anchors.append(Point(x,y));continue
        shape,w,h,*rest=p['pad'];w*=MM;h*=MM
        if shape=='ELLIPSE':
            geom=affinity.scale(Point(0,0).buffer(1,quad_segs=32),w/2,h/2)
        elif shape=='RECT':
            geom=box(-w/2,-h/2,w/2,h/2)
        else:
            raise ValueError('Unexpected TH pad '+shape)
        geom=affinity.rotate(geom,-p['rotation'],origin=(0,0))
        blocked.append(affinity.translate(geom,x,y).buffer(CLEAR,quad_segs=24))

plane=box(.6,.6,39.4,29.4).difference(unary_union(blocked))
assert plane.is_valid and plane.geom_type=='Polygon',plane.geom_type
assert all(plane.covers(p) for p in anchors),'Unconnected ground anchor'
contours=[]
bounds=[.6+i*.4 for i in range(73)]
bounds[-1]=29.4
for low,high in zip(bounds,bounds[1:]):
    stripe=plane.intersection(box(.6,low,39.4,high))
    pieces=[stripe] if stripe.geom_type=='Polygon' else list(stripe.geoms)
    for piece in pieces:
        if piece.is_empty or piece.area<1e-9:
            continue
        if piece.interiors:
            contours.extend(shapely.constrained_delaunay_triangles(piece).geoms)
        else:
            contours.append(piece)
union=unary_union(contours)
assert union.symmetric_difference(plane).area<1e-7

def contour(poly):
    # Output native y-up clockwise contours, each without any internal hole.
    poly=shapely.geometry.polygon.orient(poly,sign=1)
    pts=[(round(x/MM,5),round(-y/MM,5)) for x,y in poly.exterior.coords]
    return [*pts[0],'L',*[v for p in pts[1:] for v in p]]

ticket=max(h.get('ticket',0) for h,b in pcb_rows)+1
new_lines=[]
new_ids=[]
for i,region in enumerate(contours):
    new_id=uuid.uuid4().hex[:16];new_ids.append(new_id)
    fill=dict(partitionId='',groupId=0,netName='GND',layerId=2,width=0,
              fillStyle='SOLID',path=[contour(region)],locked=True,
              zIndex=i,isBridgingCopper=False,networkList=[],refs=[])
    new_lines.append(compact(dict(type='FILL',ticket=ticket+i,id=new_id))+'||'+compact(fill)+'|')
out=[];doc=None
for line,h,b in rows:
    if h['type']=='DOCHEAD':
        doc=b['docType']
    if doc=='PCB' and (h['type'] in ('POUR','POURED') or (h['type']=='FILL' and b and b.get('layerId')==2 and b.get('netName')=='GND')):
        continue
    out.append(line)
assert doc=='PCB','PCB must be the final document before appending'
out.extend(new_lines)
PCB.write_text('\n'.join(out)+'\n',encoding='utf-8',newline='\n')
report=dict(method='Fixed GND fill, independent boolean geometry',clearance_mm=CLEAR,
            board_edge_inset_mm=.6,layer=2,area_mm2=plane.area,contours=len(contours),
            contour_union_error_mm2=union.symmetric_difference(plane).area,
            ground_anchor_count=len(anchors),all_ground_anchors_inside=True,
            primitive_ids=new_ids,shapely=shapely.__version__,
            note='Re-generate after geometry edits; run native DRC and inspect Gerber.')
(ROOT/'verification/fixed-ground-geometry.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
print(json.dumps({k:v for k,v in report.items() if k!='primitive_ids'},indent=2))
