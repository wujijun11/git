'use strict';
// Executable UI-controller test with a minimal DOM. This checks app workflows,
// not WebView rendering or hardware BLE compatibility.
const assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
class Element{
  constructor(value=''){this.value=value;this.children=[];this.textContent='';const classes=new Set();this.classList={add:c=>classes.add(c),remove:c=>classes.delete(c)};}
  append(e){this.children.push(e);}setPointerCapture(){}click(){if(this.onclick)this.onclick();}
}
const elements=new Map(),defaults={timbre:'2',effect:'0',velocity:'100',gain:'2048',bend:'0',vibrato:'0',mapKey:'0',mapNote:'60'};
for(const id of fs.readFileSync(path.join(__dirname,'../web/index.html'),'utf8').matchAll(/id="([^"]+)"/g))elements.set(id[1],new Element(defaults[id[1]]||''));
const storage=new Map(),windowEvents=new Map(),documentEvents=new Map(),intervals=[],context={console,setTimeout,clearTimeout,setInterval:fn=>{intervals.push(fn);return intervals.length;},performance,Blob,URL,navigator:{},isSecureContext:true,addEventListener:(name,fn)=>windowEvents.set(name,fn),localStorage:{getItem:k=>storage.get(k),setItem:(k,v)=>storage.set(k,v)},document:{hidden:false,getElementById:id=>elements.get(id),createElement:()=>new Element(),addEventListener:(name,fn)=>documentEvents.set(name,fn)}};context.window=context;context.globalThis=context;vm.createContext(context);
// 加载真实页面依赖，模拟器与异步工作流测试才能覆盖当前版本。
for(const file of ['protocol.js','realtime-score.js','realtime-playback.js','app.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../web',file),'utf8'),context,{filename:file});
// Low-level fixtures exercise post-handshake workflows without repeating setup.
vm.runInContext('function createReadySession(...args){const owner=createSession(...args);setControlReady(true);return owner;}',context);
const run=code=>vm.runInContext(code,context),delay=ms=>new Promise(r=>setTimeout(r,ms));
async function until(fn){for(let i=0;i<100;i++){if(fn())return;await delay(10);}throw new Error('workflow timed out');}
class BleEvents{
  constructor(){this.listeners=new Map();}
  addEventListener(name,fn){if(!this.listeners.has(name))this.listeners.set(name,new Set());this.listeners.get(name).add(fn);}
  removeEventListener(name,fn){if(this.listeners.has(name))this.listeners.get(name).delete(fn);}
  emit(name,event={}){for(const fn of this.listeners.get(name)||[])fn(event);}
  listener(name){return Array.from(this.listeners.get(name)||[])[0];}
}
function fakeBleDevice(){
  const device=new BleEvents(),notify=new BleEvents(),writes=[];
  const mock=run('new Simulator()');
  mock.deliver=bytes=>notify.emit('characteristicvaluechanged',{target:{value:new DataView(Uint8Array.from(bytes).buffer)}});
  notify.startNotifications=()=>Promise.resolve(notify);
  const characteristic={writeValueWithResponse:bytes=>{writes.push(Array.from(bytes));return mock.write(bytes);}};
  const server={getPrimaryService:()=>Promise.resolve({getCharacteristic:uuid=>Promise.resolve(uuid===run('P.UUID.rx')?characteristic:notify)})};
  device.gatt={connected:false,connect(){this.connected=true;return Promise.resolve(server);},disconnect(){this.connected=false;device.emit('gattserverdisconnected');}};
  return {device,notify,writes,mock,server};
}
async function main(){
  assert.equal(elements.get('keys').children.length,25);assert.equal(elements.get('mapKey').children.length,25);assert.match(elements.get('capability').textContent,/不支持 Web Bluetooth/);
  elements.get('simulate').click();await until(()=>elements.get('status').textContent.includes('模拟已连接'));assert.equal(run('isMock'),true);
  context.scoreFixture=JSON.parse(fs.readFileSync(path.join(__dirname,'../examples/score.json'),'utf8'));await run('setScore(scoreFixture); upload()');assert.match(elements.get('scoreInfo').textContent,/已提交 8/);
  elements.get('mapKey').value='24';elements.get('mapNote').value='100';elements.get('mapApply').click();await until(()=>run('map[24]')===100);assert.match(elements.get('keys').children[24].textContent,/MIDI 100/);
  await run('command(4,[4]);');await run('command(4,[2]);');const key=elements.get('keys').children[24],e={preventDefault(){},pointerId:1};key.onpointerdown(e);await until(()=>run('session.pending')===null);await delay(20);key.onpointerup(e);await until(()=>run('session.pending')===null);await run('readRecording()');
  const rows=JSON.parse(run('JSON.stringify(recorded)'));assert.equal(rows.length,2);assert.equal(rows[0].midi,100);assert.equal(rows[0].on,1);assert.equal(rows[1].on,0);assert.equal(rows[0].source,63);assert.ok(rows[1].deltaMs>=15);
  let exported;context.AndroidBle={exportJson:j=>exported=j};run('exportRecording()');assert.equal(JSON.parse(exported).rows.length,2);delete context.AndroidBle;
  await assert.rejects(run('command(4,[8])'),/NACK status=1/); // phone-source recording is exportable, not physical replay
  // These simulator states must follow the RTL recorder and allocator, rather
  // than allowing tests to pass against stale events or a zero-velocity voice.
  await run('command(4,[2]);readback(0)');assert.equal(run('telemetryState.recordCount'),0);
  await run('command(1,P.note(60,100,0,1));command(1,P.note(60,0,0,1));readback(0)');
  assert.equal(run('telemetryState.activeVoices'),0);assert.equal(run('telemetryState.recordCount'),2);
  await run('command(4,[5]);readback(0)');assert.equal(run('telemetryState.recording'),false);
  await run('command(4,[4])');await assert.rejects(run('command(4,[8])'),/NACK status=1/);
  await run('test64()');assert.equal(run('telemetryState.activeVoices'),64);assert.match(elements.get('status').textContent,/协议模拟/);
  elements.get('panic').click();await until(()=>run('testActive')===false&&run('session.pending')===null);await run('readback(0)');assert.equal(run('telemetryState.activeVoices'),0);
  const pendingTest=run('test64()');elements.get('panic').click();await pendingTest;await delay(30);await run('readback(0)');assert.equal(run('telemetryState.activeVoices'),0);
  await run('command(7,[0,0,1]);command(4,[6]);');await run('readback(0)');assert.equal(run('telemetryState.guide'),true);await run('command(4,[7]);');await run('readback(0)');assert.equal(run('telemetryState.guide'),false);
  // Slow GATT writes: hundreds of drag events must coalesce, while still
  // transmitting before onchange and preserving the final slider snapshot.
  await run(`disconnect();`);
  run(`globalThis.uiWrites=[];globalThis.uiMock=new Simulator();createReadySession(b=>{
    uiWrites.push({packet:P.decode(b),time:performance.now()});
    return new Promise(resolve=>setTimeout(()=>{uiMock.write(b).then(resolve);},100));
  },true);uiMock.deliver=b=>decoder&&decoder.push(b);`);
  elements.get('gain').value='2000';elements.get('gain').oninput();
  for(let i=0;i<300;i++){elements.get('gain').value=String(2001+i);elements.get('gain').oninput();}
  elements.get('gain').value='4095';elements.get('gain').oninput();
  await until(()=>run('expressionControl && !expressionControl.sending && !expressionControl.pending'));
  const expressionWrites=JSON.parse(run('JSON.stringify(uiWrites)'));
  assert.equal(expressionWrites.length,2);assert.equal(expressionWrites[0].packet.op,2);
  assert.equal(expressionWrites[0].packet.payload[0],1);assert.equal(expressionWrites[1].packet.payload[0],1);
  assert.equal(expressionWrites[1].packet.payload[1]+256*expressionWrites[1].packet.payload[2],4095);
  assert.ok(expressionWrites[1].time-expressionWrites[0].time>=39);
  assert.equal(run('session.queue.length'),0);
  // Coalesce independent changed fields, without clobbering the physical bend.
  run('uiWrites=[]');elements.get('gain').value='3000';elements.get('gain').oninput();
  elements.get('vibrato').value='30';elements.get('vibrato').oninput();
  elements.get('gain').value='3100';elements.get('gain').oninput();
  await until(()=>run('expressionControl && !expressionControl.sending && !expressionControl.pending'));
  assert.equal(run('uiWrites[uiWrites.length-1].packet.payload[0]'),5);
  assert.equal(run('uiWrites[uiWrites.length-1].packet.payload[5]'),30);
  // 上传期间拒绝换谱，保证只发送冻结的原曲谱，不混入第二份文档。
  run(`globalThis.scoreWrites=[];globalThis.scoreMock=new Simulator();createReadySession(b=>{
    scoreWrites.push(P.decode(b));return scoreMock.write(b);
  },true);scoreMock.deliver=b=>decoder&&decoder.push(b);setScore(scoreFixture);`);
  const snapshotUpload=run('upload()');
  assert.throws(()=>run('setScore({version:1,title:"new",rows:[{deltaMs:0,key:24,velocity:1,on:1}]})'),/正在上传/);
  await snapshotUpload;
  const uploaded=JSON.parse(run('JSON.stringify(scoreWrites)'));
  assert.equal(uploaded.filter(p=>p.op===6).length,8);
  assert.equal(uploaded.at(-1).op,7);assert.equal(uploaded.at(-1).payload[0],8);
  // Replace the session immediately after STOP ACK, before upload's awaited
  // continuation. No old SCORE_WRITE may enter the new session.
  run(`globalThis.newSessionWrites=[];setScore(scoreFixture);createReadySession(b=>{
    const q=P.decode(b),old=session;
    setTimeout(()=>{old.receive(P.decode(P.encode(q.seq,128,[q.op,0])));
      createReadySession(bytes=>{newSessionWrites.push(P.decode(bytes));return Promise.resolve();});
    },10);return Promise.resolve();
  });`);
  await assert.rejects(run('upload()'),/连接已变化/);
  assert.equal(run('newSessionWrites.length'),0);
  run(`createReadySession(b=>{const q=P.decode(b),old=session;
    setTimeout(()=>{old.receive(P.decode(P.encode(q.seq,128,[q.op,0])));
      createReadySession(bytes=>{newSessionWrites.push(P.decode(bytes));return Promise.resolve();});
    },10);return Promise.resolve();
  });`);
  await assert.rejects(run('readRecording()'),/连接已变化/);
  assert.equal(run('newSessionWrites.length'),0);
  // An old ACK may resolve immediately before replacement. Old map, Panic and
  // clear-record continuations must not commit UI state into the new session.
  for(const action of ['mapApply','panic','recordClear']){
    run(`createReadySession(b=>{const q=P.decode(b),old=session;
      setTimeout(()=>{old.receive(P.decode(P.encode(q.seq,128,[q.op,0])));
        createReadySession(()=>Promise.resolve());held.set(0,{midi:88,owner:session});recorded=[{midi:88}];
      },10);return Promise.resolve();
    });`);
    const oldMap=run('map[0]');elements.get('mapKey').value='0';elements.get('mapNote').value='90';
    elements.get(action).click();await until(()=>run('held.size')===1);await delay(5);
    assert.equal(run('map[0]'),oldMap);assert.equal(run('held.size'),1);assert.equal(run('recorded[0].midi'),88);
  }
  // A scheduled trailing expression is cancelled on connection loss.
  run(`globalThis.dragOwner=session;globalThis.dragWrites=[];createReadySession(b=>{
    dragWrites.push(P.decode(b));const q=P.decode(b),owner=session;
    setTimeout(()=>owner.receive(P.decode(P.encode(q.seq,128,[q.op,0]))),100);
    return Promise.resolve();
  });`);
  elements.get('bend').value='100';elements.get('bend').oninput();
  elements.get('bend').value='200';elements.get('bend').oninput();
  run('lost("test disconnect");createReadySession(b=>{newSessionWrites.push(P.decode(b));return Promise.resolve();});');
  await delay(160);assert.equal(run('newSessionWrites.length'),0);
  // Losing window focus releases a held phone note even without visibilitychange.
  run(`globalThis.blurMock=new Simulator();createReadySession(b=>blurMock.write(b),true);blurMock.deliver=b=>decoder&&decoder.push(b);`);
  key.onpointerdown(e);await until(()=>run('session.pending')===null);windowEvents.get('blur')();
  await until(()=>run('session.pending')===null);await run('readback(0)');
  assert.equal(run('held.size'),0);assert.equal(run('telemetryState.activeVoices'),0);
  // Duplicate mappings share one source/pitch in the FPGA. Release only when
  // the last pointer holding that pitch is released; unrelated pointers cannot
  // lift another finger's key, and remapping preserves the original OFF pitch.
  run(`globalThis.duplicateWrites=[];globalThis.duplicateMock=new Simulator();createReadySession(b=>{
    duplicateWrites.push(P.decode(b));return duplicateMock.write(b);
  },true);duplicateMock.deliver=b=>decoder&&decoder.push(b);map[23]=map[24];`);
  const otherKey=elements.get('keys').children[23],e2={preventDefault(){},pointerId:2};
  key.onpointerdown(e);otherKey.onpointerdown(e2);await until(()=>run('session.pending')===null);
  assert.equal(run('duplicateWrites.filter(q=>q.op===1&&q.payload[4]).length'),1);
  key.onpointerup(e2);assert.equal(run('held.size'),2);
  key.onpointerup(e);await run('readback(0)');assert.equal(run('telemetryState.activeVoices'),1);
  run('map[23]=101');otherKey.onlostpointercapture(e2);await until(()=>run('session.pending')===null);
  await run('readback(0)');assert.equal(run('telemetryState.activeVoices'),0);
  assert.equal(run('duplicateWrites.filter(q=>q.op===1&&!q.payload[4]).length'),1);
  assert.equal(run('duplicateWrites.find(q=>q.op===1&&!q.payload[4]).payload[1]'),100);
  // A failed initial Panic must leave the diagnostic idle, without any NOTE.
  run(`globalThis.failedTestWrites=[];createReadySession(b=>{const q=P.decode(b),owner=session;
    failedTestWrites.push(q);setTimeout(()=>owner.receive(P.decode(P.encode(q.seq,128,[q.op,1]))),5);
    return Promise.resolve();});`);
  await assert.rejects(run('test64()'),/NACK status=1/);
  assert.equal(run('testActive'),false);assert.equal(run('failedTestWrites.some(q=>q.op===1)'),false);
  // Real browser transport callbacks must belong to their originating device.
  // Invoking callbacks already queued before listener removal cannot affect B.
  const bleA=fakeBleDevice(),bleB=fakeBleDevice();let chosen=bleA.device;
  context.navigator.bluetooth={requestDevice:()=>Promise.resolve(chosen)};
  await run('connectWeb()');const ownerA=run('session');
  const oldNotify=bleA.notify.listener('characteristicvaluechanged'),oldDisconnect=bleA.device.listener('gattserverdisconnected');
  chosen=bleB.device;await run('connectWeb()');const ownerB=run('session');assert.notEqual(ownerA,ownerB);
  assert.equal(bleA.device.gatt.connected,false);assert.equal(bleA.notify.listeners.get('characteristicvaluechanged').size,0);
  const beforeTelemetry=run('JSON.stringify(telemetryState)');
  const stalePacket=run('P.encode(99,129,[55,0,0,0,0,0,0,0,0,0])');
  oldNotify({target:{value:new DataView(Uint8Array.from(stalePacket).buffer)}});oldDisconnect();
  assert.equal(run('session'),ownerB);assert.equal(run('JSON.stringify(telemetryState)'),beforeTelemetry);
  await run('readback(0)');assert.equal(run('telemetryState.activeVoices'),0);
  // A fast RF reconnect can precede the hardware source-63 expiry. Retained
  // voices must be cleared by setup Panic before keys or heartbeat can send.
  run('lost("RF dropped")');bleB.mock.notes.add(61);bleB.writes.length=0;
  const reconnect=run('connectWeb()');await until(()=>run('session')!==null);
  assert.equal(run('controlReady'),false);
  for(const id of ['timbre','effect','gain','bend','vibrato','mapKey','mapNote','mapApply'])assert.equal(elements.get(id).disabled,true);
  assert.equal(key.disabled,true);
  key.onpointerdown(e);elements.get('gain').oninput();for(const tick of intervals)tick();
  await assert.rejects(run('command(1,P.note(72,100,0,1))'),/握手尚未完成/);
  assert.equal(run('held.size'),0);await reconnect;
  const setupPackets=bleB.writes.map(b=>run('P.decode')(Uint8Array.from(b)));
  assert.equal(setupPackets[0].op,8);assert.equal(setupPackets[1].op,4);assert.equal(setupPackets[1].payload[0],5);
  assert.equal(setupPackets.some(p=>p.op===1),false);
  assert.equal(setupPackets.filter(p=>p.op===8).length,4); // 状态、模式、延音能力和最终状态；没有心跳插队。
  assert.equal(setupPackets.filter(p=>p.op===8 && p.payload[0]===5).length,1);
  assert.equal(bleB.mock.notes.size,0);assert.equal(run('controlReady'),true);
  for(const id of ['timbre','effect','gain','bend','vibrato','mapKey','mapNote','mapApply'])assert.equal(elements.get(id).disabled,false);
  assert.equal(key.disabled,false);
  key.onpointerdown(e);await until(()=>run('session.pending')===null);
  assert.equal(bleB.mock.notes.size,1);key.onpointerup(e);await until(()=>run('session.pending')===null);
  assert.equal(bleB.mock.notes.size,0);
  // Cancelling an unresolved chooser must not create a session on late resolve.
  await run('disconnect()');let resolveChooser;
  context.navigator.bluetooth.requestDevice=()=>new Promise(resolve=>resolveChooser=resolve);
  const cancelledChooser=run('connectWeb()');await until(()=>!!resolveChooser);
  await run('disconnect()');resolveChooser(fakeBleDevice().device);await cancelledChooser;
  assert.equal(run('session'),null);assert.equal(run('webConnection'),null);
  // A late discovery completion is also disposed, without starting a handshake.
  const lateBle=fakeBleDevice();let resolveConnect;
  lateBle.device.gatt.connect=()=>new Promise(resolve=>resolveConnect=()=>{lateBle.device.gatt.connected=true;resolve(lateBle.server);});
  context.navigator.bluetooth.requestDevice=()=>Promise.resolve(lateBle.device);
  const cancelledDiscovery=run('connectWeb()');await until(()=>!!resolveConnect);
  await run('disconnect()');resolveConnect();await cancelledDiscovery;
  assert.equal(run('session'),null);assert.equal(lateBle.device.gatt.connected,false);assert.equal(lateBle.writes.length,0);
  delete context.navigator.bluetooth;
  await assert.rejects(run('connectWeb()'),/不提供 Web Bluetooth/);assert.equal(run('session'),null);
  await assert.rejects(run('test64()'),/请先连接/);assert.equal(run('testActive'),false);
  console.log('ALL MOBILE UI SIMULATION TESTS PASSED (25 maps, duplicate pitch/pointer release, score snapshot/session isolation, expression coalescing/continuous/final value, disconnect/chooser/discovery cancellation, stale browser callbacks, fast reconnect Panic before key/slider/heartbeat, blur release, record readback/export, replay limits,64voice test/cancel/failure,guide, capability)');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
