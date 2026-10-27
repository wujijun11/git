"use strict";
// 真实控制器与模拟FPGA：原生租用期间零交错请求，归还seq后继续原会话。
const assert = require("node:assert/strict");
const { NeonController, createDemoTransport } = require("../web/controller.js");
const { NativeScorePlayer } = require("../web/native-score-player.js");
const tick = () => new Promise(resolve => setImmediate(resolve));
async function main() {
    const transport = createDemoTransport(), sent = [], write = transport.write.bind(transport);
    transport.write = async bytes => { sent.push([...bytes]); return write(bytes); };
    const controller = new NeonController({ heartbeatMs: 5 });
    await controller.connect(transport, "serial");
    let finish, stopped = 0, initialSeq;
    transport.playRealtime = (rows, timbre, seq, token) => {
        initialSeq = seq;
        return new Promise(resolve => { finish = extra => resolve({ state: "finished", completed: rows.length,
            total: rows.length, maxLateMs: 8, nextSeq: (seq + 253) & 255, ...extra }); });
    };
    transport.stopRealtime = async () => { stopped++; finish({ state: "stopped" }); };
    transport.realtimeStatus = async token => ({ state: "playing", completed: 0, total: 2, maxLateMs: 0, token });
    const states = [], player = new NativeScorePlayer(controller, state => states.push(state));
    const doc = { rows: [{ deltaMs: 0, midi: 60, on: 1, velocity: 90 }, { deltaMs: 50, midi: 60, on: 0, velocity: 0 }] };
    const task = player.start(doc, 2);
    await tick();
    const before = sent.length;
    const query = controller.readStatus();
    await new Promise(resolve => setTimeout(resolve, 30));
    assert.equal(sent.length, before, "心跳和普通命令不得交错原生播放");
    await player.stop();
    await task;
    assert.equal(stopped, 1);
    await query;
    assert.equal(sent[before][3], (initialSeq + 253) & 255, "必须归还精确seq并处理回绕");
    assert.equal(states.at(-1).state, "stopped");
    assert.equal(player.busy, false);
    await controller.disconnect();
    // 用户断开必须取消原生任务，不等到整首歌曲结束才关闭连接。
    const t2 = createDemoTransport(), c2 = new NeonController({ heartbeatMs: 0 });
    await c2.connect(t2);
    let stop2 = 0, finish2;
    t2.playRealtime = (rows, timbre, seq) => new Promise(resolve => {
        finish2 = () => resolve({ state: "stopped", completed: 1, total: 2, maxLateMs: 0, nextSeq: (seq + 2) & 255 });
    });
    t2.stopRealtime = async () => { stop2++; finish2(); };
    const native2 = c2.playNativeScore(doc, 2, "disconnect_test");
    await tick();
    await c2.disconnect();
    await native2;
    assert.equal(stop2, 1);
    assert.equal(c2.ready, false);
    // 交接结果不明时不能用旧seq继续；按安全断连处理，而非静默吞掉错误。
    const t3 = createDemoTransport(), c3 = new NeonController({ heartbeatMs: 0 });
    await c3.connect(t3);
    t3.stopRealtime = async () => {};
    t3.playRealtime = async () => { throw Error("native bridge failed"); };
    await assert.rejects(c3.playNativeScore(doc, 2, "bridge_failure"), /native bridge failed/);
    assert.equal(c3.ready, false);
    console.log("NATIVE LEASE PASS: exclusive session, heartbeat deferral, sequence handback, stop, queued request");
}
main().catch(error => { console.error(error); process.exitCode = 1; });
