"use strict";
// 可控单调时钟与ACK边界，测试真实调度行为，不打开硬件。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const R = require("../web/realtime-score.js");
const note = (midi, on, deltaMs = 0) => ({ midi, on, deltaMs, velocity: on ? 90 : 0 });
const doc = rows => ({ version: 2, playback: "direct", rows });
const tick = () => new Promise(resolve => setImmediate(resolve));

async function main() {
    let time = 0, released = 0;
    const sent = [], states = [];
    const player = new R.Player({
        now: () => time,
        setTimer: (callback, delay) => { time += delay; queueMicrotask(callback); return 1; },
        clearTimer: () => {},
        send: async event => { sent.push({ ...event, at: time }); time += 7; },
        release: async () => { released++; },
        onState: state => states.push(state),
    });
    const result = await player.start(doc([note(60, 1), note(60, 0, 100), note(62, 1, 100), note(62, 0, 100)]));
    assert.deepEqual(sent.map(x => x.at), [0, 100, 200, 300], "ACK耗时不能累加到节拍");
    assert.equal(result.completed, 4);
    assert.equal(result.maxLateMs, 7);
    assert.equal(released, 1);
    assert.equal(states.at(-1).state, "finished");

    // 和弦相同时间戳按原顺序发送，确认没有静默删短音或增添额外间隔。
    sent.length = 0;
    const base = time;
    await player.start(doc([note(60, 1), note(64, 1), note(67, 1), note(60, 0, 100), note(64, 0), note(67, 0)]));
    assert.deepEqual(sent.map(x => x.midi), [60, 64, 67, 60, 64, 67]);
    assert.deepEqual(sent.slice(0, 3).map(x => x.at - base), [0, 7, 14]);

    // NOTE ON正在等待ACK时停止：未来音符不发送，ACK后才清理；多次停止复用任务。
    let ack, cleanup = 0, pending = [];
    const slow = new R.Player({
        send: event => { pending.push(event); return new Promise(resolve => { ack = resolve; }); },
        release: async () => { cleanup++; },
    });
    const running = slow.start(doc([note(60, 1), note(60, 0, 1000)]));
    await tick();
    const stopping = slow.stop(); slow.stop();
    assert.equal(cleanup, 0);
    assert.throws(() => slow.start(doc([note(62, 1), note(62, 0)])), /停止中/);
    ack();
    assert.equal((await running).stopped, true); await stopping;
    assert.equal(pending.length, 1); assert.equal(cleanup, 1);

    // 提前停止长休止符必须立即唤醒，不等待下一个音符的定时器。
    let future = 0;
    const resting = new R.Player({ send: async () => { future++; }, release: async () => {} });
    const rest = resting.start(doc([note(60, 1, 60000), note(60, 0, 100)]));
    await tick(); await resting.stop(); await rest;
    assert.equal(future, 0);

    // 传输跟不上时明确失败并清理；不把整首曲子排队，也不“补弹”后面的事件。
    time = 0; pending = []; cleanup = 0;
    const overloaded = new R.Player({ now: () => time, maxLateMs: 250,
        send: async event => { pending.push(event); time += 300; },
        release: async () => { cleanup++; } });
    await assert.rejects(overloaded.start(doc([note(60, 1), note(60, 0, 10)])), /落后/);
    assert.equal(pending.length, 1); assert.equal(cleanup, 1); assert.equal(overloaded.busy, false);

    const broken = new R.Player({ send: async () => { throw Error("断线"); }, release: async () => { cleanup++; } });
    await assert.rejects(broken.start(doc([note(60, 1), note(60, 0)])), /断线/);
    assert.equal(cleanup, 2);
    const long = doc(Array.from({ length: 1200 }, (_, i) => note(60 + Math.floor(i / 2) % 30, i % 2 === 0 ? 1 : 0, 1)));
    assert.equal(R.validate(long).rows.length, 1200);
    sent.length = 0; time = 0;
    const completeLong = doc(long.rows.map(event => ({ ...event, deltaMs: 10 })));
    assert.equal((await player.start(completeLong)).completed, 1200);
    assert.equal(sent.length, 1200, "长曲谱应完整发送每条事件");
    const tooMany = doc(Array.from({ length: 65 }, (_, midi) => note(midi, 1)));
    assert.throws(() => R.validate(tooMany), /超过64/);
    assert.throws(() => R.validate(doc([note(60, 1)])), /结尾/);
    assert.throws(() => R.validate(doc([note(60, 0)])), /没有对应/);
    assert.throws(() => R.validate(doc([note(60, 1), note(60, 1)])), /重叠/);
    const keyScore = { version: 1, rows: [{ ...note(0, 1), key: 0 }, { ...note(0, 0, 100), key: 0 }] };
    const mapping = Array.from({ length: 25 }, (_, i) => i + 60);
    const snapshot = R.validate(keyScore, mapping); mapping[0] = 99;
    assert.equal(snapshot.rows[0].midi, 60);
    assert.equal(fs.readFileSync(path.resolve(__dirname, "../web/realtime-score.js"), "utf8"),
        fs.readFileSync(path.resolve(__dirname, "../../mobile/web/realtime-score.js"), "utf8"));
    console.log("REALTIME SCORE PASS: absolute timing, chord order, stop/ACK, rests, overload, disconnect, long score, mapping snapshot, shared source");
}
main().catch(error => { console.error(error); process.exitCode = 1; });
