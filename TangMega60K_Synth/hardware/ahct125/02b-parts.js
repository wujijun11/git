const out=[];
for (const code of ['C124375','KF301-5.08-2P','1000uF 10V']) {
  out.push({code,items: await eda.lib_Device.search(code,undefined,undefined,undefined,12,1)});
}
return out;
