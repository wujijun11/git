"""Generate one passive 25-key electrode panel from a single geometry source.

No MCU, capacitive controller, audio circuit, power rail, or ground plane is
placed on this board. MPR121 breakout modules remain external.
Native import, native DRC and native Gerber review are required before ordering.
"""
from pathlib import Path
import json,csv,math,html,hashlib
from native_writer import NativePCB

ROOT=Path(__file__).parent
NAME='Touch25_C4_C6_18mm_R1'
# Preview/spec coordinates use x right and y down. Native PCB coordinates use
# Cartesian y up; this is the sole transform applied to all geometry and labels.
NATIVE_Y_SIGN=-1
BOARD_W,BOARD_H=290.0,105.0
WHITE_PITCH=18.0
TRACE_W=.18
HOLES=[(5,5),(145,5),(285,5),(5,100),(170,100),(285,100)]
NOTES=['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']
WHITES={0,2,4,5,7,9,11}
J_CONFIG=[dict(name='J1',start=0,count=8,x=55.0,y=95.0),dict(name='J2',start=8,count=8,x=136.0,y=95.0),dict(name='J3',start=16,count=9,x=226.0,y=95.0)]

def npt(pt):return (pt[0],NATIVE_Y_SIGN*pt[1])
def npoly(points):return [npt(p) for p in points]
def rounded_rect(cx,cy,w,h,r=1.5,steps=8):
    """Closed polygonal representation of four exact-radius circular corners."""
    x0,x1,y0,y1=cx-w/2,cx+w/2,cy-h/2,cy+h/2
    pts=[]
    for ox,oy,a0 in [(x1-r,y0+r,-90),(x1-r,y1-r,0),(x0+r,y1-r,90),(x0+r,y0+r,180)]:
        for j in range(steps+1):
            a=math.radians(a0+j*90/steps)
            pts.append((round(ox+r*math.cos(a),6),round(oy+r*math.sin(a),6)))
    return pts
def rect(x0,y0,x1,y1):return [(x0,y0),(x1,y0),(x1,y1),(x0,y1)]
def poly_svg(points):return ' '.join(f'{x:.4f},{y:.4f}' for x,y in points)
def short_text_x(x,text,h):return x-len(text)*h*.32
def native_text(p,x,y,text,h=1.2,layer=3,center=False,mirror=False):
    h=max(1.0,h)
    if center:x=short_text_x(x,text,h)
    return p.text(x,NATIVE_Y_SIGN*y,text,layer=layer,height=h,width=max(.15,h*.115),mirror=mirror)

def keys():
    out=[];wi=0
    for i,midi in enumerate(range(60,85)):
        white=midi%12 in WHITES
        x=19+18*wi if white else 10+18*wi
        if white:wi+=1
        name=NOTES[midi%12]+str(midi//12-1)
        j=next(v for v in J_CONFIG if v['start']<=i<v['start']+v['count'])
        channel=i-j['start'];pin=channel+1
        px=j['x']+(pin-(j['count']+1)/2)*2.54
        cy,w,h=(66,16,28) if white else (35.5,11,25)
        ty=82 if white else 50
        out.append(dict(index=i,net=f'E{i:02}',midi=midi,note=name,color='white' if white else 'black',center_mm=[x,cy],electrode_size_mm=[w,h],corner_radius_mm=1.5,electrode_polygon_mm=rounded_rect(x,cy,w,h),transfer_mm=[x,ty],top_trace_mm=[[x,cy+h/2],[x,ty]],bottom_route_mm=[[x,ty],[x,84],[round(px,4),92.5],[round(px,4),95]],connector=j['name'],pin=pin,connector_pin_mm=[round(px,4),95],mpr121_board=J_CONFIG.index(j)+1,ele=channel))
    assert len(out)==25 and sum(k['color']=='white' for k in out)==15
    return out

def white_outline(k,black_x):
    x=k['center_mm'][0];left,right=x-9,x+9
    lnot=any(abs(b-left)<.01 for b in black_x)
    rnot=any(abs(b-right)<.01 for b in black_x)
    lu,ru=left+(6 if lnot else 0),right-(6 if rnot else 0)
    points=[(lu,18),(ru,18),(ru,50),(right,50),(right,82),(left,82),(left,50),(lu,50)]
    # Remove duplicate consecutive vertices, retaining a closed outline.
    clean=[]
    for p in points:
        if not clean or p!=clean[-1]:clean.append(p)
    return clean

def native_design(ks):
    p=NativePCB(NAME)
    p.outline(npoly(rect(0,0,BOARD_W,BOARD_H)))
    black_x=[k['center_mm'][0] for k in ks if k['color']=='black']
    for x,y in HOLES:p.hole(x,NATIVE_Y_SIGN*y,3.2)
    for k in ks:
        p.fill(npoly(k['electrode_polygon_mm']),k['net'],layer=1)
        tx,ty=k['transfer_mm']
        p.track(npt(k['top_trace_mm'][0]),npt(k['top_trace_mm'][1]),k['net'],layer=1,width=TRACE_W)
        tid=p.pad(tx,NATIVE_Y_SIGN*ty,'',k['net'],diameter=.8,hole=.3)
        # The zero-size solder aperture is intended to tent this transfer point.
        # Native DRC/Gerber export must confirm mask coverage before ordering.
        transfer=p.rows[-1][1]
        transfer['topSolderExpansion']=-.4*1000/25.4
        transfer['bottomSolderExpansion']=-.4*1000/25.4
        for a,b in zip(k['bottom_route_mm'],k['bottom_route_mm'][1:]):p.track(npt(a),npt(b),k['net'],layer=2,width=TRACE_W)
        px,py=k['connector_pin_mm']
        p.pad(px,NATIVE_Y_SIGN*py,k['pin'],k['net'],diameter=1.8,hole=1.0,shape='RECT' if k['pin']==1 else 'ELLIPSE')
        if k['color']=='white':
            p.poly(npoly(white_outline(k,black_x)),layer=3,width=.18)
            p.poly(npoly(k['electrode_polygon_mm']),layer=3,width=.15)
            native_text(p,tx,63,k['note'],h=2.1,center=True)
            native_text(p,tx,69,k['net'],h=1.3,center=True)
        else:
            p.poly(npoly(k['electrode_polygon_mm']),layer=3,width=.15)
            native_text(p,tx,34,k['note'],h=1.45,center=True)
            native_text(p,tx,40,k['net'],h=1.1,center=True)
    native_text(p,10,10,'Touch25 FPGA Synth / C4-C6',h=2.0)
    native_text(p,204,10,'R1 18mm / PASSIVE',h=1.45)
    native_text(p,10,89,'25 KEYS / NO MCU / MPR121 EXTERNAL',h=1.1)
    for j in J_CONFIG:
        half=(j['count']-1)*2.54/2
        box=rect(j['x']-half-1.5,92.5,j['x']+half+1.5,97.5)
        p.poly(npoly(box),layer=3,width=.18)
        p.poly(npoly(box),layer=4,width=.18)
        # Native bottom silk mirrored so it reads normally when viewing the back.
        native_text(p,j['x'],91,f"{j['name']} E{j['start']:02}-E{j['start']+j['count']-1:02}",h=1.15,center=True)
        native_text(p,j['x'],90.3,f"{j['name']} -> MPR{J_CONFIG.index(j)+1} ELE0-{j['count']-1}",h=1.2,layer=4,center=True,mirror=True)
        for k in ks:
            if k['connector']!=j['name']:continue
            px,py=k['connector_pin_mm']
            native_text(p,px,100.3,str(k['pin']),h=1.0,center=True)
            native_text(p,px,99.1,str(k['ele']),h=1.0,layer=4,center=True,mirror=True)
        native_text(p,j['x'],102.2,'PIN1 LEFT (TOP VIEW)',h=1.0,center=True)
    native_text(p,10,15,'PASSIVE ELECTRODES: NO VCC / NO GND',h=1.2,layer=4,mirror=True)
    return p

def svg_doc(title,body,caption):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1450" height="585" viewBox="-3 -3 296 117">
<title>{html.escape(title)}</title><desc>Engineering preview generated from design_manifest.json. Native DRC and Gerber validation are pending.</desc>
<rect x="-3" y="-3" width="296" height="117" fill="#eef0f2"/>
<rect x="0" y="0" width="290" height="105" rx="0" fill="#191c22" stroke="#5a6370" stroke-width=".25"/>
{body}
<text x="2" y="111" font-family="sans-serif" font-size="2.1" fill="#333">{html.escape(caption)}</text></svg>'''
def svg_text(x,y,text,size=1.2,color='#f5f5f5',anchor='middle'):
    return f'<text x="{x:.4f}" y="{y:.4f}" text-anchor="{anchor}" font-family="Arial,sans-serif" font-size="{size}" fill="{color}">{html.escape(text)}</text>'
def render_previews(ks):
    bx=[k['center_mm'][0] for k in ks if k['color']=='black'];top=[];bottom=[]
    for x,y in HOLES:
        hole=f'<circle cx="{x}" cy="{y}" r="1.6" fill="#eef0f2" stroke="#808791" stroke-width=".18"/>'
        top.append(hole);bottom.append(hole)
    top.append(svg_text(10,10,'Touch25 FPGA Synth / C4-C6',2.6,anchor='start'))
    top.append(svg_text(205,10,'R1 18mm / PASSIVE',1.8,anchor='start'))
    for k in ks:
        x,y=k['center_mm'];poly=poly_svg(k['electrode_polygon_mm'])
        if k['color']=='white':top.append(f'<polygon points="{poly_svg(white_outline(k,bx))}" fill="none" stroke="#fafafa" stroke-width=".2"/>')
        top.append(f'<polygon points="{poly}" fill="#{"c3bd98" if k["color"]=="white" else "7d9a89"}" fill-opacity=".30" stroke="#f2f2f2" stroke-width=".15"/>')
        top.extend([svg_text(x,63 if k['color']=='white' else 34,k['note'],2.1 if k['color']=='white' else 1.45),svg_text(x,69 if k['color']=='white' else 40,k['net'],1.3 if k['color']=='white' else 1.1)])
        top.append(f'<polyline points="{poly_svg(k["top_trace_mm"])}" fill="none" stroke="#c89061" stroke-width=".18"/>')
        tx,ty=k['transfer_mm']
        top.append(f'<circle cx="{tx}" cy="{ty}" r=".4" fill="#b09571" fill-opacity=".5"/>')
        bottom.append(f'<polyline points="{poly_svg(k["bottom_route_mm"])}" fill="none" stroke="#4f9aff" stroke-width=".18"/>')
        bottom.append(f'<circle cx="{tx}" cy="{ty}" r=".4" fill="#91b9f4"/>')
        bottom.append(svg_text(tx,ty-1,k['net'],1.05,color='#b8cfee'))
        px,py=k['connector_pin_mm']
        shape=f'<rect x="{px-.9:.4f}" y="{py-.9}" width="1.8" height="1.8" fill="#c1a366"/>' if k['pin']==1 else f'<circle cx="{px:.4f}" cy="{py}" r=".9" fill="#c1a366"/>'
        shape+=f'<circle cx="{px:.4f}" cy="{py}" r=".5" fill="#181b20"/>'
        top.append(shape);bottom.append(shape)
        top.append(svg_text(px,100.3,str(k['pin']),1.0))
        bottom.append(svg_text(px,99.1,str(k['ele']),1.0))
    top.append(svg_text(10,89,'25 KEYS / NO MCU / MPR121 EXTERNAL',1.1,anchor='start'))
    bottom.append(svg_text(10,12,'PASSIVE ELECTRODES: NO VCC / NO GND',2.1,anchor='start'))
    for j in J_CONFIG:
        label=f"{j['name']} E{j['start']:02}-E{j['start']+j['count']-1:02}"
        top.append(svg_text(j['x'],91,label,1.2))
        bottom.append(svg_text(j['x'],90.3,f"{j['name']} -> MPR{J_CONFIG.index(j)+1} ELE0-{j['count']-1}",1.2))
        top.append(svg_text(j['x'],102.2,'PIN1 LEFT (TOP VIEW)',1.0))
    (ROOT/'top_preview.svg').write_text(svg_doc('Touch25 top engineering preview','\n'.join(top),'Top view | shaded areas show covered copper electrodes; not a native Gerber render.'),encoding='utf-8')
    (ROOT/'bottom_preview.svg').write_text(svg_doc('Touch25 bottom routing engineering preview','\n'.join(bottom),'Bottom copper shown through the board from top, not mirrored | numbers below pins are MPR121 ELE channels.'),encoding='utf-8')

def write_mapping(ks):
    fields=['key_index','net','midi','note','key_color','connector','connector_pin','mpr121_board','mpr121_electrode','x_mm','y_mm','pin_x_mm','pin_y_mm']
    with (ROOT/'mapping.csv').open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
        for k in ks:w.writerow(dict(key_index=k['index'],net=k['net'],midi=k['midi'],note=k['note'],key_color=k['color'],connector=k['connector'],connector_pin=k['pin'],mpr121_board=k['mpr121_board'],mpr121_electrode=f"ELE{k['ele']}",x_mm=k['center_mm'][0],y_mm=k['center_mm'][1],pin_x_mm=k['connector_pin_mm'][0],pin_y_mm=k['connector_pin_mm'][1]))

def main():
    ks=keys();p=native_design(ks);output=p.save(ROOT/(NAME+'.epro2'))
    manifest=dict(name=NAME,revision='R1',status='PROTOTYPE: native import, native DRC and native Gerber validation pending',coordinate_convention='millimetres, x right and y down; native y = -preview y',native_y_sign=NATIVE_Y_SIGN,board=dict(width_mm=290,height_mm=105,layers=2,solder_mask='black',silkscreen='white',thickness_recommended_mm=1.6,no_ground_plane=True,no_onboard_controller=True,no_electrode_mask_openings=True),white_pitch_mm=18,midi_range=[60,84],keys_count=25,white_count=15,black_count=10,trace_width_mm=.18,fanout_finish_y_mm=92.5,connector_pads=dict(hole_mm=1.0,outer_mm=1.8,pitch_mm=2.54,pin1='square'),transfer_pads=dict(hole_mm=.3,outer_mm=.8,annular_ring_mm=.25,mask_expansion_mm=-.4,validation='Check zero-size apertures/tenting in native DRC and Gerber'),silkscreen_minimum=dict(text_height_mm=1.0,stroke_width_mm=.15),mounting_holes=dict(diameter_mm=3.2,plated=False,centers_mm=HOLES),connectors=J_CONFIG,keys=ks,limitations=['MPR121 breakout modules are external and require separate 3.3 V power/GND/SCL/SDA/IRQ wiring.','This panel exports electrodes only; no VCC/GND pins are present.','A 25-key touch input driver and calibration are still required in the FPGA.','No claim of measured capacitive latency or end-to-end <=10 ms.','Native drill typing, pad mask coverage and routing clearance require verification before ordering.'],output_sha256=hashlib.sha256(output.read_bytes()).hexdigest())
    (ROOT/'design_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    write_mapping(ks);render_previews(ks)
    print(json.dumps(dict(output=str(output),keys=len(ks),white=15,black=10,dimensions_mm=[290,105],status=manifest['status']),ensure_ascii=False))

if __name__=='__main__':main()
