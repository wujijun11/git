'use strict';
// Controlled ACK/data boundaries; never opens BLE, serial, audio, or a window.
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
const P = require('../web/protocol.js');
const controllerPath = process.env.CONTROLLER_UNDER_TEST || path.resolve(__dirname, '../web/controller.js');
const {NeonController} = require(controllerPath);
const tick = () => new Promise(resolve => setImmediate(resolve));
const outcome = promise => promise.then(value => ({ok: true, value}), error => ({ok: false, error}));
const opts = {heartbeatMs: 0, timeoutMs: 40, dataTimeoutMs: 40, writeTimeoutMs: 80, retries: 0};

function wire() {
  let bytes = () => {}, gated = false;
  const t = {
    requests: [], pending: [], notes: new Set(), closes: 0,
    onBytes(fn) { bytes = fn; return () => { bytes = () => {}; }; },
    onDisconnect() { return () => {}; },
    telemetry(seq) { bytes(P.encode(seq, P.OP.TELEMETRY, [])); },
    reply(q, data = true) { bytes(P.encode(q.seq, P.OP.ACK, [q.op, 0])); if (q.op === P.OP.READBACK && data) t.telemetry(q.seq); },
    ack(data = true) { assert.ok(t.pending.length, 'expected an active request'); const q = t.pending.shift(); t.reply(q, data); return q; },
    gate() { gated = true; },
    automatic() { gated = false; },
    async write(raw) {
      const q = P.decode(raw); t.requests.push(q);
      if (q.op === P.OP.NOTE) q.payload[4] ? t.notes.add(q.payload[1]) : t.notes.delete(q.payload[1]);
      if (q.op === P.OP.TRANSPORT && q.payload[0] === 5) t.notes.clear();
      if (gated) t.pending.push(q); else t.reply(q);
    },
    async close() { t.closes++; }
  };
  return t;
}

async function fixture(fn) {
  const t = wire(), c = new NeonController(opts);
  await c.connect(t);
  try { await fn(c, t); }
  finally { if (c._ctx) c._lose(c._ctx, new Error('test cleanup')); await tick(); }
}

async function panicSkipsOldBacklog() {
  await fixture(async (c, t) => {
    t.gate(); const start = t.requests.length;
    const active = outcome(c.noteOn('active', 60)); await tick();
    const old = [];
    for (let i = 0; i < 25; i++) { old.push(outcome(c.noteOn('old'+i, 62+i))); old.push(outcome(c.noteOff('old'+i))); }
    const stop = outcome(c.panic()), fresh = outcome(c.noteOn('fresh', 64));
    t.ack(); await tick();
    assert.equal(t.requests[start+1].op, P.OP.TRANSPORT, 'PANIC must precede every unstarted old command');
    assert.equal(t.requests[start+1].payload[0], 5);
    t.ack(); await tick();
    assert.deepEqual(t.requests[start+2].payload.slice(1, 5), [64, 100, 2, 1]);
    t.ack(); await tick();
    assert.ok((await active).ok && (await stop).ok && (await fresh).ok);
    assert.ok((await Promise.all(old)).every(x => !x.ok && x.error.cancelled));
    assert.equal(t.requests.length-start, 3, 'old note traffic must not resume after stop');
    assert.deepEqual([...t.notes], [64]); assert.equal(c.ready, true);
    t.automatic(); await c.noteOff('fresh'); assert.equal(t.notes.size, 0);
  });
}

async function disconnectUsesAcceptedNotes() {
  await fixture(async (c, t) => {
    await c.noteOn('accepted', 52); t.gate(); const start = t.requests.length;
    const active = outcome(c.noteOn('inflight', 60)); await tick();
    const old = [outcome(c.noteOff('accepted')), outcome(c.noteOff('inflight'))];
    for (let i = 0; i < 20; i++) { old.push(outcome(c.noteOn('old'+i, 64+i)), outcome(c.noteOff('old'+i))); }
    const close = c.disconnect(); assert.equal(c.ready, false);
    await assert.rejects(c.noteOn('too-late', 90), /关闭|连接已变化/);
    t.ack(); await tick();
    assert.deepEqual(t.requests[start+1].payload.slice(1, 5), [52, 0, 2, 0], 'release accepted notes even when queued OFF removed their UI owners');
    t.ack(); await tick();
    assert.deepEqual(t.requests[start+2].payload.slice(1, 5), [60, 0, 2, 0], 'release the note accepted by the in-flight ACK');
    t.ack(); await close;
    assert.ok((await active).ok); assert.ok((await Promise.all(old)).every(x => !x.ok && x.error.cancelled));
    assert.equal(t.notes.size, 0); assert.equal(t.closes, 1); assert.equal(t.requests.length-start, 3);
    assert.ok(t.requests.slice(start).every(q => q.op === P.OP.NOTE), 'disconnect must not stop local FPGA score owners');
  });
}

async function queueHasRealBound() {
  await fixture(async (c, t) => {
    t.gate(); const start = t.requests.length;
    const pending = [outcome(c.noteOn('active', 60))]; await tick();
    let maximum = 0;
    for (let i = 0; i < 150; i++) {
      pending.push(outcome(c.configure(0, i%4)));
      maximum = Math.max(maximum, c._ctx?.queue?.length || 0);
    }
    assert.equal(c.ready, false, 'overflow must close immediately without waiting for an ACK timeout');
    const results = await Promise.all(pending);
    assert.equal(maximum, 128); assert.ok(results.every(x => !x.ok));
    assert.equal(c.ready, false); assert.equal(t.closes, 1); assert.equal(t.requests.length-start, 1);
    assert.ok(results.some(x => /积压/.test(x.error.message)));
  });
}

async function stopKeepsAckDataBoundary() {
  await fixture(async (c, t) => {
    t.gate(); const start = t.requests.length;
    const read = outcome(c.readStatus()); await tick(); const q = t.ack(false);
    const stop = outcome(c.panic()); await tick();
    assert.equal(t.requests.length-start, 1, 'cannot start PANIC between READBACK ACK and telemetry');
    t.telemetry(q.seq); await tick(); assert.equal(t.requests[start+1].op, P.OP.TRANSPORT);
    t.ack(); assert.ok((await read).ok && (await stop).ok);
  });
}

async function cancelledReleaseDoesNotClose() {
  await fixture(async (c, t) => {
    await c.noteOn('a', 60); await c.noteOn('b', 62); t.gate();
    const read = outcome(c.readStatus()); await tick();
    const release = outcome(c.releaseAll()), stop = outcome(c.panic());
    t.ack(); await tick(); assert.equal(t.pending[0].op, P.OP.TRANSPORT);
    t.ack(); assert.ok((await read).ok && (await stop).ok);
    const result = await release; assert.equal(result.error.cancelled, true);
    assert.equal(c.ready, true); assert.equal(t.closes, 0); assert.equal(t.notes.size, 0);
  });
}

async function missingAckStillFailsClosed() {
  await fixture(async (c, t) => {
    t.gate(); const start = t.requests.length;
    const active = outcome(c.noteOn('active', 60)); await tick(); const stop = outcome(c.panic());
    const result = await Promise.all([active, stop]);
    assert.ok(result.every(x => !x.ok && /ACK 超时/.test(x.error.message)));
    assert.equal(c.ready, false); assert.equal(t.closes, 1); assert.equal(t.requests.length-start, 1);
  });
}

async function disconnectObserverIsReentrant() {
  const t = wire(); let c, nested, observed = false;
  c = new NeonController({...opts, onState: state => {
    if (state.status === '正在释放远程音符并断开' && !observed) { observed = true; nested = c.disconnect(); }
  }});
  try {
    await c.connect(t); await c.noteOn('held', 60); const start = t.requests.length;
    const closing = c.disconnect(); assert.equal(nested, closing);
    await closing; assert.equal(t.closes, 1); assert.equal(t.notes.size, 0);
    assert.deepEqual(t.requests.slice(start).map(q => q.payload.slice(1, 5)), [[60, 0, 2, 0]]);
  } finally { if (c._ctx) c._lose(c._ctx, new Error('test cleanup')); }
}

(async () => {
  const unhandled = []; const collect = error => unhandled.push(String(error)); process.on('unhandledRejection', collect);
  const cases = [];
  for (const test of [panicSkipsOldBacklog, disconnectUsesAcceptedNotes, queueHasRealBound, stopKeepsAckDataBoundary, cancelledReleaseDoesNotClose, missingAckStillFailsClosed, disconnectObserverIsReentrant]) {
    try { await test(); cases.push({name: test.name, pass: true}); }
    catch (error) { cases.push({name: test.name, pass: false, error: error.stack}); }
  }
  await tick(); process.off('unhandledRejection', collect);
  const result = {controllerPath, controllerSha256: crypto.createHash('sha256').update(fs.readFileSync(controllerPath)).digest('hex'),
    cases, unhandledRejections: unhandled, accepted: cases.every(x => x.pass) && unhandled.length === 0, hardwareAccessed: false};
  if (process.env.QUEUE_TEST_RESULT) fs.writeFileSync(process.env.QUEUE_TEST_RESULT, JSON.stringify(result, null, 2)+'\n');
  console.log(JSON.stringify(result, null, 2)); if (!result.accepted) process.exitCode = 1;
})().catch(error => { console.error(error); process.exitCode = 1; });
