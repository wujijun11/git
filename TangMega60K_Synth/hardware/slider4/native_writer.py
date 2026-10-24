"""Minimal new EasyEDA Pro .epro2 writer, independent of the 555 project.

All public methods use millimetres. Internal native coordinates are mil.
Use generate_touch25.py for the actual panel candidate.
"""
from pathlib import Path
import json,uuid,time,zipfile,copy

ROOT=Path(__file__).parent
MIL=1000/25.4
def mm(v): return round(float(v)*MIL,6)
def uid(): return uuid.uuid4().hex[:16]
def compact(x):return json.dumps(x,ensure_ascii=False,separators=(',',':'))
def path_mm(points):
    assert len(points)>=3
    p=[mm(points[0][0]),mm(points[0][1]),'L']
    for x,y in points[1:]:p.extend([mm(x),mm(y)])
    if points[-1]!=points[0]:p.extend([mm(points[0][0]),mm(points[0][1])])
    return p

class NativePCB:
    def __init__(self,title):
        self.title=title;self.rows=[];self.ticket=0;self.z=0;self.nets=set()
        self.board=uid();self.pcb=uid();self.client=uid();self.now=int(time.time()*1000)
        self.head('BOARD',self.board)
        self.add('META','META',dict(title=title,zIndex=1))
        self.head('PCB',self.pcb)
        self.add('META','META',dict(title=title,parent='',source='',board=self.board,zIndex=1))
        self.add('CANVAS','CANVAS',dict(originX=0,originY=0,unit='mm',gridXSize=mm(.5),gridYSize=mm(.5),snapXSize=mm(.1),snapYSize=mm(.1),altSnapXSize=mm(.1),altSnapYSize=mm(.1),gridType='GRID',multiGridType='NONE',multiGridRatio=5,highlightValue=.5,layerBrightness='NORMAL'))
        for r in json.loads((ROOT/'clean_editor_defaults.json').read_text(encoding='utf-8')):
            self.add(r['kind'],r['id'],copy.deepcopy(r['body']))
        self.add_net('')
    def head(self,kind,id):
        self.add('DOCHEAD',None,dict(docType=kind,client=self.client,uuid=id,updateTime=self.now,version=str(self.now),editVersion='4.1.60',user=dict(uuid='',username='',nickname='')))
    def add(self,kind,id,body):
        self.ticket+=1
        h=dict(type=kind,ticket=self.ticket)
        if id is not None:h['id']=id
        self.rows.append((h,body));return id
    def obj(self,kind,body):
        self.z+=1
        return self.add(kind,uid(),dict(partitionId='',groupId=0,locked=False,zIndex=self.z,**body))
    def add_net(self,name):
        if name in self.nets:return
        self.nets.add(name)
        self.add('NET',compact(['NET',name]),dict(netType=None,specialColor=None,retLine=True,differentialName=None,isPositiveNet=False,equalLengthGroupName=None))
        self.add('RULE_SELECTOR',compact(['RULE_SELECTOR',['NET',name]]),dict(ruleOrder=4,ruleKeyValue={},copperValue={'COPPER':'default'},innerPlaneValue={'PLANE':'default'}))
    def fill(self,points,net='',layer=1):
        """Copper/electrode polygon. No automatic mask or paste aperture."""
        self.add_net(net)
        return self.obj('FILL',dict(netName=net,layerId=layer,width=0,fillStyle='SOLID',path=[path_mm(points)],isBridgingCopper=False,networkList=[],refs=[]))
    def outline(self,points):
        return self.obj('POLY',dict(netName='',layerId=11,width=mm(.1),path=path_mm(points),polyType='NORMAL'))
    def poly(self,points,layer=3,width=.15,closed=True):
        p=path_mm(points) if closed else [mm(points[0][0]),mm(points[0][1]),'L',*[v for x,y in points[1:] for v in (mm(x),mm(y))]]
        return self.obj('POLY',dict(netName='',layerId=layer,width=mm(width),path=p,polyType='NORMAL'))
    def track(self,p1,p2,net,layer=2,width=.25):
        self.add_net(net)
        return self.obj('LINE',dict(netName=net,layerId=layer,startX=mm(p1[0]),startY=mm(p1[1]),endX=mm(p2[0]),endY=mm(p2[1]),width=mm(width)))
    def pad(self,x,y,num,net,diameter=1.8,hole=.9,shape='ELLIPSE',plated=True):
        """Free through-hole PAD, not a footprint instance; connector pin."""
        self.add_net(net)
        return self.obj('PAD',dict(netName=net,layerId=12,num=str(num),centerX=mm(x),centerY=mm(y),padAngle=0,hole=dict(holeType='ROUND',width=mm(hole),height=mm(hole)),defaultPad=dict(padType=shape,width=mm(diameter),height=mm(diameter)),specialPad=[],padOffsetX=0,padOffsetY=0,relativeAngle=0,plated=plated,padType='NORMAL',topSolderExpansion=mm(.05),bottomSolderExpansion=mm(.05),topPasteExpansion=0,bottomPasteExpansion=0,connectMode=None,spokeSpace=None,spokeWidth=None,spokeAngle=None,padLen=0))
    def hole(self,x,y,diameter=3.2):
        return self.pad(x,y,'','',diameter=diameter,hole=diameter,plated=False)
    def text(self,x,y,text,layer=3,height=1.2,width=.15,origin='LEFT_BOTTOM',mirror=False):
        return self.obj('STRING',dict(layerId=layer,x=mm(x),y=mm(y),text=text,fontFamily='default',fontSize=mm(height),strokeWidth=mm(width),bold=False,italic=False,origin=origin,angle=0,reverse=False,expansion=0,mirror=mirror))
    def save(self,path):
        path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
        native='\n'.join(compact(h)+'||'+compact(b)+'|' for h,b in self.rows)+'\n'
        project=dict(title=self.title,cbb_project=0,editorVersion='4.1.60',introduction='',description='New passive touch electrode PCB. No MCU or audio electronics.',custom_tags='[]')
        with zipfile.ZipFile(path,'w',compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr('project2.json',json.dumps(project,ensure_ascii=False,indent=2))
            z.writestr(self.title+'.epru',native)
        path.with_suffix('.epru').write_text(native,encoding='utf-8')
        return path

