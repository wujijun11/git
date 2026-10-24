const dir='C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1/';
const project=await eda.dmt_Project.getCurrentProjectInfo();
await eda.dmt_EditorControl.openDocument(project.data[0].pcb.uuid);
await eda.pcb_Document.save();
const results=[];
async function save(path,file){
 if(!file||!file.size)throw Error('Empty export '+path);
 const saved=await eda.sys_FileSystem.saveFileToFileSystem(dir+path,file,undefined,true);
 if(!saved)throw Error('Failed export '+path);
 results.push({path,bytes:file.size});
}
await save('Gerber_AHCT125_LED_R1.zip',await eda.pcb_ManufactureData.getGerberFile('Gerber_AHCT125_LED_R1'));
await save('BOM_AHCT125_LED_R1.csv',await eda.pcb_ManufactureData.getBomFile('BOM_AHCT125_LED_R1','csv'));
await save('BOM_AHCT125_LED_R1.xlsx',await eda.pcb_ManufactureData.getBomFile('BOM_AHCT125_LED_R1','xlsx'));
await save('CPL_AHCT125_LED_R1.csv',await eda.pcb_ManufactureData.getPickAndPlaceFile('CPL_AHCT125_LED_R1','csv','mm'));
await save('CPL_AHCT125_LED_R1.xlsx',await eda.pcb_ManufactureData.getPickAndPlaceFile('CPL_AHCT125_LED_R1','xlsx','mm'));
await save('Assembly_AHCT125_LED_R1.html',await eda.pcb_ManufactureData.getInteractiveBomFile('Assembly_AHCT125_LED_R1'));
await save('PCB_AHCT125_LED_R1.pdf',await eda.pcb_ManufactureData.getPdfFile('PCB_AHCT125_LED_R1'));
await eda.pcb_Document.save();
return results;
