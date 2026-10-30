"use strict";
// 真实协议/会话与可控二进制设备，验证扩展探测不破坏旧板连接。
const assert = require("node:assert/strict");
const P = require("../web/protocol.js");
const Phone = require("../../mobile/web/protocol.js");
const { NeonController, createDemoTransport } = require("../web/controller.js");

function device(legacy = false) {
    const base = createDemoTransport();
    let receive = () => {};
    const state = { enabled: false, count: 0, requests: [] };
    const transport = {
        ...base,
        onBytes(callback) { receive = callback; return base.onBytes(callback); },
        async write(bytes) {
            const q = P.decode(bytes);
            state.requests.push(q);
            if (q.op === P.OP.READBACK && q.payload[0] === 5) {
                if (!legacy)
                    receive(P.encode(q.seq, P.OP.SUSTAIN_STATUS,
                        [1, state.enabled ? 1 : 0, state.count, 64]));
                receive(P.encode(q.seq, P.OP.ACK, [q.op, legacy ? 1 : 0]));
                return;
            }
            if (q.op === P.OP.CONFIG && q.payload[0] === 2) {
                assert.equal(legacy, false);
                state.enabled = !!q.payload[1];
                receive(P.encode(q.seq, P.OP.ACK, [q.op, 0]));
                return;
            }
            if (q.op === P.OP.TRANSPORT && q.payload[0] === 5) state.enabled = false;
            return base.write(bytes);
        },
    };
    return { state, transport };
}

async function main() {
    const payload = [1, 1, 64, 64, 0, 0, 0, 0, 0, 0];
    assert.deepEqual(P.sustainStatus(payload), Phone.sustainStatus(payload));
    assert.throws(() => P.sustainStatus([1, 2, 0, 64, 0, 0, 0, 0, 0, 0]));
    assert.throws(() => P.sustainStatus([1, 1, 65, 64, 0, 0, 0, 0, 0, 0]));
    assert.throws(() => P.sustainStatus([1, 1, 0, 32, 0, 0, 0, 0, 0, 0]));
    assert.throws(() => P.sustainStatus([1, 1, 0, 64, 1, 0, 0, 0, 0, 0]));
    const options = { heartbeatMs: 0, sustainSync: true, retries: 0 };
    const { state, transport } = device();
    const controller = new NeonController(options);
    await controller.connect(transport, "serial");
    assert.equal(controller.ready, true);
    assert.equal(controller.sustainState.supported, true);
    assert.equal(controller.sustainState.enabled, false);
    await controller.setSustain(true);
    assert.equal(controller.sustainState.enabled, true);
    state.enabled = false;
    state.count = 7;
    await controller.readSustainState();
    assert.equal(controller.sustainState.enabled, false);
    assert.equal(controller.sustainState.deferredVoices, 7);
    await controller.setSustain(true);
    await controller.panic();
    await controller.readSustainState();
    assert.equal(controller.sustainState.enabled, false);
    await controller.disconnect();
    const old = device(true);
    const legacy = new NeonController(options);
    await legacy.connect(old.transport, "serial");
    assert.equal(legacy.ready, true);
    assert.equal(legacy.sustainState.supported, false);
    await assert.rejects(legacy.setSustain(true), /延音/);
    assert.equal(old.state.requests.some(q => q.op === 3 && q.payload[0] === 2), false);
    await legacy.noteOn("legacy", 69);
    await legacy.noteOff("legacy");
    await legacy.disconnect();
    console.log("SUSTAIN CLIENT PASS parser parity, board state, switch, panic and legacy fallback");
}
main().catch(error => { console.error(error); process.exitCode = 1; });
