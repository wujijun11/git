const mm=v=>v*1000/25.4,M=(x,y)=>[mm(x),-mm(y)];
await eda.pcb_PrimitiveLine.delete('4c0d0aaafe097cd9');
await eda.pcb_PrimitiveLine.delete('8342301227bc583e');
const comps={};for(const c of await eda.pcb_PrimitiveComponent.getAll())comps[c.getState_Designator()]=await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId());
const P=(r,n)=>{const p=comps[r].find(p=>p.padNumber===n);return[p.x,p.y];};
async function route(net,w,points){for(let i=1;i<points.length;i++)await eda.pcb_PrimitiveLine.create(net,1,...points[i-1],...points[i],mm(w));}
await route('+5V',.5,[P('C2','1'),M(18.001,10),M(23.299,10),M(23.299,8)]);
// Move only the ground return beside the otherwise unused U1.11 land.
const vs=await eda.pcb_PrimitiveVia.getAll();
for(const v of vs)if(v.getState_Net()==='GND'&&Math.abs(v.getState_X()-mm(23.8))<.1&&Math.abs(v.getState_Y()+mm(17.6))<.1)await eda.pcb_PrimitiveVia.modify(v.getState_PrimitiveId(),{x:mm(24.2)});
await route('GND',.35,[P('U1','12'),M(24.2,16.731),M(24.2,17.6)]);
const poly=eda.pcb_MathPolygon.createPolygon([mm(.5),-mm(.5),'L',mm(39.5),-mm(.5),mm(39.5),-mm(29.5),mm(.5),-mm(29.5),mm(.5),-mm(.5)]);
const pours=[];
for(const layer of [1,2]){
 const p=await eda.pcb_PrimitivePour.create('GND',layer,poly,'solid',false,'GND_'+layer,1,mm(.25),false);
 if(!p)throw Error('Ground pour');pours.push(p.getState_PrimitiveId());
}
await eda.pcb_Document.save();return {pours};
