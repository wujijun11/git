const mm=v=>v*1000/25.4;
const M=(x,y)=>[mm(x),-mm(y)];
const parts={};
for(const c of await eda.pcb_PrimitiveComponent.getAll()){
 const ref=c.getState_Designator();parts[ref]={};
 for(const p of await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId()))parts[ref][p.padNumber]=[p.x,p.y];
}
const P=(r,n)=>parts[r][n];
const traces=[],vias=[];
async function route(net,layer,width,points){
 for(let i=1;i<points.length;i++){
  const [x1,y1]=points[i-1],[x2,y2]=points[i];
  const t=await eda.pcb_PrimitiveLine.create(net,layer,x1,y1,x2,y2,mm(width),false);
  if(!t)throw Error('trace '+net);traces.push(t.getState_PrimitiveId());
 }
}
async function via(net,x,y){const v=await eda.pcb_PrimitiveVia.create(net,mm(x),-mm(y),mm(.3),mm(.65));if(!v)throw Error('via');vias.push(v.getState_PrimitiveId());}
// Main LED power path remains entirely on the top; short spur into the connector.
await route('+5V',1,1.6,[P('J3','1'),M(5.959,2),M(34,2),M(34,18),P('J2','2')]);
await route('+5V',1,1.2,[M(27.249,2),P('C3','1')]);
await route('+5V',1,.6,[M(18.001,2),P('C2','1')]);
await route('+5V',1,.5,[P('C2','1'),M(23.299,8),P('C1','1')]);
// Local decoupling directly feeds the AHCT VCC lead.
await route('+5V',1,.35,[P('C1','1'),M(23.299,13.51),P('U1','14'),P('U1','13')]);
await route('+5V',1,.35,[P('U1','13'),M(25.5,15.461),M(25.5,19.271),P('U1','10')]);
await via('+5V',21.5,12);await via('+5V',19,18);
await route('+5V',1,.4,[P('C1','1'),M(21.5,12)]);
await route('+5V',2,.4,[M(21.5,12),M(19,14.5),M(19,18)]);
await route('+5V',1,.35,[M(19,18),P('U1','4')]);
// Input and its pull-down; no 5V pin is present on J1.
await route('DATA_IN',1,.25,[P('J1','1'),M(11.485,17.269),P('R1','1')]);
await route('DATA_IN',1,.25,[P('R1','1'),M(13.292,15.461),P('U1','2')]);
// Buffered data crosses under the IC, then reaches the output-side 330R resistor.
await via('BUF_OUT',20,16.731);await via('BUF_OUT',28.6,20.541);
await route('BUF_OUT',1,.25,[P('U1','3'),M(20,16.731)]);
await route('BUF_OUT',2,.25,[M(20,16.731),M(24.79,16.731),M(28.6,20.541)]);
await route('BUF_OUT',1,.25,[M(28.6,20.541),P('R2','1')]);
await route('DATA_OUT',1,.25,[P('R2','2'),P('J2','1')]);
// Each local ground connection reaches the lower ground plane through a nearby via.
for(const [r,n,x,y]of [['C1','2',25.4,12],['C2','2',20.7,8],['R1','2',12,14.4],
 ['U1','1',16,14.191],['U1','5',16,19.271],['U1','7',16,21.811],
 ['U1','9',24,20.541],['U1','12',23.8,17.6]]){
 await via('GND',x,y);await route('GND',1,.35,[P(r,n),M(x,y)]);
}
// Both copper pours are actual ground-net pours; isolated islands are removed.
const poly=eda.pcb_MathPolygon.createPolygon([mm(.5),-mm(.5),'L',mm(39.5),-mm(.5),mm(39.5),-mm(29.5),mm(.5),-mm(29.5),mm(.5),-mm(.5)]);
const pours=[];
for(const layer of [1,2]){const p=await eda.pcb_PrimitivePour.create('GND',layer,poly,0,false,'GND_'+layer,1,mm(.25),false);pours.push(p?.getState_PrimitiveId());}
await eda.pcb_Document.save();return {traces,vias,pours};
