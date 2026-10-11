"""Read-only audit of released slider4 manufacturing geometry against its manifest.

Reuses only the independent Gerber/Excellon parsers and primitive geometry
functions, not the Touch25-specific audit() or the slider4 source generator.
Writes reports in this directory; manufacturing inputs are never modified.
"""
import hashlib
import importlib.util
import json
import math
import sys
import tempfile
import zipfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
BOARD = HERE.parent
PARSER = BOARD.parents[2] / 'tmp' / 'touch25_rules' / 'audit_gerber_independent.py'
spec = importlib.util.spec_from_file_location('independent_gerber_parser', PARSER)
g = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = g
spec.loader.exec_module(g)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def polygon_equal(a, b, tolerance=0.00002):
    if len(a) != len(b):
        return False
    for vertices in (b, list(reversed(b))):
        for start in range(len(vertices)):
            if all(math.dist(p, vertices[(start+i) % len(vertices)]) <= tolerance
                   for i, p in enumerate(a)):
                return True
    return False


def polygon_distance(a, b):
    if g.overlap(a, b):
        return 0.0
    return min(min(g.point_seg_dist(p, q, r) for p in a.points
                   for q, r in zip(b.points, b.points[1:] + b.points[:1])),
               min(g.point_seg_dist(p, q, r) for p in b.points
                   for q, r in zip(a.points, a.points[1:] + a.points[:1])))


def audit():
    archive = BOARD / 'Gerber_Touch25_Slider4_100x20_R1_Release.zip'
    manifest_file = BOARD / 'design_manifest.json'
    archive_bytes, manifest_bytes = archive.read_bytes(), manifest_file.read_bytes()
    manifest = json.loads(manifest_bytes.decode('utf-8-sig'))
    result = {
        'archive': str(archive), 'archive_sha256': sha256(archive_bytes),
        'manifest': str(manifest_file), 'manifest_sha256': sha256(manifest_bytes),
        'parser': str(PARSER), 'parser_sha256': sha256(PARSER.read_bytes()),
        'method': 'Actual ZIP Gerber/Excellon parsing; geometry matched to manifest; per-layer overlap graph joined only at plated drill centers.',
        'files': {}, 'checks': [],
        'limitations': [
            'Circles/arcs polygonised with radial error <=0.001 mm; contact tolerance 0.002 mm.',
            'Nominal drill geometry only; fabrication registration, drilling tolerance, and CAM clearance processing are not simulated.',
            'Exact equal-diameter circular NPTH copper disks are removed nominally by drilling; no general Boolean copper subtraction is assumed.',
            'Gerbers do not encode PCB thickness, material, sensor behavior, soldering instructions, or firmware performance.',
            'Silkscreen layers are parsed for syntax and inventoried, but lettering semantics are not OCR verified.',
            'The informational GDD drill drawing is hashed and inventoried only: its hollow IconRect/IconTriangle macros use Boolean clear primitives unsupported by the independent parser. Actual Excellon drill files are fully parsed.',
        ],
    }
    def check(name, passed, details):
        result['checks'].append({'name': name, 'pass': bool(passed), 'details': details})
    names = {
        'top_copper': 'Gerber_TopLayer.GTL',
        'bottom_copper': 'Gerber_BottomLayer.GBL',
        'top_mask': 'Gerber_TopSolderMaskLayer.GTS',
        'bottom_mask': 'Gerber_BottomSolderMaskLayer.GBS',
        'outline': 'Gerber_BoardOutlineLayer.GKO',
        'top_silk': 'Gerber_TopSilkscreenLayer.GTO',
        'bottom_silk': 'Gerber_BottomSilkscreenLayer.GBO',
    }
    with tempfile.TemporaryDirectory(prefix='slider4_gerber_audit_', dir=HERE) as temp:
        folder = Path(temp)
        with zipfile.ZipFile(archive) as z:
            check('zip_integrity', z.testzip() is None, {'bad_member': z.testzip()})
            for name in z.namelist():
                if z.getinfo(name).is_dir():
                    continue
                data = z.read(name)
                result['files'][name] = {'size': len(data), 'sha256': sha256(data)}
                if Path(name).name != name:
                    raise ValueError('Unexpected nested archive member: ' + name)
                (folder / name).write_bytes(data)
        layers = {name: g.Gerber(folder / filename) for name, filename in names.items()}
        for name, filename in names.items():
            layer = layers[name]
            result['files'][filename].update(
                category=name, shapes=len(layer.shapes),
                regions=sum(s.kind == 'region' for s in layer.shapes),
                flashes=sum(s.kind == 'flash' for s in layer.shapes),
                drawn_segments=len(layer.lines))
        check('all_manufacturing_and_silk_gerber_layers_parse', True, {'parsed_layers': list(layers)})
        result['files']['Gerber_DrillDrawingLayer.GDD'].update(category='informational_drill_drawing',
            parse_status='inventory_only: hollow symbol macros are unsupported; Excellon files audited instead')
        drill = []
        for name, plating in [('Drill_PTH_Through.DRL', 'PTH'), ('Drill_NPTH_Through.DRL', 'NPTH')]:
            holes = g.parse_drill(folder / name)
            for hole in holes:
                hole['file'] = name
                hole['plating'] = plating
            drill.extend(holes)
            result['files'][name].update(category=plating, hole_count=len(holes))
        outline = layers['outline']
        endpoints = [p for a, b in outline.lines for p in (a, b)]
        minx, miny = min(p[0] for p in endpoints), min(p[1] for p in endpoints)
        maxx, maxy = max(p[0] for p in endpoints), max(p[1] for p in endpoints)
        width, height = maxx-minx, maxy-miny
        check('100x20_board_outline', abs(width-manifest['board']['width_mm']) < 0.00001
              and abs(height-manifest['board']['height_mm']) < 0.00001,
              {'width_mm': width, 'height_mm': height, 'bounds_cartesian_mm': [minx, miny, maxx, maxy]})
        expected_edges = [((minx, maxy), (maxx, maxy)), ((maxx, maxy), (maxx, miny)),
                          ((maxx, miny), (minx, miny)), ((minx, miny), (minx, maxy))]
        check('closed_rectangle_no_extra_cutout', len(outline.lines) == 4 and all(
            sum((math.dist(a,c) < 0.00001 and math.dist(b,d) < 0.00001) or
                (math.dist(a,d) < 0.00001 and math.dist(b,c) < 0.00001)
                for a,b in outline.lines) == 1 for c,d in expected_edges),
            {'drawn_segments': outline.lines, 'perimeter_mm': sum(math.dist(a,b) for a,b in outline.lines)})
        def native(p):
            return (minx+p[0], maxy-p[1])
        electrodes = manifest['electrodes']
        npth = [h for h in drill if h['plating'] == 'NPTH']
        pth = [h for h in drill if h['plating'] == 'PTH']
        def hole_match(holes, centers, diameter):
            return len(holes) == len(centers) and all(sum(
                math.dist(h['center'], p) < 0.00001 and abs(h['diameter']-diameter) < 0.000001
                for h in holes) == 1 for p in centers)
        check('2_npth_3p2mm_mounting_holes', hole_match(npth,
            [native(p) for p in manifest['mounting_holes']['centers_mm']], manifest['mounting_holes']['diameter_mm']),
            {'actual_holes': npth})
        transfer_holes = [h for h in pth if abs(h['diameter']-manifest['transfer_pads']['hole_mm']) < 0.000001]
        connector_holes = [h for h in pth if abs(h['diameter']-manifest['connector']['hole_mm']) < 0.000001]
        check('4_pth_0p3mm_transfer_holes', hole_match(transfer_holes,
            [native(e['transfer_mm']) for e in electrodes], manifest['transfer_pads']['hole_mm']),
            {'actual_holes': transfer_holes})
        check('4_pth_1p0mm_J4_holes', hole_match(connector_holes,
            [native(e['connector_pin_mm']) for e in electrodes], manifest['connector']['hole_mm']),
            {'actual_holes': connector_holes})
        check('no_extra_drill_holes', len(drill) == 10 and len(pth) == 8 and len(npth) == 2,
              {'total': len(drill), 'PTH': len(pth), 'NPTH': len(npth)})
        check('all_drills_inside_board', all(minx < h['center'][0]-h['diameter']/2 and
            h['center'][0]+h['diameter']/2 < maxx and miny < h['center'][1]-h['diameter']/2 and
            h['center'][1]+h['diameter']/2 < maxy for h in drill), {})
        expected_regions = [(e['net'], g.Shape([native(p) for p in polygon], 'manifest', 'region'))
                            for e in electrodes for polygon in e['polygons_mm']]
        actual_regions = [s for s in layers['top_copper'].shapes if s.kind == 'region']
        check('all_30_top_electrode_polygons_match', len(actual_regions) == len(expected_regions) == 30 and
              all(sum(polygon_equal(expected.points, actual.points) for actual in actual_regions) == 1
                  for _,expected in expected_regions),
              {'expected_count': len(expected_regions), 'actual_count': len(actual_regions),
               'polygon_counts_by_net': {e['net']: len(e['polygons_mm']) for e in electrodes},
               'coordinate_tolerance_mm': 0.00002})
        check('no_bottom_electrode_regions_or_ground_plane', not any(s.kind == 'region' for s in layers['bottom_copper'].shapes),
              {'bottom_region_count': sum(s.kind == 'region' for s in layers['bottom_copper'].shapes)})
        route_details = {}
        for layer_name, route_key, expected_count in [('top_copper','top_trace_mm',4), ('bottom_copper','bottom_route_mm',10)]:
            expected_lines = [(e['net'], native(a), native(b)) for e in electrodes
                              for a,b in zip(e[route_key],e[route_key][1:])]
            actual_lines = layers[layer_name].lines
            ok = len(actual_lines) == len(expected_lines) == expected_count and all(sum(
                (math.dist(a,c) < 0.00001 and math.dist(b,d) < 0.00001) or
                (math.dist(a,d) < 0.00001 and math.dist(b,c) < 0.00001)
                for a,b in actual_lines) == 1 for _,c,d in expected_lines)
            strokes = [s for s in layers[layer_name].shapes if s.kind == 'stroke']
            widths = [layers[layer_name].apertures[s.aperture][1][0] for s in strokes]
            check(layer_name+'_routes_match', ok, {'segments': actual_lines, 'expected_count': expected_count})
            check(layer_name+'_trace_width_0p2mm', len(widths) == expected_count and
                  all(abs(w-manifest['trace_width_mm']) < 0.000001 for w in widths), {'widths_mm': widths})
            route_details[layer_name] = len(actual_lines)
        result['route_segment_counts'] = route_details
        removed = []
        copper = {}
        for layer_name in ['top_copper', 'bottom_copper']:
            layer = layers[layer_name]
            kept = []
            for s in layer.shapes:
                is_removed = False
                if s.kind == 'flash':
                    kind, values = layer.apertures[s.aperture]
                    if kind == 'C' and len(values) == 1:
                        for h in npth:
                            if abs(values[0]-h['diameter']) < 1e-9 and all(
                                abs(math.dist(p,h['center'])-h['diameter']/2) < 1e-8 for p in s.points):
                                removed.append({'layer': layer_name, 'center': h['center'],
                                                'diameter_mm': h['diameter'], 'residual_annulus_mm': 0.0})
                                is_removed = True
                if not is_removed:
                    kept.append(s)
            copper[layer_name] = kept
        result['npth_nominal_copper_removal'] = removed
        check('4_npth_coincident_disks_removed_nominally', len(removed) == 4 and all(sum(
            r['layer'] == layer and math.dist(r['center'],h['center']) < 1e-9 for r in removed) == 1
            for layer in copper for h in npth), {'disks': removed})
        tops, bottoms = copper['top_copper'], copper['bottom_copper']
        shapes, split = tops+bottoms, len(tops)
        parent = list(range(len(shapes)))
        def find(i):
            while parent[i] != i:
                parent[i] = parent[parent[i]]
                i = parent[i]
            return i
        def union(i,j):
            parent[find(j)] = find(i)
        for begin,end in [(0,split),(split,len(shapes))]:
            for i in range(begin,end):
                for j in range(i+1,end):
                    if g.overlap(shapes[i],shapes[j]):
                        union(i,j)
        for h in pth:
            hits = [i for i,s in enumerate(shapes) if g.contains(s.points,h['center'])]
            top_hits, bottom_hits = [i for i in hits if i < split], [i for i in hits if i >= split]
            check('PTH_both_layer_copper_'+str(h['center']), bool(top_hits) and bool(bottom_hits),
                  {'top_shape_count': len(top_hits), 'bottom_shape_count': len(bottom_hits)})
            for i in hits[1:]:
                union(hits[0],i)
        for pad_type, holes, outer in [('transfer',transfer_holes,manifest['transfer_pads']['outer_mm']),
                                        ('connector',connector_holes,manifest['connector']['outer_mm'])]:
            for layer_name, layer_shapes in copper.items():
                counts = []
                for hole in holes:
                    count = 0
                    for s in layer_shapes:
                        if s.kind != 'flash' or not g.contains(s.points,hole['center']):
                            continue
                        kind, values = layers[layer_name].apertures[s.aperture]
                        count += ((kind == 'C' and abs(values[0]-outer) < 1e-9) or
                                  (kind == 'R' and all(abs(v-outer) < 1e-9 for v in values[:2])))
                    counts.append(count)
                check(pad_type+'_annulus_'+layer_name, len(counts) == 4 and all(n == 1 for n in counts),
                      {'matching_pad_counts': counts, 'outer_mm': outer,
                       'nominal_minimum_ring_mm': (outer-holes[0]['diameter'])/2 if holes else None})
        net_roots = {}
        pin_mapping = []
        for e in electrodes:
            regions = [i for i,s in enumerate(tops) if s.kind == 'region' and any(
                       polygon_equal(s.points, exp.points) for net, exp in expected_regions if net == e['net'])]
            via_hits = [i for i,s in enumerate(shapes) if g.contains(s.points,native(e['transfer_mm']))]
            pin_hits = [i for i,s in enumerate(shapes) if g.contains(s.points,native(e['connector_pin_mm']))]
            roots = {find(i) for i in regions+via_hits+pin_hits}
            connected = len(regions) == len(e['polygons_mm']) and bool(via_hits) and bool(pin_hits) and len(roots) == 1
            check(e['net']+'_all_electrode_polygons_to_J4_pin_'+str(e['pin']), connected,
                  {'electrode_region_count': len(regions), 'roots': sorted(roots),
                   'transfer_mm_preview': e['transfer_mm'], 'J4_pin': e['pin'],
                   'J4_pin_mm_preview': e['connector_pin_mm']})
            if connected:
                net_roots[e['net']] = next(iter(roots))
            pin_mapping.append({'pin': e['pin'], 'net': e['net'], 'MPR121_board': e['mpr121_board'],
                                'ELE': e['ele'], 'preview_center_mm': e['connector_pin_mm']})
        result['J4_pin_mapping'] = pin_mapping
        groups = {}
        for i in range(len(shapes)):
            groups.setdefault(find(i),[]).append(i)
        check('4_independent_nets_no_shorts', len(net_roots) == 4 and len(set(net_roots.values())) == 4,
              {'net_components': net_roots})
        extras = {str(root): members for root,members in groups.items() if root not in net_roots.values()}
        check('no_extra_copper_components', not extras and len(groups) == 4,
              {'total_components': len(groups), 'unassigned_components': extras})
        check('all_remaining_copper_inside_board', all(minx < s.box[0] and s.box[2] < maxx
              and miny < s.box[1] and s.box[3] < maxy for s in shapes), {})
        for layer_name, layer_shapes in copper.items():
            shapes_with_roots = [(s,find(i if layer_name == 'top_copper' else split+i))
                                for i,s in enumerate(layer_shapes)]
            smallest, pair = float('inf'), None
            for i,(a,ra) in enumerate(shapes_with_roots):
                for j,(b,rb) in enumerate(shapes_with_roots[i+1:],i+1):
                    if ra == rb:
                        continue
                    dx = max(a.box[0]-b.box[2],b.box[0]-a.box[2],0)
                    dy = max(a.box[1]-b.box[3],b.box[1]-a.box[3],0)
                    if math.hypot(dx,dy) >= smallest:
                        continue
                    distance = polygon_distance(a,b)
                    if distance < smallest:
                        smallest, pair = distance, [i,j]
            check(layer_name+'_net_clearance_at_least_0p25mm',
                  smallest >= manifest['electrode_band']['minimum_clearance_requirement_mm'],
                  {'minimum_mm_polygonised': smallest, 'closest_shape_indices': pair})
        for layer_name in copper:
            pads = []
            for e in electrodes:
                q = native(e['connector_pin_mm'])
                candidates = [s for s in copper[layer_name] if s.kind == 'flash' and g.contains(s.points,q)]
                kinds = [layers[layer_name].apertures[s.aperture][0] for s in candidates]
                pads.append({'pin': e['pin'], 'kinds': kinds})
            check('J4_pin1_square_others_round_'+layer_name,
                  all(p['kinds'] == (['R'] if p['pin'] == 1 else ['C']) for p in pads), {'pad_shapes': pads})
        pins = sorted(electrodes,key=lambda e:e['pin'])
        check('J4_2p54mm_pitch_pin1_left_front_view',
              all(abs(b['connector_pin_mm'][0]-a['connector_pin_mm'][0]-manifest['connector']['pitch_mm']) < 1e-9
                  and abs(b['connector_pin_mm'][1]-a['connector_pin_mm'][1]) < 1e-9 for a,b in zip(pins,pins[1:])),
              {'front_view_left_to_right': [e['net'] for e in pins]})
        for layer_name in ['top_mask','bottom_mask']:
            layer = layers[layer_name]
            for e in electrodes:
                regions = [expected for net,expected in expected_regions if net == e['net']]
                hits = [(i,j) for i,s in enumerate(layer.shapes) for j,r in enumerate(regions) if g.overlap(s,r)]
                check(e['net']+'_no_'+layer_name+'_electrode_opening', not hits, {'overlaps': hits})
                pad = g.Shape(g.circle(*native(e['transfer_mm']),manifest['transfer_pads']['outer_mm']/2),'expected','circle')
                hits = [i for i,s in enumerate(layer.shapes) if g.overlap(s,pad)]
                check(e['net']+'_tented_transfer_'+layer_name, not hits, {'overlaps': hits})
            expected_mask_centers = [native(p) for p in manifest['mounting_holes']['centers_mm']] + [native(e['connector_pin_mm']) for e in electrodes]
            check(layer_name+'_only_2_mounting_and_4_connector_openings', len(layer.shapes) == 6 and all(
                sum(g.contains(s.points,p) for s in layer.shapes) == 1 for p in expected_mask_centers),
                {'nonzero_opening_count': len(layer.shapes)})
            for e in electrodes:
                trace = next(s for s in tops if s.kind == 'stroke' and g.contains(s.points,native(e['top_trace_mm'][0])))
                check(e['net']+'_no_'+layer_name+'_top_trace_opening', not any(g.overlap(trace,s) for s in layer.shapes), {})
        paste_names = [n for n in result['files'] if n.lower().endswith(('.gtp','.gbp'))]
        check('no_paste_opening_files', not paste_names, {'files': paste_names})
        probe = json.loads((folder/'FlyingProbeTesting.json').read_text(encoding='utf-8-sig'))
        fields = probe['pins']['fields']
        rows = [dict(zip(fields,row)) for row in probe['pins']['rows']]
        unit = 0.0254 if probe['lengthUnit'] == 'mil' else None
        if unit is None:
            raise ValueError('Unsupported probe units')
        probe_map = []
        for e in electrodes:
            center = native(e['connector_pin_mm'])
            hits = [r for r in rows if math.dist((r['PIN_X']*unit,r['PIN_Y']*unit),center) < 0.00001]
            check('probe_J4_pin_'+str(e['pin'])+'_net_'+e['net'], len(hits) == 2 and all(
                r['NET_NAME'] == e['net'] and r['PIN_NAME'].endswith('_'+str(e['pin'])) for r in hits),
                {'records': hits})
            probe_map.extend(hits)
        check('probe_only_S0_S1_S2_S3_nets', {r['NET_NAME'] for r in rows} == {e['net'] for e in electrodes},
              {'record_count': len(rows), 'nets': sorted({r['NET_NAME'] for r in rows}),
               'note': 'Native export duplicates each of 8 physical plated pads in probe records; geometry and drill files contain one physical pad/hole per location.'})
    check('manufacturing_inputs_unchanged', archive.read_bytes() == archive_bytes and manifest_file.read_bytes() == manifest_bytes,
          {'archive_sha256': sha256(archive.read_bytes()), 'manifest_sha256': sha256(manifest_file.read_bytes())})
    result['summary'] = {'pass': all(c['pass'] for c in result['checks']),
                         'check_count': len(result['checks']),
                         'failed_checks': [c['name'] for c in result['checks'] if not c['pass']]}
    return result


if __name__ == '__main__':
    try:
        result = audit()
    except Exception as exc:
        result = {'summary': {'pass': False, 'error': type(exc).__name__+': '+str(exc)}}
    output = HERE/'gerber_release_independent_audit.json'
    output.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result['summary'],ensure_ascii=True,indent=2))
    sys.exit(0 if result['summary']['pass'] else 1)
