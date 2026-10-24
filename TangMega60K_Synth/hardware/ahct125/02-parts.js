const codes = ['C155176','C25804','C23138','C14663','C15850','C124376'];
const out = [];
for (const code of codes) {
  const items = await eda.lib_Device.search(code);
  out.push({code, items});
}
return out;
