const out=[];
for(const code of ['C474906','C88853']) {
  const items=await eda.lib_Device.search(code);
  if(!items.length)throw Error('Missing part '+code);
  const p=items[0];
  const [ref,x,y]=code==='C474906'?['J3',180,280]:['C3',800,280];
  const c=await eda.sch_PrimitiveComponent.create({libraryType:'3',libraryUuid:p.libraryUuid,uuid:p.uuid},x,y,undefined,0,false,true,true);
  const id=c.getState_PrimitiveId();
  const props=(await eda.sch_PrimitiveComponent.get(id)).getState_OtherProperty();
  await eda.sch_PrimitiveComponent.modify(id,{designator:ref,otherProperty:props});
  out.push({ref,code,id,part:p,pins:await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(id)});
}
await eda.sch_Document.save();return out;
