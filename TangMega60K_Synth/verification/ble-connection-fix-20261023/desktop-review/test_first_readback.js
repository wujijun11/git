'use strict';
// Real controller/Session/decoder with a controlled first READBACK transport.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '../../..');
const P = require(path.join(root, 'desktop/web/protocol.js'));
const {NeonController} = require(path.join(root, 'desktop/web/controller.js'));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

function controlled(mode) {
  let notify = () => {}, closed = false, active = 0;
  const wire = {
    writes: [], maximumWrites: 0, closeCount: 0,
    onBytes(fn) { notify = fn; return () => { notify = () => {}; }; },
    onDisconnect() { return () => {}; },
    async write(bytes) {
      if (closed) throw new Error('controlled link closed');
      active++; wire.maximumWrites = Math.max(active, wire.maximumWrites);
      try {
        wire.writes.push(Buffer.from(bytes));
        const q = P.decode(bytes), first = q.op === P.OP.READBACK && q.seq === 0;
        const ack = P.encode(q.seq, P.OP.ACK, [q.op, 0]), data = P.encode(q.seq, P.OP.TELEMETRY, []);
        if (first && mode === 'crc-corrupt') { ack[15] ^= 1; notify(ack); }
        else if (first && mode === 'drop-first-ack' && wire.writes.length === 1) notify(data);
        else if (q.op === P.OP.READBACK) {
          if (mode === 'data-first') { notify(data); notify(ack); }
          else if (mode === 'bundled') notify(Uint8Array.from([...ack, ...data]));
          else if (mode === 'bytewise') for (const byte of [...ack, ...data]) notify(Uint8Array.of(byte));
          else { notify(ack); if (mode !== 'data-missing') notify(data); }
        } else notify(ack);
        // Every response above precedes the transport write completion.
        await delay(3);
      } finally { active--; }
    },
    async close() { closed = true; wire.closeCount++; }
  };
  return wire;
}

(async () => {
  const cases = [];
  for (const mode of ['early-ack', 'data-first', 'bundled', 'bytewise', 'drop-first-ack', 'crc-corrupt', 'data-missing']) {
    const wire = controlled(mode), controller = new NeonController({heartbeatMs: 0, timeoutMs: 15, dataTimeoutMs: 20, writeTimeoutMs: 100, retries: 1});
    try {
      if (mode === 'crc-corrupt') {
        await assert.rejects(controller.connect(wire, 'controlled'), /ACK 超时/);
        assert.equal(controller.ready, false); assert.equal(wire.writes.length, 2);
      } else if (mode === 'data-missing') {
        await assert.rejects(controller.connect(wire, 'controlled'), /数据响应超时/);
        assert.equal(controller.ready, false); assert.equal(wire.writes.length, 1);
      } else {
        await controller.connect(wire, 'controlled'); assert.equal(controller.ready, true);
        if (mode === 'drop-first-ack') assert.deepEqual(wire.writes[0], wire.writes[1], 'retry preserves the exact first READBACK');
      }
      assert.equal(wire.maximumWrites, 1);
      cases.push({mode, passed: true, writes: wire.writes.length, failClosedExpected: mode === 'crc-corrupt' || mode === 'data-missing'});
    } catch (error) { cases.push({mode, passed: false, error: error.message}); }
    finally { await controller.disconnect(); }
  }
  const sourceHashes = Object.fromEntries(['desktop/web/controller.js', 'desktop/web/protocol.js'].map(name => [name, crypto.createHash('sha256').update(fs.readFileSync(path.join(root, name))).digest('hex')]));
  const result = {passed: cases.filter(c => c.passed).length, failed: cases.filter(c => !c.passed).length, newDefectReproduced: false, hardwareAccessed: false, cases, sourceHashes};
  fs.writeFileSync(path.join(__dirname, 'first-readback-result.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2)); process.exitCode = result.failed ? 1 : 0;
})().catch(error => { console.error(error); process.exitCode = 1; });
