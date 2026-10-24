"""Prepare small, reviewable editor API calls from captured library metadata."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def read(name):
    return json.loads((ROOT/'references'/name).read_text(encoding='utf-8'))['value']

parts = {x['code']: x['items'][0] for x in read('parts.json') + read('extra-parts.json') if x['items']}
spec = [['U1','C155176',500,570,0], ['R1','C25804',340,480,90],
        ['R2','C23138',710,570,0], ['C1','C14663',440,280,0],
        ['C2','C15850',620,280,0], ['J1','C124375',160,570,0],
        ['J2','C124376',890,570,0]]
code = 'const parts='+json.dumps(parts, ensure_ascii=False)+';\nconst spec='+json.dumps(spec)+';\n'
code += '''
const project=await eda.dmt_Project.getCurrentProjectInfo();
const page=project.data[0].schematic.page[0].uuid;
await eda.dmt_EditorControl.openDocument(page);
await new Promise(r=>setTimeout(r,1500));
const out=[];
for(const [ref,code,x,y,angle] of spec){
  const part=parts[code];
  const c=await eda.sch_PrimitiveComponent.create({libraryType:'3',libraryUuid:part.libraryUuid,uuid:part.uuid},x,y,undefined,angle,false,true,true);
  if(!c)throw Error('place '+ref);
  const id=c.getState_PrimitiveId();
  const props=(await eda.sch_PrimitiveComponent.get(id)).getState_OtherProperty();
  await eda.sch_PrimitiveComponent.modify(id,{designator:ref,otherProperty:props});
  const pins=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(id);
  out.push({ref,code,id,properties:props,pins});
}
await eda.sch_Document.save();
return {page,pcb:project.data[0].pcb.uuid,components:out};
'''
(ROOT/'03-place.js').write_text(code,encoding='utf-8')
