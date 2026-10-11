"""Passive 4-electrode slider: native LCEDA Pro source and shared geometry.

Coordinates in the manifest and SVG are mm, x right / y down. Native y is negated.
The overlapping-in-space, electrically separated wedges require calibrated analog
MPR121 data; this generator makes no claim about measured touch performance.
"""
from pathlib import Path
import json, csv, html, hashlib
from native_writer import NativePCB

ROOT = Path(__file__).parent
NAME = 'Touch25_Slider4_100x20_R1'
W, H = 100.0, 20.0
ANCHORS = [8.0, 36.0, 64.0, 92.0]
GAP, SPINE_W = .30, .50
Y0, Y1 = 3.0, 14.0
SPINE_EXIT_Y = 14.5  # Move each stub beyond adjacent wedges; fill-to-line >=0.508mm.
BANDS = 4
BAND_H = (Y1 - Y0 - (BANDS - 1) * GAP) / BANDS
TRACE_W = .20
PIN_X = [50 + (i - 1.5) * 2.54 for i in range(4)]
HOLES = [[3.0, 8.5], [97.0, 8.5]]
COLORS = ['#d98656', '#73b86e', '#69b1dd', '#b188d7']


def rect(x0, y0, x1, y1):
    return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]


def npt(p):
    return p[0], -p[1]


def text(p, x, y, s, size=1.0, layer=3, mirror=False):
    return p.text(x, -y, s, height=size, width=.15, layer=layer, mirror=mirror)


def electrodes():
    es = [dict(index=i, net=f'S{i}', mpr121_board=1, ele=8+i,
               anchor_mm=x, polygons_mm=[rect(x-SPINE_W/2, Y0, x+SPINE_W/2, SPINE_EXIT_Y)],
               top_trace_mm=[[x, SPINE_EXIT_Y], [x, 15.1]], transfer_mm=[x, 15.1],
               bottom_route_mm=([[x, 15.1], [x, 16.2], [PIN_X[i], 16.2], [PIN_X[i], 17.5]]
                                if i in (0, 3) else [[x, 15.1], [PIN_X[i], 15.1], [PIN_X[i], 17.5]]),
               pin=i+1, connector_pin_mm=[PIN_X[i], 17.5])
          for i, x in enumerate(ANCHORS)]
    # End caps increase coverage beyond the nominal endpoint marks. Keep away
    # from fixing holes. Actual endpoints still require measured calibration.
    es[0]['polygons_mm'].append(rect(6, Y0, 8.25, Y1))
    es[3]['polygons_mm'].append(rect(91.75, Y0, 94, Y1))
    for i in range(3):
        a, b = ANCHORS[i] + SPINE_W/2, ANCHORS[i+1] - SPINE_W/2
        def ha(x):
            return .30 + (BAND_H - GAP - .60) * (1 - (x-a)/(b-a))
        for k in range(BANDS):
            y = Y0 + k * (BAND_H + GAP)
            # Left and right wedges share a gradient, with a vertical 0.30mm
            # gap. Stop each tip 0.30mm before the opposite electrode spine.
            left = [[a, y], [b-GAP, y], [b-GAP, y+ha(b-GAP)], [a, y+ha(a)]]
            right = [[a+GAP, y+ha(a+GAP)+GAP], [b, y+ha(b)+GAP],
                     [b, y+BAND_H], [a+GAP, y+BAND_H]]
            if k % 2:
                left = [[x, 2*y+BAND_H-yy] for x, yy in left]
                right = [[x, 2*y+BAND_H-yy] for x, yy in right]
            es[i]['polygons_mm'].append(left)
            es[i+1]['polygons_mm'].append(right)
    return es


def native(es):
    p = NativePCB(NAME)
    p.outline([npt(x) for x in rect(0, 0, W, H)])
    for x, y in HOLES:
        p.hole(x, -y, 3.2)
    for e in es:
        for poly in e['polygons_mm']:
            p.fill([npt(v) for v in poly], e['net'], layer=1)
        p.track(*[npt(v) for v in e['top_trace_mm']], e['net'], layer=1, width=TRACE_W)
        x, y = e['transfer_mm']
        p.pad(x, -y, '', e['net'], diameter=.8, hole=.3)
        p.rows[-1][1]['topSolderExpansion'] = -.4*1000/25.4
        p.rows[-1][1]['bottomSolderExpansion'] = -.4*1000/25.4
        for a, b in zip(e['bottom_route_mm'], e['bottom_route_mm'][1:]):
            p.track(npt(a), npt(b), e['net'], layer=2, width=TRACE_W)
        x, y = e['connector_pin_mm']
        p.pad(x, -y, e['pin'], e['net'], diameter=1.8, hole=1.0,
              shape='RECT' if e['pin'] == 1 else 'ELLIPSE')
        text(p, x-.33, 19.5, str(e['pin']))
        text(p, x-.65, 19.5, str(e['ele']), layer=4, mirror=True)
    text(p, 8, 1.7, 'Touch25 / SLIDER4 R1', size=1.2)
    text(p, 66, 1.7, 'BEND -200 ... +200', size=1.0)
    text(p, 41, 18.0, 'J4')
    text(p, 58, 18.0, 'ELE8-11 / NO VCC')
    text(p, 8, 6.0, 'MPR1 ELE8-11 / NO VCC', size=1.2, layer=4, mirror=True)
    text(p, 8, 10.0, 'SHORT WIRES <=50mm', size=1.0, layer=4, mirror=True)
    text(p, 8, 13.0, 'PIN1 SQUARE / TOP VIEW', size=1.0, layer=4, mirror=True)
    # Edge ticks are outside the copper sensing band. The centre mark is the
    # nominal zero-bend position, not an unmeasured physical calibration point.
    for x in [8, 50, 92]:
        p.poly([npt([x, 2.0]), npt([x, 2.7])], layer=3, width=.15, closed=False)
    return p


def points(poly):
    return ' '.join(f'{x:.6f},{y:.6f}' for x, y in poly)


def svg_text(x, y, s, size=1.2, color='#fafafa', anchor='start'):
    return f'<text x="{x}" y="{y}" fill="{color}" font-size="{size}" text-anchor="{anchor}" font-family="Arial,sans-serif">{html.escape(s)}</text>'


def svg(es):
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="1500" height="660" viewBox="-4 -5 108 47.52">',
           '<title>Touch25 Slider4 R1 engineering preview and wiring</title>',
           '<desc>Geometry preview, not a Gerber render or measured capacitive response.</desc>',
           '<rect x="-4" y="-5" width="108" height="47.52" fill="#eef2f6"/>',
           svg_text(0, -1.8, '100 x 20 mm / 4 electrodes / MPR121 spare channels', 1.8, '#253448'),
           '<rect width="100" height="20" fill="#171d26" stroke="#596b81" stroke-width=".15"/>']
    for e, color in zip(es, COLORS):
        for poly in e['polygons_mm']:
            out.append(f'<polygon points="{points(poly)}" fill="{color}" stroke="none" opacity=".85"/>')
        out.append(f'<polyline points="{points(e["top_trace_mm"])}" fill="none" stroke="{color}" stroke-width=".2"/>')
        # Blue translucent bottom lines show routing through the board.
        out.append(f'<polyline points="{points(e["bottom_route_mm"])}" fill="none" stroke="{color}" stroke-width=".2" opacity=".7"/>')
        x, y = e['transfer_mm']
        out.append(f'<circle cx="{x}" cy="{y}" r=".4" fill="{color}"/>')
        x, y = e['connector_pin_mm']
        out.append(f'<rect x="{x-.9}" y="{y-.9}" width="1.8" height="1.8" fill="#c7a262"/>' if e['pin']==1 else f'<circle cx="{x}" cy="{y}" r=".9" fill="#c7a262"/>')
        out.append(f'<circle cx="{x}" cy="{y}" r=".5" fill="#171d26"/>')
        out.append(svg_text(x, 19.5, str(e['pin']), 1, anchor='middle'))
    for x, y in HOLES:
        out.append(f'<circle cx="{x}" cy="{y}" r="1.6" fill="#eef2f6"/>')
    out += [svg_text(8, 1.7, 'Touch25 / SLIDER4 R1', 1.2),
            svg_text(66, 1.7, 'BEND -200 ... +200', 1),
            svg_text(41, 18, 'J4', 1), svg_text(58, 18, 'ELE8-11 / NO VCC', 1),
            svg_text(0, 23.2, 'Coloured copper stays covered by solder mask; single-finger prototype.', 1.3, '#253448'),
            svg_text(0, 26, 'Nominal travel: 84 mm. Calibrate endpoints after assembly and cover film.', 1.3, '#253448')]
    for i, color in enumerate(COLORS):
        out += [f'<rect x="{i*25}" y="29" width="23" height="7.5" rx=".6" fill="{color}" opacity=".25"/>',
                svg_text(i*25+1, 31.5, f'J4 pin {i+1} / S{i}', 1.5, '#253448'),
                svg_text(i*25+1, 34.5, f'MPR121 #1 ELE{8+i}', 1.35, '#253448')]
    out += [svg_text(0, 40, 'MPR121 -> I2C -> FPGA position / bend -> existing I2S / DAC / amplifier', 1.35, '#253448'), '</svg>']
    (ROOT/'design_overview.svg').write_text('\n'.join(out), encoding='utf-8')


def main():
    es = electrodes()
    p = native(es)
    archive = p.save(ROOT/(NAME+'.epro2'))
    m = dict(name=NAME, revision='R1', status='Prototype: native import/DRC/export pending',
             board=dict(width_mm=W, height_mm=H, layers=2, thickness_mm=1.6,
                        no_ground_plane=True, no_vcc_gnd_pins=True,
                        no_onboard_controller=True, no_electrode_mask_openings=True),
             coordinate_convention='mm, x right / y down; native y=-preview y',
             anchors_mm=ANCHORS, nominal_travel_mm=84.0,
             electrode_band=dict(y0_mm=Y0, y1_mm=Y1, bands=BANDS,
                                 band_height_mm=BAND_H, spine_width_mm=SPINE_W, spine_exit_y_mm=SPINE_EXIT_Y,
                                 vertical_gap_mm=GAP, minimum_clearance_requirement_mm=.25),
             trace_width_mm=TRACE_W, transfer_pads=dict(outer_mm=.8, hole_mm=.3, mask_expansion_mm=-.4),
             connector=dict(name='J4', pitch_mm=2.54, hole_mm=1.0, outer_mm=1.8,
                            pin1='square, left when viewing component/front side',
                            mounting='solder 1x4 male header on back'),
             mounting_holes=dict(diameter_mm=3.2, plated=False, centers_mm=HOLES),
             electrodes=es, original_touch25_files_modified=False,
             firmware_status='MPR121 acquisition and board constraints not implemented; expression interface exists',
             limitations=['Single finger only; two fingers produce a combined position.',
                          'True pressure/velocity is not measured.',
                          'Physical position, endpoint linearity and touch-to-audio latency require hardware tests.',
                          'This source package is independent of the original Touch25 R1 Gerber.'],
             sources=['https://community.nxp.com/pwmxy87654/attachments/pwmxy87654/sensors/2732/1/MPR121%20design%20guidelines.pdf',
                      'https://www.nxp.com/docs/en/application-note/AN4600.pdf',
                      'https://www.nxp.com/docs/en/data-sheet/MPR121.pdf'],
             native_exchange_sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
    (ROOT/'design_manifest.json').write_text(json.dumps(m, ensure_ascii=False, indent=2), encoding='utf-8')
    with (ROOT/'wiring.csv').open('w', encoding='utf-8-sig', newline='') as f:
        wr = csv.writer(f)
        wr.writerow(['connector', 'pin', 'net', 'mpr121_module', 'mpr121_electrode'])
        for e in es:
            wr.writerow(['J4', e['pin'], e['net'], 1, f'ELE{e["ele"]}'])
    svg(es)
    print(json.dumps(dict(output=str(archive), dimensions_mm=[W,H], channels=4,
                          status=m['status']), ensure_ascii=False))


if __name__ == '__main__':
    main()
