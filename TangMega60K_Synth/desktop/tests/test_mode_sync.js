"use strict";
// 模式来自板端；读取不会回写音色。使用真实帧编解码的受控传输，不接触硬件。
const assert = require("node:assert/strict");
const P = require("../web/protocol.js");
const Phone = require("../../mobile/web/protocol.js");
const { NeonController, createDemoTransport } = require("../web/controller.js");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function device() {
    const base = createDemoTransport();
    let receive = () => {};
    const state = { payload: [1, 32, 1, 2, 3, 244, 2, 0, 0, 0], requests: [] };
    const transport = {
        ...base,
        onBytes(fn) {
            receive = fn;
            return base.onBytes(fn);
        },
        async write(bytes) {
            const q = P.decode(bytes);
            state.requests.push(q);
            if (q.op === 8 && q.payload[0] === 2) {
                receive(P.encode(q.seq, 131, state.payload));
                receive(P.encode(q.seq, 128, [q.op, 0]));
                return;
            }
            return base.write(bytes);
        },
    };
    return { state, transport };
}
(async () => {
    const { state, transport } = device(),
        seen = [];
    const c = new NeonController({
        modeSync: true,
        heartbeatMs: 25,
        onBoardMode: (value) => seen.push(value),
    });
    try {
        await c.connect(transport);
        assert.equal(c.timbre, 3);
        assert.equal(c.effect, 2);
        assert.equal(c.boardMode.transpose, -12);
        assert.equal(
            state.requests.some((q) => q.op === 3),
            false,
            "connection must not overwrite a physical timbre",
        );
        state.payload = [1, 33, 0, 1, 1, 12, 1, 0, 0, 0];
        await c.readBoardMode();
        assert.equal(c.timbre, 1);
        assert.equal(c.boardMode.mainMenu, true);
        state.payload = [1, 40, 2, 0, 2, 232, 0, 0, 0, 0];
        for (let i = 0; i < 30 && !c.boardMode.recording; i++) await delay(10);
        assert.equal(
            c.boardMode.recording,
            true,
            "idle heartbeat must refresh the board state",
        );
        assert.equal(c.boardMode.transpose, -24);
        assert.deepEqual(
            P.modeStatus(state.payload),
            Phone.modeStatus(state.payload),
        );
        assert.equal(
            state.requests.some((q) => q.op === 3),
            false,
            "polling must remain read-only",
        );
        state.payload[0] = 2;
        await assert.rejects(c.readBoardMode(), /模式/);
        assert.equal(c.ready, false, "invalid new payload must fail visibly");
    } finally {
        await c.disconnect();
    }
    const old = new NeonController({ modeSync: true, heartbeatMs: 0 });
    try {
        await old.connect(createDemoTransport());
        assert.equal(old.ready, true);
        assert.equal(old.boardMode, null);
        await assert.rejects(old.readBoardMode(), /不支持/);
    } finally {
        await old.disconnect();
    }
    console.log(
        "MODE SYNC PASS board truth, negative transpose, idle polling, no config writes, malformed packet and legacy fallback",
    );
})().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
