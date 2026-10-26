'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const P=require('../web/protocol.js');
const delay=ms=>new Promise(r=>setTimeout(r,ms));
async function main(){
  assert.equal(P.crc8(Buffer.from('123456789')),0xf4);
  for(let i=0;i<1000;i++){const payload=Array.from({length:10},(_,b)=>(i*17+b*31)&255),a=P.encode(i&255,(i*13)&255,payload),q=P.decode(a);assert.equal(q.seq,i&255);assert.equal(q.op,(i*13)&255);assert.deepEqual(q.payload,payload);a[7]^=1;assert.throws(()=>P.decode(a));}
  assert.throws(()=>P.encode(256,1));assert.throws(()=>P.encode(1,1,[0,0,0,0,0,0,0,0,0,0,0]));
  assert.deepEqual(P.note(60,100,2,true),[63,60,100,2,1]);assert.deepEqual(P.expression(2048,-100,12),[7,0,8,156,255,12]);
  assert.deepEqual(P.scoreRow(257,{deltaMs:0x12345678,key:24,velocity:127,on:1}),[1,1,120,86,52,18,24,127,1]);
  const example=JSON.parse(fs.readFileSync(path.join(__dirname,'../examples/score.json'),'utf8'));assert.equal(P.validateScore(example).rows.length,8);
  for(const bad of [{version:2,rows:[]},{version:1,rows:[]},{version:1,rows:[{deltaMs:-1,key:0,velocity:0,on:1}]},{version:1,rows:[{deltaMs:0,key:25,velocity:0,on:1}]},{version:1,rows:[{deltaMs:0,key:1.2,velocity:0,on:1}]},{version:1,rows:[{deltaMs:0,key:0,velocity:128,on:1}]},{version:1,rows:[{deltaMs:0,key:0,velocity:0,on:2}]}])assert.throws(()=>P.validateScore(bad));
  assert.equal(P.validateScore({...example,rows:Array(1024).fill(example.rows[0])}).rows.length,1024);
  assert.throws(()=>P.validateScore({...example,rows:Array(1025).fill(example.rows[0])}));
  assert.throws(()=>P.validateScore({...example,rows:Array(257).fill(example.rows[0])},256));
  assert.deepEqual(P.telemetry([16,15,0,4,120,86,52,18,255,0]),{activeVoices:16,playing:true,recording:true,guide:true,overflow:true,recordCount:1024,audioUnderruns:0x12345678,scorePosition:255});
  assert.deepEqual(P.event([1,4,120,86,52,18,63,127,100,7]),{index:1025,deltaMs:0x12345678,source:63,midi:127,velocity:100,on:1,timbre:3});
  const seen=[],decoder=new P.StreamDecoder(q=>seen.push(q));const valid=P.encode(4,1,[63,60,100,1,1]),bad=valid.slice();bad[15]^=1;
  const stream=Uint8Array.from([9,8,165,...bad,...valid,...P.encode(5,8,[0])]);
  for(let i=0;i<stream.length;i+=3)decoder.push(stream.slice(i,i+3));assert.deepEqual(seen.map(q=>q.seq),[4,5]);assert.equal(decoder.errors,1);
  // A consumer failure is not a corrupt frame. Surface it without discarding
  // the following valid packet or counting it as a CRC failure.
  const callbackPackets=[];const callbackFailure=new P.StreamDecoder(q=>{callbackPackets.push(q.seq);if(q.seq===4)throw new Error('consumer failed');});
  assert.throws(()=>callbackFailure.push(Uint8Array.from([...valid,...P.encode(5,8,[0])])),/consumer failed/);
  callbackFailure.push([]);assert.deepEqual(callbackPackets,[4,5]);assert.equal(callbackFailure.errors,0);
  // Drop first ACK. Both attempts must be byte-identical and only one request
  // can be outstanding. Then exercise sequence wrap and NACK continuation.
  let session,writes=[],applied=0,lastSeq=null;
  session=new P.Session(async bytes=>{const q=P.decode(bytes);writes.push(Buffer.from(bytes));if(lastSeq!==q.seq){lastSeq=q.seq;applied++;}if(writes.length===1)return;setTimeout(()=>session.receive(P.decode(P.encode(q.seq,128,[q.op,q.op===3?2:0]))),1);},{timeoutMs:15,retries:2,startSeq:255});
  const a=session.send(1,[63,60,100,0,1]),b=session.send(2,P.expression(2048,0,0));assert.equal((await a).seq,255);assert.equal((await b).seq,0);assert.equal(applied,2);assert.deepEqual(writes[0],writes[1]);assert.equal(writes.length,3);
  await assert.rejects(session.send(3,[0,1]),/NACK status=2/);await session.send(4,[5]);session.close();await assert.rejects(session.send(1),/关闭/);
  // A UART ACK notification may arrive before the GATT write callback. Never
  // launch the next GATT operation until both conditions have completed.
  let slow,activeWrites=0,maxWrites=0;
  slow=new P.Session(async bytes=>{activeWrites++;maxWrites=Math.max(maxWrites,activeWrites);const q=P.decode(bytes);slow.receive(P.decode(P.encode(q.seq,128,[q.op,0])));await delay(5);activeWrites--;});
  await Promise.all([slow.send(1),slow.send(2),slow.send(3)]);assert.equal(maxWrites,1);slow.close();
  let fatal=0;const exhausted=new P.Session(async()=>{}, {timeoutMs:5,retries:1,onFatal:()=>fatal++});await assert.rejects(exhausted.send(1),/ACK 超时/);assert.equal(fatal,1);assert.ok(exhausted.closed);
  const closed=new P.Session(async()=>{}, {timeoutMs:100});const promises=[closed.send(1),closed.send(2)].map(p=>assert.rejects(p,/测试关闭/));closed.close(new Error('测试关闭'));await Promise.all(promises);
  // A stuck transport write must close the session, including when an ACK
  // arrived early. Never retry or pump another GATT operation while it hangs.
  for(const earlyAck of [false,true]){
    let stuck,completeWrite,stuckWrites=0,stuckFatal=0;
    stuck=new P.Session(bytes=>{stuckWrites++;const q=P.decode(bytes);if(earlyAck)stuck.receive(P.decode(P.encode(q.seq,128,[q.op,0])));return new Promise(resolve=>completeWrite=resolve);},{writeTimeoutMs:10,timeoutMs:5,retries:2,onFatal:()=>stuckFatal++});
    const blocked=[stuck.send(1),stuck.send(2)].map(p=>p.catch(e=>e.message));
    await delay(30);assert.ok(stuck.closed,'a transport write must have its own deadline');
    assert.ok((await Promise.all(blocked)).every(e=>/写入超时/.test(e)));assert.equal(stuckFatal,1);assert.equal(stuckWrites,1);
    completeWrite();await delay(2);assert.equal(stuckWrites,1);assert.equal(stuckFatal,1);
  }
  let closeFatal=0;const cancelledWrite=new P.Session(()=>new Promise(()=>{}),{writeTimeoutMs:5,onFatal:()=>closeFatal++});
  const cancelled=assert.rejects(cancelledWrite.send(1),/主动取消/);cancelledWrite.close(new Error('主动取消'));await cancelled;await delay(15);assert.equal(closeFatal,0);
  // Capture queued payloads at send time; bad requests must reject before they
  // can poison the queue or consume the next sequence number.
  let queued,releaseFirst;const queueWrites=[];
  queued=new P.Session(bytes=>{const q=P.decode(bytes);queueWrites.push(q);queued.receive(P.decode(P.encode(q.seq,128,[q.op,0])));return queueWrites.length===1?new Promise(r=>releaseFirst=r):Promise.resolve();});
  const first=queued.send(4,[5]),payload=[63,60,100,0,1],second=queued.send(1,payload);payload[1]=72;
  await assert.rejects(queued.send(1,[256]),/payload/);await assert.rejects(queued.send(256),/op/);
  const third=queued.send(4,[5]);releaseFirst();await Promise.all([first,second,third]);
  assert.equal(queueWrites[1].payload[1],60);assert.deepEqual(queueWrites.map(q=>q.seq),[0,1,2]);queued.close();
  // Queue overflow has an explicit fatal/closed path, including pending notes.
  const overloaded=new P.Session(async()=>{}, {timeoutMs:100,onFatal:()=>fatal++});const pending=[];for(let i=0;i<130;i++)pending.push(overloaded.send(1).catch(e=>e.message));await Promise.all(pending);assert.ok(overloaded.closed);assert.equal(fatal,2);
  const java=fs.readFileSync(path.join(__dirname,'../android/app/src/main/java/cn/tangsynth/remote/Protocol.java'),'utf8');for(const id of Object.values(P.UUID))assert.ok(java.includes(id));const firmware=fs.readFileSync(path.join(__dirname,'../../firmware/ble_bridge/ble_bridge.ino'),'utf8');for(const id of Object.values(P.UUID))assert.ok(firmware.includes(id));
  assert.ok(fs.readFileSync(path.join(__dirname,'../android/app/build.gradle'),'utf8').includes("../../web"));
  await delay(2);console.log('ALL MOBILE PROTOCOL TESTS PASSED (CRC, framing, bounds, retry, seq wrap, queues, UUID parity)');
}
main().catch(e=>{console.error(e);process.exitCode=1;});
