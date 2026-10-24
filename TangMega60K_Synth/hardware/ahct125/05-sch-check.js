await new Promise(r=>setTimeout(r,8000));
const passed=await eda.sch_Drc.check(true,false,false);
const verbose=await eda.sch_Drc.check(true,false,true);
const net=await eda.sch_ManufactureData.getNetlistFile('AHCT125_LED_R1_NET','Protel2');
const dir='C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1/';
const netSaved=await eda.sys_FileSystem.saveFileToFileSystem(dir+'AHCT125_LED_R1.net',net,undefined,true);
const png=await eda.sch_ManufactureData.getPngFile('AHCT125_LED_R1_schematic',{width:2200});
const pngSaved=await eda.sys_FileSystem.saveFileToFileSystem(dir+'schematic.png',png,undefined,true);
return {passed,verbose,netSaved,pngSaved,net:await net.text()};
