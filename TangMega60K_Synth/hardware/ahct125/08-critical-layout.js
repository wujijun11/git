const mm=v=>v*1000/25.4;
const all=await eda.pcb_PrimitiveComponent.getAll();
for(const c of all){
 const ref=c.getState_Designator();
 if(ref==='U1')await eda.pcb_PrimitiveComponent.modify(c.getState_PrimitiveId(),{rotation:270});
 if(ref==='R1')await eda.pcb_PrimitiveComponent.modify(c.getState_PrimitiveId(),{y:-mm(16)});
 if(ref==='R2')await eda.pcb_PrimitiveComponent.modify(c.getState_PrimitiveId(),{y:-mm(20.54)});
}
const holes=[];
for(const [x,y] of [[3,27],[37,3]]){
 const h=await eda.pcb_PrimitivePad.create(12,'',mm(x),-mm(y),0,['ELLIPSE',mm(3.2),mm(3.2)],'', ['ROUND',mm(3.2)],0,0,0,false,0);
 if(!h)throw Error('mounting hole'); holes.push(h.getState_PrimitiveId());
}
await eda.pcb_Document.save();
await new Promise(r=>setTimeout(r,5000));
const parts=[];
for(const c of await eda.pcb_PrimitiveComponent.getAll())parts.push({ref:c.getState_Designator(),id:c.getState_PrimitiveId(),x:c.getState_X(),y:c.getState_Y(),rotation:c.getState_Rotation(),pads:await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId())});
return {parts,holes,rules:await eda.pcb_Drc.getCurrentRuleConfiguration(),netRules:await eda.pcb_Drc.getNetRules()};
