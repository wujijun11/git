'use strict';
// Run the actual UI controller against deliberately reordered data operations.
const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
const source=process.argv[2]||path.join(__dirname,'../web/app.js');
class Element{constructor(value=''){this.value=value;this.children=[];this.textContent='';this.classList={add(){},remove(){}};}append(e){this.children.push(e);}setPointerCapture(){}click(){if(this.onclick)this.onclick();}}
const elements=new Map(),defaults={timbre:'2',effect:'0',velocity:'100',gain:'2048',bend:'0',vibrato:'0',mapKey:'0',mapNote:'60'};
for(const id of fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8').matchAll(/id="([^"]+)"/g))elements.set(id[1],new Element(defaults[id[1]]||''));
const context={console,setTimeout,clearTimeout,setInterval(){},performance,Blob,URL,AbortController,TextEncoder,navigator:{},isSecureContext:true,addEventListener(){},localStorage:{getItem(){return 0;},setItem(){}},document:{hidden:false,getElementById:id=>elements.get(id),createElement:()=>new Element(),addEventListener(){}}};context.window=context;context.globalThis=context;vm.createContext(context);
vm.runInContext(fs.readFileSync(path.join(__dirname,'../web/protocol.js'),'utf8'),context);
// 与实际HTML保持相同的依赖顺序，避免新增实时播放模块后旧测试台漏加载。
for(const file of ['realtime-score.js','realtime-playback.js'])
  vm.runInContext(fs.readFileSync(path.join(__dirname,'../web',file),'utf8'),context,{filename:file});
vm.runInContext(fs.readFileSync(source,'utf8'),context,{filename:source});
const run=code=>vm.runInContext(code,context),delay=ms=>new Promise(r=>setTimeout(r,ms));
const doc=title=>JSON.stringify({version:1,title,rows:[{deltaMs:0,key:0,velocity:100,on:1},{deltaMs:50,key:0,velocity:0,on:0}]});
async function flush(){await delay(0);await delay(0);}
async function until(fn){for(let i=0;i<200;i++){if(fn())return;await delay(5);}throw new Error('async workflow timed out');}
let passed=0,failed=0,jobs=[];
function track(p){p.catch(()=>{});jobs.push(p);return p;}
async function test(name,fn){try{await fn();console.log('PASS '+name);passed++;}catch(e){console.error('FAIL '+name+': '+e.message);failed++;}finally{await Promise.allSettled(jobs);jobs=[];delete context.AndroidBle;}}
async function main(){
 await test('latest HTTPS result wins; prior browser request is aborted',async()=>{
   const requests=[];context.fetch=(url,options)=>new Promise(resolve=>requests.push({url,options,resolve}));
   elements.get('scoreUrl').value='https://example.test/old';elements.get('loadUrl').click();await flush();
   elements.get('scoreUrl').value='https://example.test/new';elements.get('loadUrl').click();await flush();
   requests[1].resolve({ok:true,text:async()=>doc('new')});await flush();
   requests[0].resolve({ok:true,text:async()=>doc('old')});await flush();
   assert.equal(run('score.title'),'new');assert.equal(requests[0].options.signal.aborted,true);
 });
 await test('obsolete HTTP failure cannot replace a newer score status',async()=>{
   const requests=[];context.fetch=()=>new Promise((resolve,reject)=>requests.push({resolve,reject}));
   elements.get('scoreUrl').value='https://example.test/old';elements.get('loadUrl').click();await flush();
   elements.get('scoreUrl').value='https://example.test/new';elements.get('loadUrl').click();await flush();
   requests[1].resolve({ok:true,text:async()=>doc('newer')});await flush();const status=elements.get('status').textContent;
   requests[0].reject(new Error('obsolete network failure'));await flush();assert.equal(elements.get('status').textContent,status);
 });
 await test('latest local file wins over an older pending file read',async()=>{
   let resolveOld;elements.get('scoreFile').files=[{size:50,text:()=>new Promise(resolve=>resolveOld=resolve)}];const old=elements.get('scoreFile').onchange();
   elements.get('scoreFile').files=[{size:50,text:async()=>doc('file-new')}];await elements.get('scoreFile').onchange();
   resolveOld(doc('file-old'));await old;assert.equal(run('score.title'),'file-new');
 });
 await test('native download result IDs are scoped and local choice cancels it',async()=>{
   const native=[];let cancelled=0;context.AndroidBle={loadScoreUrl:(url,id)=>native.push({url,id}),cancelScoreLoad:()=>cancelled++};
   elements.get('scoreUrl').value='https://example.test/native-old';elements.get('loadUrl').click();await flush();
   elements.get('scoreUrl').value='https://example.test/native-new';elements.get('loadUrl').click();await flush();
   context.nativeScoreLoaded(doc('native-new'),null,native[1].id);context.nativeScoreLoaded(doc('native-old'),null,native[0].id);
   assert.equal(run('score.title'),'native-new');
   elements.get('scoreFile').files=[{size:50,text:async()=>doc('file-after-native')}];await elements.get('scoreFile').onchange();
   context.nativeScoreLoaded(doc('native-old'),null,native[1].id);assert.equal(run('score.title'),'file-after-native');assert.ok(cancelled>=3);delete context.AndroidBle;
 });
 function ready(){run(`globalThis.writes=[];globalThis.mock=new Simulator();createSession(b=>{writes.push(P.decode(b));return mock.write(b);},true);setControlReady(true);mock.deliver=b=>decoder&&decoder.push(b);setScore(${doc('upload')});`);}
 await test('parallel uploads reject without interleaving rows or commits',async()=>{
   ready();const first=track(run('upload()'));await assert.rejects(run('upload()'),/正在|完成/);await first;assert.equal(run('writes.filter(p=>p.op===6).length'),2);assert.equal(run('writes.filter(p=>p.op===7&&p.payload[2]!==1).length'),1);
 });
 await test('upload excludes recorder operations and builtin replacement',async()=>{
   ready();const first=track(run('upload()'));await assert.rejects(run('readRecording()'),/正在|完成/);
   elements.get('builtin').click();elements.get('recordStart').click();elements.get('recordClear').click();elements.get('play').click();await flush();await first;
   assert.equal(run('writes.filter(p=>p.op===7&&p.payload[2]!==1).length'),1);assert.equal(run('writes.some(p=>p.op===4&&[1,2,4].includes(p.payload[0]))'),false);
 });
 await test('upload locks score replacement; new selection works after completion',async()=>{
   ready();const first=track(run('upload()'));
   assert.throws(()=>run(`setScore(${doc('new-not-uploaded')});`),/正在上传/);
   await first;
   assert.equal(run('score.title'),'upload');
   assert.equal(run('writes.filter(p=>p.op===6).length'),2);
   run(`setScore(${doc('new-not-uploaded')});`);
   assert.match(elements.get('scoreInfo').textContent,/new-not-uploaded.*尚未上传/);
 });
 await test('stop cancels remaining score rows and commit',async()=>{
   ready();const first=track(run('upload()'));await until(()=>run('writes.some(p=>p.op===6)'));elements.get('stop').click();await assert.rejects(first,/取消/);await delay(40);
   assert.equal(run('writes.filter(p=>p.op===6).length'),1);assert.equal(run('writes.filter(p=>p.op===7&&p.payload[2]!==1).length'),0);assert.equal(run('dataOperation'),null);
 });
 await test('recorder read excludes export, start and clear, then releases lock',async()=>{
   ready();run('mock.events=[{deltaMs:0,source:25,midi:60,velocity:100,timbre:0,on:1},{deltaMs:50,source:25,midi:60,velocity:0,timbre:0,on:0}]');
   const read=track(run('readRecording()'));assert.throws(()=>run('exportRecording()'),/正在|完成/);elements.get('recordStart').click();elements.get('recordClear').click();await flush();await read;
   assert.equal(run('recorded.length'),2);assert.equal(run('writes.some(p=>p.op===4&&[2,4].includes(p.payload[0]))'),false);assert.equal(run('dataOperation'),null);
 });
 await test('failed bulk command releases operation lock for retry',async()=>{
   ready();run(`const previous=mock.write.bind(mock);mock.write=bytes=>{const p=P.decode(bytes);mock.write=previous;setTimeout(()=>mock.deliver(P.encode(p.seq,128,[p.op,1])),0);return Promise.resolve();};`);
   await assert.rejects(run('upload()'),/NACK/);assert.equal(run('dataOperation'),null);await run('upload()');assert.equal(run('writes.filter(p=>p.op===7&&p.payload[2]!==1).length'),1);
 });
 await test('native file-error info keeps the healthy JS session and controls',async()=>{
   ready();const owner=run('session');context.nativeBleState('info','导出失败：测试文档提供器');
   assert.equal(run('session'),owner);assert.equal(run('controlReady'),true);assert.equal(elements.get('keys').children[0].disabled,false);
   assert.match(elements.get('status').textContent,/导出失败/);await run('readback(0)');
 });
 await test('mapped upload failure restores all previous physical key pitches',async()=>{
   ready();const old=JSON.parse(run('JSON.stringify(map)'));
   run(`{setScore({...${doc('mapped')},mapping:Array.from({length:25},(_,i)=>40+i)});
     const previous=mock.write.bind(mock);let rejected=false;mock.write=bytes=>{const p=P.decode(bytes);if(p.op===6&&!rejected){rejected=true;setTimeout(()=>mock.deliver(P.encode(p.seq,128,[p.op,2])),0);return Promise.resolve();}return previous(bytes);};}`);
   await assert.rejects(run('upload()'),/NACK/);
   assert.deepEqual(JSON.parse(run('JSON.stringify(map)')),old);
   const maps=JSON.parse(run('JSON.stringify(writes.filter(p=>p.op===5))'));
   assert.equal(maps.length,50);assert.deepEqual(maps.slice(-25).map(p=>p.payload[1]),old);
   assert.equal(run('writes.some(p=>p.op===7&&p.payload[2]!==1)'),false);assert.equal(run('dataOperation'),null);
 });
 await test('cancel during remapping sends no score rows and restores mapping',async()=>{
   ready();const old=JSON.parse(run('JSON.stringify(map)'));
   run(`setScore({...${doc('cancel-mapping')},mapping:Array.from({length:25},(_,i)=>35+i)});`);
   const upload=track(run('upload()'));await until(()=>run('writes.some(p=>p.op===5)'));
   run('cancelDataOperation()');await assert.rejects(upload,/取消/);
   assert.equal(run('writes.some(p=>p.op===6||(p.op===7&&p.payload[2]!==1))'),false);
   assert.deepEqual(JSON.parse(run('JSON.stringify(map)')),old);
 });
 await test('direct upload probes capability, preserves keys and commits format2',async()=>{
   ready();run(`setScore({version:2,playback:'direct',title:'direct',rows:[{deltaMs:0,midi:0,velocity:100,on:1},{deltaMs:50,midi:0,velocity:0,on:0}]})`);
   await run('upload()');
   assert.equal(run('writes[0].op'),8);assert.equal(run('writes[0].payload[0]'),3);
   assert.equal(run('writes.some(p=>p.op===5)'),false);
   assert.equal(run('writes.filter(p=>p.op===6).every(p=>p.payload[9]===1)'),true);
   assert.equal(run('writes.at(-1).payload[2]'),2);
 });
 await test('old mapping restoration never writes to a reconnected session',async()=>{
   ready();run(`setScore({...${doc('reconnect-mapping')},mapping:Array.from({length:25},(_,i)=>30+i)});`);
   const upload=track(run('upload()'));await until(()=>run('writes.some(p=>p.op===5)'));
   run("lost('test reconnect')");ready();await assert.rejects(upload,/reconnect|连接|关闭/);await flush();
   assert.equal(run('writes.length'),0);assert.equal(run('controlReady'),true);
 });
 console.log(JSON.stringify({Passed:passed,Failed:failed,HardwareTested:false}));if(failed)process.exitCode=1;
}
main().catch(e=>{console.error(e);process.exitCode=1;});
