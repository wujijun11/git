"use strict";
const assert = require("node:assert/strict");
const P = require("../web/protocol.js");
const { NeonController, createDemoTransport } = require("../web/controller.js");
const { LearningControl } = require("../web/learning-control.js");
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const row = (key, on, deltaMs) => ({ key, on, deltaMs, velocity: on ? 100 : 0 });

async function main() {
    const idle = [1, 33, 0, 0, 0, 0, 0, 0, 0, 0];
    assert.equal(P.learningStatus(idle).active, false);
    for (const bad of [[0, ...idle.slice(1)], [1, 97, ...idle.slice(2)],
        [1, 47, 0, 0, 1, 0, 0, 0, 0, 0], [1, 41, 0, 0, 1, 0, 0, 0, 0, 0]])
        assert.throws(() => P.learningStatus(bad));
    const transport = createDemoTransport();
    const controller = new NeonController({ heartbeatMs: 0 });
    await controller.connect(transport, "demo");
    const score = {version: 1, title: "重复音与和弦", rows: [row(0,1,0), row(0,0,50),
        row(0,1,50), row(0,0,50), row(2,1,50), row(4,1,0), row(7,1,0)]};
    let latest, generation = 0;
    const lesson = new LearningControl({ controller, getScore: () => score,
        getGeneration: () => generation, prepareScore: value => controller.uploadScore(value),
        runExclusive: fn => fn(), onStatus: status => { latest = status; }, onError: e => { throw e; } });
    assert.equal(await lesson.toggle(), true);
    assert.equal(latest.targetMask, 1);
    await delay(300);
    assert.equal((await controller.readLearningStatus()).completedSteps, 0);
    await controller.noteOn("wrong", 61, 100, 2);
    assert.equal((await controller.readLearningStatus()).completedSteps, 0);
    await controller.noteOff("wrong");
    await controller.noteOn("a", 60, 100, 2);
    assert.equal((await controller.readLearningStatus()).completedSteps, 1);
    assert.equal((await controller.readLearningStatus()).waitingRelease, true);
    await controller.noteOff("a");
    await controller.noteOn("b", 60, 100, 2);
    await controller.noteOff("b");
    for (const note of [62,64]) await controller.noteOn("c"+note, note, 100, 2);
    assert.equal((await controller.readLearningStatus()).completedSteps, 2);
    await controller.noteOn("c67",67,100,2);
    assert.equal((await controller.readLearningStatus()).finished, true);
    for (const note of [62,64,67]) await controller.noteOff("c"+note);
    await delay(220);
    assert.equal(latest.completedSteps, 3);
    // 空闲才查询，忙的时候不能积累新的状态请求。
    const before = transport.requests.length;
    controller._ctx.running = true;
    assert.equal(await controller.readLearningStatusIfIdle(), null);
    controller._ctx.running = false;
    assert.equal(transport.requests.length, before);
    assert.equal(await lesson.toggle(), true);
    assert.equal(await lesson.toggle(), false);
    lesson.cancel();
    await controller.disconnect();
    // 旧固件NACK应在上传前解释，并禁止发出启动命令。
    let uploaded = false, actions = [];
    const old = new LearningControl({controller: {ready:true, readLearningStatus: async () => {throw Error("FPGA NACK status=1");}},
        getScore:()=>score,getGeneration:()=>0,prepareScore:async()=>{uploaded=true;},runExclusive:fn=>fn()});
    await assert.rejects(old.toggle(), /LearningMode/);
    assert.equal(uploaded,false);
    // 准备期间取消不可在随后偷偷启动学习。
    const fake = {ready:true, telemetry:{},readLearningStatus:async()=>({active:false}),readStatus:async()=>{},transportAction:async a=>actions.push(a)};
    const cancelled = new LearningControl({controller:fake,getScore:()=>score,getGeneration:()=>generation,
        prepareScore:async()=>{generation++;},runExclusive:fn=>fn()});
    await assert.rejects(cancelled.toggle(),/取消/);
    assert.deepEqual(actions,[]);
    console.log("LEARNING DESKTOP PASS: strict protocol, wait/repeat/chord, EOF, polling, restart/stop, old firmware and cancellation");
}
main().catch(error=>{console.error(error);process.exitCode=1;});
