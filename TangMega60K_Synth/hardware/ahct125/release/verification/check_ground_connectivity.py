"""Read-only audit of the saved PCB and exported bottom copper.

Does not import/run the generator, start the editor, or modify design files.
Only writes an independent JSON evidence file alongside this script.
"""
import hashlib
import json
import math
import re
import sys
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.deps'))
import shapely
from shapely import affinity
from shapely.geometry import Point, Polygon, LineString, box
from shapely.ops import unary_union

PROJECT = Path('C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1')
PCB = PROJECT / 'pcb/PCB1.epcb2'
GERBER = PROJECT / 'Gerber_AHCT125_LED_R1.zip'
MM = 0.0254


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


docs = {}
doc = None
for line in PCB.read_text(encoding='utf-8').splitlines():
    head, sep, payload = line.partition('||')
    if not sep:
        continue
    head = json.loads(head)
    try:
        body = json.JSONDecoder().raw_decode(payload)[0]
    except ValueError:
        body = None
    if head['type'] == 'DOCHEAD':
        doc = body['uuid']
        docs[doc] = {'kind': body['docType'], 'rows': []}
    docs[doc]['rows'].append((head, body))
rows = next(d['rows'] for d in docs.values() if d['kind'] == 'PCB')
active = [(h, b) for h, b in rows if b is not None]
attrs = {}
for h, b in active:
    if h['type'] == 'ATTR':
        attrs.setdefault(b['parentId'], {})[b['key']] = b['value']
pad_nets = {}
for h, b in active:
    if h['type'] == 'PAD_NET':
        _, comp, num, local_id = json.loads(h['id'])
        pad_nets[(comp, num)] = b['padNet']


def disk(x, y, radius):
    return Point(x, y).buffer(radius, quad_segs=96)


def pad_shape(shape, w, h):
    if shape == 'RECT':
        return box(-w/2, -h/2, w/2, h/2)
    if shape == 'ELLIPSE':
        return affinity.scale(disk(0, 0, 1), w/2, h/2)
    if shape == 'OVAL':
        if w >= h:
            return LineString([(-(w-h)/2, 0), ((w-h)/2, 0)]).buffer(h/2, quad_segs=48)
        return LineString([(0, -(h-w)/2), (0, (h-w)/2)]).buffer(w/2, quad_segs=48)
    raise AssertionError('Unsupported pad shape: ' + shape)


pads = []
max_snapshot_delta = 0.0
snapshot = json.loads((ROOT / 'references/critical-layout.json').read_text(encoding='utf-8'))['value']['parts']
snap_lookup = {(c['id'], p['padNumber']): p for c in snapshot for p in c['pads']}
for h, c in active:
    if h['type'] != 'COMPONENT':
        continue
    fp = attrs[h['id']]['Footprint']
    ref = attrs[h['id']]['Designator']
    angle = c['angle']
    rad = math.radians(angle)
    for ph, p in docs[fp]['rows']:
        if ph['type'] != 'PAD' or not p:
            continue
        x = (c['x'] + p['centerX']*math.cos(rad) - p['centerY']*math.sin(rad))*MM
        y = -(c['y'] + p['centerX']*math.sin(rad) + p['centerY']*math.cos(rad))*MM
        s = p['defaultPad']
        geom = pad_shape(s['padType'], s['width']*MM, s['height']*MM)
        geom = affinity.rotate(geom, -(angle + p['padAngle']), origin=(0, 0))
        geom = affinity.translate(geom, x, y)
        hole = p.get('hole')
        if hole:
            assert hole['holeType'] == 'ROUND'
            geom = geom.difference(disk(x, y, hole['width']*MM/2))
        net = pad_nets[(h['id'], p['num'])]
        pads.append(dict(ref=ref, num=p['num'], x=x, y=y, layer=p['layerId'], net=net, geom=geom))
        sp = snap_lookup[(h['id'], p['num'])]
        max_snapshot_delta = max(max_snapshot_delta, math.hypot(x-sp['x']*MM, y+sp['y']*MM))

fills = [(h, b) for h, b in active if h['type'] == 'FILL' and b['layerId'] == 2 and b['netName'] == 'GND']
regions = []
for h, b in fills:
    assert len(b['path']) == 1 and b['path'][0][2] == 'L'
    path = b['path'][0]
    vals = path[:2] + path[3:]
    region = Polygon([(vals[i]*MM, -vals[i+1]*MM) for i in range(0, len(vals), 2)])
    assert region.is_valid and not region.interiors
    regions.append(region)
plane = unary_union(regions)
assert plane.is_valid and plane.geom_type == 'Polygon', plane.geom_type

non_ground_bottom = []
top_nodes = []
bottom_contacts = []
for p in pads:
    if p['net'] == 'GND':
        if p['layer'] == 1:
            top_nodes.append((p['ref']+'-'+p['num'], p['geom']))
        elif p['layer'] == 12:
            bottom_contacts.append((p['ref']+'-'+p['num'], p['geom']))
    elif p['layer'] in (2, 12):
        non_ground_bottom.append((p['ref']+'-'+p['num'], p['geom']))

gnd_vias = []
top_lines = []
for h, b in active:
    if h['type'] == 'VIA':
        geom = disk(b['centerX']*MM, -b['centerY']*MM, b['viaDiameter']*MM/2)
        if b['netName'] == 'GND':
            gnd_vias.append((h['id'], geom))
            bottom_contacts.append(('via-'+h['id'], geom))
        else:
            non_ground_bottom.append(('via-'+h['id'], geom))
    elif h['type'] == 'LINE' and b['layerId'] in (1, 2):
        geom = LineString([(b['startX']*MM, -b['startY']*MM), (b['endX']*MM, -b['endY']*MM)]).buffer(b['width']*MM/2, quad_segs=96)
        if b['netName'] == 'GND' and b['layerId'] == 1:
            top_lines.append((h['id'], geom))
        elif b['netName'] != 'GND' and b['layerId'] == 2:
            non_ground_bottom.append(('line-'+h['id'], geom))

assert all(plane.intersection(g).area > 1e-4 for _, g in bottom_contacts)
ground_graph = top_nodes + top_lines + [('via-'+i, g) for i, g in gnd_vias] + [('BOTTOM', plane)]
links = [set() for _ in ground_graph]
plane_idx = len(ground_graph)-1
for i, (name, g) in enumerate(ground_graph):
    for j in range(i):
        other, gg = ground_graph[j]
        if i == plane_idx and not other.startswith('via-'):
            continue
        if g.intersection(gg).area > 1e-6:
            links[i].add(j)
            links[j].add(i)
seen = {plane_idx}
todo = [plane_idx]
while todo:
    for n in links[todo.pop()]:
        if n not in seen:
            seen.add(n)
            todo.append(n)
assert all(i in seen for i in range(len(top_nodes))), 'Disconnected SMD ground pad'
clearances = [(name, plane.distance(geom)) for name, geom in non_ground_bottom]
assert min(v for _, v in clearances) > .295

with ZipFile(GERBER) as z:
    bottom_text = z.read('Gerber_BottomLayer.GBL').decode('utf-8')
assert '%FSLAX45Y45*%' in bottom_text and '%MOMM*%' in bottom_text
assert '%LPC' not in bottom_text, 'Unexpected clear polarity; needs full compositing parser'
gerber_regions = []
for block in re.findall(r'G36\*\s*(.*?)\s*G37\*', bottom_text, re.S):
    assert 'G02' not in block and 'G03' not in block
    pts = [(int(x)/1e5, -int(y)/1e5) for x, y in re.findall(r'G01X(-?\d+)Y(-?\d+)D0[12]\*', block)]
    gerber_regions.append(Polygon(pts))
gerber_plane = unary_union(gerber_regions)
assert len(gerber_regions) == len(regions)
assert plane.hausdorff_distance(gerber_plane) < .00002
assert gerber_plane.geom_type == 'Polygon'
assert all(gerber_plane.intersection(g).area > 1e-4 for _, g in bottom_contacts)

report = {
    'passed': True, 'scope': 'Independent saved-file and Gerber GND geometry, not physical validation',
    'pcb_sha256': digest(PCB), 'gerber_zip_sha256': digest(GERBER),
    'generator_sha256': digest(ROOT/'generate_ground_plane.py'),
    'native_ground_regions': len(regions), 'native_ground_components': 1,
    'native_ground_area_mm2': plane.area, 'ground_th_pad_count': len(bottom_contacts)-len(gnd_vias),
    'ground_via_count': len(gnd_vias), 'ground_smd_pad_count': len(top_nodes),
    'ground_top_line_count': len(top_lines), 'ground_anchors_attached': len(bottom_contacts),
    'all_smd_ground_connected_via_top_traces_to_plane': True,
    'snapshot_max_pad_position_delta_mm': max_snapshot_delta,
    'minimum_actual_bottom_other_net_clearance_mm': min(v for _, v in clearances),
    'bottom_clearance_items_mm': dict(clearances),
    'gerber_region_count': len(gerber_regions), 'gerber_ground_components': 1,
    'gerber_vs_native_hausdorff_mm': plane.hausdorff_distance(gerber_plane),
    'gerber_vs_native_symmetric_difference_mm2': plane.symmetric_difference(gerber_plane).area,
    'all_12_contacts_overlap_exported_regions': True, 'shapely_version': shapely.__version__,
    'not_verified': ['physical continuity', 'voltage or pulse waveforms', 'thermal and sustained current capability'],
}
(ROOT/'verification/independent-ground-check.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
