const all=await eda.sch_PrimitiveComponent.getAll();
const map={U1:{1:'GND',2:'DATA_IN',3:'BUF_OUT',4:'+5V',5:'GND',7:'GND',9:'GND',10:'+5V',12:'GND',13:'+5V',14:'+5V'},
 R1:{1:'DATA_IN',2:'GND'},R2:{1:'BUF_OUT',2:'DATA_OUT'},
 C1:{1:'+5V',2:'GND'},C2:{1:'+5V',2:'GND'},C3:{1:'+5V',2:'GND'},
 J1:{1:'DATA_IN',2:'GND'},J2:{1:'DATA_OUT',2:'+5V',3:'GND'},J3:{1:'+5V',2:'GND'}};
const out=[];
for(const c of all){
 const ref=c.getState_Designator(); if(!map[ref])continue;
 const pins=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId());
 for(const p of pins){
   const n=p.getState_PinNumber ? p.getState_PinNumber() : p.pinNumber;
   const net=map[ref][n];
   if(!net){
     p.noConnected=true; await p.done(); out.push({ref,pin:n,nc:true});continue;
   }
   const x=p.x,y=p.y;
   const dx=p.rotation===180?-50:p.rotation===0?50:0;
   const dy=p.rotation===90?35:p.rotation===270?-35:0;
   const w=await eda.sch_PrimitiveWire.create([x,y,x+dx,y+dy],net);
   if(!w)throw Error('wire '+ref+'.'+n+' '+net);
   out.push({ref,pin:n,net,id:w.getState_PrimitiveId()});
 }
}
for(const [x,y,t,size] of [
 [120,740,'AHCT125 LED interface / R1 / 2026-10-18',18],
 [120,705,'FPGA 3.3V DATA -> 5V WS2812 DIN (one direction)',12],
 [120,665,'J1: 1 DATA IN, 2 GND. NO POWER PIN TO FPGA.',11],
 [660,665,'J2: 1 LED DIN, 2 +5V, 3 GND',11],
 [120,385,'J3: 1 +5V, 2 GND / regulated external supply',11],
 [390,385,'100nF near U1.14; C3 1000uF/10V near LED.',11],
 [120,170,'AHCT and LED MUST share +5V/GND. Not 12V. No 5V output into FPGA.',11],
 [120,140,'Keep output-to-LED wire short. Confirm pin 1 and capacitor polarity before power.',11],
 [120,110,'Prototype: electrical/layout checks do not replace first-board waveform tests.',11]
])await eda.sch_PrimitiveText.create(x,y,t,0,null,null,size,false,false,false);
await eda.sch_Document.save();
return out;
