"use strict";
// 软件协议与真实控制器测试；传输为替身，不扫描蓝牙或写板卡。
const assert=require('node:assert/strict');
const P=require('../web/protocol'),MobileP=require('../../mobile/web/protocol');
const {NeonController,createDemoTransport}=require('../web/controller');
const M=require('../../mobile/web/music/smf');
const score={version:2,playback:'direct',title:'30 pitches',rows:Array.from({length:30},(_,i)=>[
    {deltaMs:0,midi:30+i,velocity:96,on:1},{deltaMs:5,midi:30+i,velocity:0,on:0}]).flat()};
for(const api of [P,MobileP]){
    const got=api.validateScore(score);
    assert.equal(got.playback,'direct');assert(!got.mapping);
    assert.deepEqual(api.scoreRow(0,got.rows[0]),[0,0,0,0,0,0,30,96,1,1]);
    assert.throws(()=>api.validateScore({...score,mapping:Array(25).fill(60)}),/mapping/);
    assert.throws(()=>api.validateScore({...score,rows:[{deltaMs:0,midi:128,velocity:1,on:1}]}),/MIDI/);
    assert.throws(()=>api.scoreCapabilities([1,1,0,4,127,64,63,0,0,0]),/能力/);
}
const events=Array.from({length:30},(_,i)=>[
    {ms:i*10,track:0,type:'note',channel:0,midi:30+i,velocity:96,on:1},
    {ms:i*10+5,track:0,type:'note',channel:0,midi:30+i,velocity:0,on:0}]).flat();
const info={durationMs:300,tracks:[{index:0}],messages:events};
const converted=M.convert(info,'30 notes',{tracks:[0],endMs:300,direct:true});
assert.equal(converted.canUpload,true);assert.equal(converted.pitchCount,30);
assert.deepEqual(converted.score.rows,score.rows.map((r,i)=>({...r,deltaMs:i===0?0:5})));
assert.equal(M.convert(info,'legacy',{tracks:[0],endMs:300,compact:true}).canUpload,false);
(async()=>{
    const transport=createDemoTransport({latencyMs:1}),c=new NeonController({heartbeatMs:100000});
    await c.connect(transport);
    try{
        const initialMapping=c.mapping.slice();transport.requests.length=0;
        await c.uploadScore(score);
        assert.equal(transport.requests[0].op,P.OP.READBACK);
        assert.equal(transport.requests[0].payload[0],3);
        assert.equal(transport.requests.filter(q=>q.op===P.OP.SCORE_WRITE).length,60);
        assert.equal(transport.requests.at(-1).payload[2],2);
        assert.equal(transport.requests.some(q=>q.op===P.OP.MAP||q.op===P.OP.NOTE),false);
        assert.deepEqual(c.mapping,initialMapping);
        await assert.rejects(c.transportAction(6),/NACK/);
    }finally{await c.disconnect();}
    const old=createDemoTransport({latencyMs:1});let receiver=()=>{};
    const onBytes=old.onBytes.bind(old),write=old.write.bind(old);
    old.onBytes=fn=>{receiver=fn;return onBytes(fn);};
    old.write=async bytes=>{const q=P.decode(bytes);if(q.op===8&&q.payload[0]===3){old.requests.push(q);setTimeout(()=>receiver(P.encode(q.seq,128,[8,1])),1);return;}return write(bytes);};
    const legacy=new NeonController({heartbeatMs:100000});await legacy.connect(old);old.requests.length=0;
    try{
        await assert.rejects(legacy.uploadScore(score),/DirectScore/);
        assert.equal(old.requests.length,1,'unsupported probe must not stop, remap or overwrite old score');
        assert.equal(legacy.ready,true);
    }finally{await legacy.disconnect();}
    console.log('DIRECT SCORE CLIENT PASS full pitches, mobile parity, format, capacity, read-only capability, no remapping, upload, legacy safety');
})().catch(error=>{console.error(error);process.exitCode=1;});
