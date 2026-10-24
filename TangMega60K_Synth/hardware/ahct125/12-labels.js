const project=await eda.dmt_Project.getCurrentProjectInfo();
await eda.dmt_EditorControl.openDocument(project.data[0].schematic.page[0].uuid);
for(const t of await eda.sch_PrimitiveText.getAll()){
 const s=t.getState_Content();
 let y=null;
 if(s.startsWith('AHCT and LED'))y=230;
 if(s.startsWith('Keep output-to-LED'))y=210;
 if(s.startsWith('Prototype:'))y=190;
 if(y!==null)await eda.sch_PrimitiveText.modify(t.getState_PrimitiveId(),{y});
}
await eda.sch_Document.save();
const dir='C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1/';
const sch=await eda.sch_ManufactureData.getPngFile('schematic',{width:2200});
await eda.sys_FileSystem.saveFileToFileSystem(dir+'schematic.png',sch,undefined,true);
await eda.dmt_EditorControl.openDocument(project.data[0].pcb.uuid);
const mm=v=>v*1000/25.4;
const labels={U1:[20,23.6],R1:[10,16],R2:[30,22.4],C1:[24,10.8],C2:[19,6.7],C3:[29,1.3],J1:[3,12.9],J2:[37,22.9],J3:[8.5,.8]};
for(const c of await eda.pcb_PrimitiveComponent.getAll()){
 const ref=c.getState_Designator(),[x,y]=labels[ref];
 for(const a of await eda.pcb_PrimitiveAttribute.getAll(c.getState_PrimitiveId())){
  if(a.getState_Key()==='Designator')await eda.pcb_PrimitiveAttribute.modify(a.getState_PrimitiveId(),{x:mm(x),y:-mm(y),rotation:0,fontSize:mm(.85),lineWidth:mm(.15),alignMode:5,layer:3,keyVisible:false,valueVisible:true});
 }
}
const created=[];
for(const [x,y,t,size,align]of [
 [7,25.7,'AHCT125 LED R1',1.3,2], [7,27.4,'3.3V IN > 5V OUT',.85,2],
 [7,29,'5V ONLY / COMMON GND',.75,2],
 [4.9,14.729,'GND',.85,2],[4.9,17.269,'IN',.85,2],
 [1.3,11.1,'FPGA',.85,2], [35.4,15.461,'GND',.85,8],
 [35.4,18.001,'+5V',.85,8],[35.4,20.541,'OUT',.85,8],
 [34.7,12.8,'LED',.85,2], [5.959,10.3,'+5V',.85,5],
 [11.039,10.3,'GND',.85,5], [16.5,4.8,'5V ONLY',1,2],
 [27,12.3,'1000uF',.75,2]
]){
 const s=await eda.pcb_PrimitiveString.create(3,mm(x),-mm(y),t,'default',mm(size),mm(.15),align,0,false,0,false,false);
 if(!s)throw Error('silk '+t);created.push(s.getState_PrimitiveId());
}
await eda.pcb_Document.save();await eda.pcb_Document.zoomToBoardOutline();
return {created};
