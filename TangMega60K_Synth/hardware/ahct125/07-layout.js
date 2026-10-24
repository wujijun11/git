const mm=v=>v*1000/25.4;
const pos={U1:[20,18,90],R1:[12,18,90],R2:[30,16,0],C1:[24,12,0],C2:[19,8,0],C3:[29,7,0],J1:[3,16,90],J2:[37,18,90],J3:[8.5,5,0]};
const all=await eda.pcb_PrimitiveComponent.getAll();
if(all.length!==9)throw Error('Expected 9 parts, got '+all.length);
for(const c of all){const ref=c.getState_Designator(); const [x,y,rotation]=pos[ref];
 await eda.pcb_PrimitiveComponent.modify(c.getState_PrimitiveId(),{x:mm(x),y:-mm(y),rotation,layer:1});}
await eda.pcb_Document.save();
await new Promise(r=>setTimeout(r,5000));
const out=[];
for(const c of await eda.pcb_PrimitiveComponent.getAll()){
 out.push({ref:c.getState_Designator(),id:c.getState_PrimitiveId(),x:c.getState_X(),y:c.getState_Y(),rotation:c.getState_Rotation(),pads:await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId())});
}
await eda.pcb_Document.zoomToBoardOutline();return out;
