'use strict';
const assert = require('node:assert/strict');
const P = require('../web/protocol.js');
const {NeonController, createDemoTransport} = require('../web/controller.js');
const delay = ms => new Promise(r => setTimeout(r, ms));
const options = {heartbeatMs: 0, timeoutMs: 30, dataTimeoutMs: 35, writeTimeoutMs: 80, retries: 1};
const score = n => ({version: 1, title: 'Test', rows: Array.from({length: n}, (_, i) => ({deltaMs: i ? 20 : 0, key: i % 25, velocity: 100, on: i % 2 ? 0 : 1}))});

// Deliberately controllable binary transport. Each write carries one real
// RemoteProtocol frame; data and ACK may be delivered in either order.
function wire({dataFirst = false, ackDelay = 0, dataDelay = 0, drop = false, conflict = false} = {}) {
  let onBytes = () => {}, onDisconnect = () => {}, closed = false, reads = 0;
  const writes = [], delivered = [], timers = new Set();
  const schedule = (p, ms) => { const t = setTimeout(() => { timers.delete(t); if (!closed) { delivered.push(p); onBytes(P.encode(p.seq, p.op, p.payload)); } }, ms); timers.add(t); };
  return {
    writes, delivered, closeCount: 0,
    onBytes(fn) { onBytes = fn; this.savedBytes = fn; return () => { onBytes = () => {}; }; },
    onDisconnect(fn) { onDisconnect = fn; this.savedDisconnect = fn; return () => { onDisconnect = () => {}; }; },
    async write(bytes) {
      if (closed) throw new Error('closed wire');
      const q = P.decode(bytes); writes.push(q); if (drop) return;
      let status = 0;
      if (q.op === 8 && conflict && reads++ === 0) status = 1;
      const ack = {seq: q.seq, op: 128, payload: [q.op, status]};
      const data = {seq: q.seq, op: q.payload[0] === 0 ? 129 : 130, payload: q.payload[0] === 0 ? [3, 0, 0, 0, 0, 0, 0, 0, 0, 0] : [q.payload[1], q.payload[2], 0, 0, 0, 0, 25, 60, 100, 5]};
      if (q.op === 8 && !status && dataFirst) { schedule(data, dataDelay); schedule(ack, Math.max(dataDelay + 2, ackDelay)); }
      else { schedule(ack, ackDelay); if (q.op === 8 && !status) schedule(data, Math.max(ackDelay + 2, dataDelay)); }
    },
    async close() { this.closeCount++; closed = true; for (const t of timers) clearTimeout(t); timers.clear(); },
    fail() { onDisconnect(new Error('wire lost')); }
  };
}

async function handshakeAndReadback() {
  for (const dataFirst of [false, true]) {
    const t = wire({dataFirst, ackDelay: 3, dataDelay: 8, conflict: true});
    const states = [], telemetry = [];
    const c = new NeonController({...options, onState: s => states.push(s), onTelemetry: x => telemetry.push(x)});
    await c.connect(t, 'ble'); assert.equal(c.ready, true); assert.equal(c.mode, 'ble');
    assert.deepEqual(t.writes.slice(0, 3).map(q => q.op), [8, 8, 4]);
    assert.equal(t.writes[2].payload[0], 5);
    assert.deepEqual(t.writes.slice(3, 28).map(q => q.payload.slice(0, 2)), Array.from({length: 25}, (_, i) => [i, 60 + i]));
    assert.deepEqual(t.writes.slice(28).map(q => q.op), [3, 3, 2, 8]);
    assert.ok(states.at(-1).ready); assert.equal(telemetry.at(-1).activeVoices, 3);
    const before = t.writes.length;
    const read = c.readStatus(), config = c.configure(0, 3);
    await delay(4); assert.equal(t.writes.length, before + 1, 'ACK alone cannot release READBACK boundary');
    await Promise.all([read, config]); assert.equal(c.timbre, 3);
    await c.disconnect(); assert.equal(c.ready, false); assert.equal(t.closeCount, 1);
  }
}

async function staleAndFaults() {
  const c = new NeonController(options), old = wire(); await c.connect(old, 'serial');
  const savedBytes = old.savedBytes, savedDisconnect = old.savedDisconnect;
  const next = wire(); await c.connect(next, 'ble');
  savedBytes(P.encode(55, 129, [64, 15])); savedDisconnect(new Error('stale disconnect'));
  assert.equal(c.ready, true); assert.equal(c.telemetry.activeVoices, 3);
  next.fail(); assert.equal(c.ready, false); await assert.rejects(c.noteOn('a', 60), /连接已变化/);
  const failing = new NeonController(options); await assert.rejects(failing.connect(wire({drop: true}), 'serial'), /ACK 超时/); assert.equal(failing.ready, false);
  const missing = wire();
  const original = missing.write;
  // Deliver ACKs but no telemetry, proving a separate bounded data deadline.
  missing.write = async function (bytes) {
    const q = P.decode(bytes); if (q.op !== 8) return original.call(this, bytes);
    this.writes.push(q); setTimeout(() => this.savedBytes(P.encode(q.seq, 128, [8, 0])), 0);
  };
  await assert.rejects(new NeonController(options).connect(missing, 'ble'), /数据响应超时/);
  const overlap = new NeonController(options), a = wire(), b = wire();
  const pending = overlap.connect(a, 'ble').catch(e => e);
  await overlap.connect(b, 'ble'); assert.ok(await pending instanceof Error); assert.equal(a.closeCount, 1); assert.equal(overlap.ready, true); await overlap.disconnect();
}

async function heldAndExpressions() {
  const t = createDemoTransport({latencyMs: 1}), c = new NeonController(options);
  await c.connect(t, 'ble'); assert.equal(c.mode, 'demo');
  const start = t.requests.length;
  await Promise.all([c.noteOn('mouse', 60, 90, 2), c.noteOn('keyboard', 60, 100, 1)]);
  await c.noteOff('mouse'); assert.equal(t.requests.length, start + 1);
  await c.noteOff('keyboard');
  assert.deepEqual(t.requests.slice(start).map(q => q.payload.slice(0, 5)), [[63,60,90,2,1], [63,60,0,2,0]]);
  await c.noteOn('a', 62); await c.noteOn('b', 64);
  const releaseStart = t.requests.length; await c.releaseAll();
  assert.ok(t.requests.slice(releaseStart).every(q => q.op === 1 && q.payload[4] === 0), 'blur release is remote NOTE OFF only');
  const exprStart = t.requests.length;
  await Promise.all([c.setExpression({gain: 2100}), c.setExpression({bend: -125}), c.setExpression({gain: 2200, vibrato: 8})]);
  const expr = t.requests.slice(exprStart).filter(q => q.op === 2); assert.equal(expr.length, 1);
  assert.deepEqual(expr[0].payload.slice(0, 6), [7, 152,8,131,255,8]);
  await c.setExpression({gain: 2250}); assert.equal(t.requests.at(-1).payload[0], 1, 'gain-only drag must not overwrite physical bend');
  await assert.rejects(c.setExpression({bend: 2401}), /bend/);
  await assert.rejects(c.setExpression({vibrato: 101}), /vibrato/);
  const cancelled = c.setExpression({gain: 2300}).catch(e => e); await c.panic(); assert.ok(await cancelled instanceof Error);
  await c.setMapping(2, 70); assert.equal(c.mapping[2], 70);
  await c.noteOn('disconnect-held', 67);
  const closing = c.disconnect(); assert.equal(c.ready, false);
  await assert.rejects(c.noteOn('late-press', 69), /关闭/);
  await Promise.all([closing, c.disconnect()]);
  assert.deepEqual(t.requests.at(-1).payload.slice(0, 5), [63,67,0,2,0]);
}

async function releaseAllKeepsNewPress() {
  const t = createDemoTransport({latencyMs: 1}), c = new NeonController(options);
  await c.connect(t, 'demo');
  try {
    await c.noteOn('old-c', 60); await c.noteOn('old-d', 62); await c.noteOn('old-d-alias', 62);
    const start = t.requests.length;
    const releasing = c.releaseAll(), pressing = c.noteOn('new-d', 62);
    await Promise.all([releasing, pressing]);
    assert.deepEqual(t.requests.slice(start).map(q => q.payload.slice(1, 5)), [
      [60, 0, 2, 0], [62, 0, 2, 0], [62, 100, 2, 1]
    ], 'a fresh press must follow the entire deduplicated release batch');
    assert.equal((await c.readStatus()).activeVoices, 1, 'a fresh press must remain sounding after releaseAll');
    await c.noteOff('new-d');
    assert.equal((await c.readStatus()).activeVoices, 0, 'the fresh owner must still release its note');

    await c.noteOn('prior-off', 60); await c.noteOn('batch-d', 62);
    const secondStart = t.requests.length;
    const priorOff = c.noteOff('prior-off'), firstBatch = c.releaseAll();
    const intermediatePress = c.noteOn('intermediate-d', 62), secondBatch = c.releaseAll();
    const finalPress = c.noteOn('final-d', 62);
    await Promise.all([priorOff, firstBatch, intermediatePress, secondBatch, finalPress]);
    assert.deepEqual(t.requests.slice(secondStart).map(q => q.payload.slice(1, 5)), [
      [60, 0, 2, 0], [62, 0, 2, 0], [62, 100, 2, 1], [62, 0, 2, 0], [62, 100, 2, 1]
    ], 'individual releases and repeated batches must preserve successive note owners');
    assert.equal((await c.readStatus()).activeVoices, 1);
    await c.noteOff('final-d'); assert.equal((await c.readStatus()).activeVoices, 0);
  } finally { await c.disconnect(); }
}

async function releaseAllFailureClosesCleanly() {
  const t = wire(), c = new NeonController(options), unhandled = [];
  const capture = e => unhandled.push(e);
  process.on('unhandledRejection', capture);
  try {
    await c.connect(t); await c.noteOn('a', 60); await c.noteOn('b', 62); await c.noteOn('c', 64);
    const original = t.write;
    t.write = async function (bytes) {
      const q = P.decode(bytes);
      if (q.op !== P.OP.NOTE || q.payload[4]) return original.call(this, bytes);
      this.writes.push(q);
      queueMicrotask(() => this.savedBytes(P.encode(q.seq, P.OP.ACK, [P.OP.NOTE, 2])));
    };
    await assert.rejects(c.releaseAll(), /NACK status=2/);
    await delay(20);
    assert.equal(c.ready, false, 'a rejected release must close the uncertain session');
    assert.equal(t.closeCount, 1);
    assert.deepEqual(unhandled, [], 'all queued release rejections must have handlers');
  } finally { await c.disconnect(); process.off('unhandledRejection', capture); }
}

async function bulkAndRecording() {
  const t = createDemoTransport({latencyMs: 1}), c = new NeonController(options); await c.connect(t, 'demo');
  const progress = []; await c.uploadScore(score(6), p => progress.push(p));
  assert.deepEqual(progress.at(-1), {completed: 6, total: 6});
  assert.equal(t.requests.at(-1).op, 7); assert.deepEqual(t.requests.at(-1).payload.slice(0, 3), [6,0,0]);
  const before = t.requests.length;
  const cancelled = c.uploadScore(score(80), p => { if (p.completed === 2) c.transportAction(0).catch(() => {}); }).catch(e => e);
  assert.match((await cancelled).message, /取消/);
  await c.readStatus(); assert.equal(t.requests.slice(before).filter(q => q.op === 7).length, 0, 'cancelled upload never commits');
  const panicStart = t.requests.length; let panic;
  const panicCancelled = c.uploadScore(score(80), p => { if (p.completed === 2) panic = c.panic(); }).catch(e => e);
  assert.match((await panicCancelled).message, /取消/); await panic;
  assert.equal(t.requests.slice(panicStart).filter(q => q.op === 7).length, 0, 'PANIC also cancels uncommitted bulk');
  await c.transportAction(2); await c.noteOn('record', 65); await delay(3); await c.noteOff('record');
  const rows = await c.readRecording(); assert.equal(rows.length, 2); assert.equal(rows[0].source, 63); assert.equal(rows[0].midi, 65); assert.equal(rows[1].on, 0); assert.equal(c.recorded, rows);
  await assert.rejects(c.transportAction(8), /NACK status=1/, 'source63 recording cannot use FPGA physical replay');
  await c.selectBuiltin(); await c.transportAction(1); assert.equal((await c.readStatus()).playing, true);
  await c.transportAction(0); assert.equal((await c.readStatus()).playing, false);
  const uploading = c.uploadScore(score(80)).catch(e => e); await delay(4); t.fail(); assert.ok(await uploading instanceof Error); assert.equal(c.ready, false);
}

async function heartbeat() {
  const t = wire({dataDelay: 8}), c = new NeonController({...options, heartbeatMs: 12});
  await c.connect(t, 'serial'); const start = t.writes.length;
  await delay(55); assert.ok(t.writes.slice(start).filter(q => q.op === 8).length >= 2);
  await c.disconnect(); const end = t.writes.length; await delay(30); assert.equal(t.writes.length, end, 'disconnect stops heartbeats');
}

async function main() {
  await handshakeAndReadback(); await staleAndFaults(); await heldAndExpressions(); await releaseAllKeepsNewPress(); await releaseAllFailureClosesCleanly(); await bulkAndRecording(); await heartbeat();
  console.log('ALL DESKTOP CONTROLLER TESTS PASSED: handshake, ACK/data ordering, generation isolation, failures, held pitches, atomic remote release batches, clean batch failure, expression coalescing, upload/cancel, recording and demo distinction');
}
main().catch(e => { console.error(e); process.exitCode = 1; });
