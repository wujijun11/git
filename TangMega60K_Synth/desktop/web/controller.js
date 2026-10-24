(function (root, factory) {
  'use strict';
  const api = factory(typeof module === 'object' && module.exports ? require('./protocol.js') : root.RemoteProtocol);
  if (typeof module === 'object' && module.exports) module.exports = api;
  root.NeonController = api.NeonController;
  root.createDemoTransport = api.createDemoTransport;
})(typeof globalThis !== 'undefined' ? globalThis : this, function (P) {
  'use strict';
  if (!P) throw new Error('RemoteProtocol must load before controller.js');
  const number = (v, lo, hi, label) => {
    if (!Number.isInteger(v) || v < lo || v > hi) throw new Error(label + ' 必须为 ' + lo + '..' + hi + ' 的整数');
    return v;
  };
  const errorOf = e => e instanceof Error ? e : new Error(String(e || '连接已断开'));
  const cancelled = message => Object.assign(new Error(message), {cancelled: true});
  const MAX_QUEUED_REQUESTS = 128;

  class NeonController {
    constructor({onState = () => {}, onTelemetry = () => {}, onLog = () => {}, onEvent = () => {},
      heartbeatMs = 1000, timeoutMs = 1500, writeTimeoutMs = 4000, dataTimeoutMs = 2000, retries = 2} = {}) {
      Object.assign(this, {onState, onTelemetry, onLog, onEvent, heartbeatMs, timeoutMs, writeTimeoutMs, dataTimeoutMs, retries});
      this.ready = false; this.mode = null; this.mapping = Array.from({length: 25}, (_, i) => 60 + i);
      this.timbre = 2; this.effect = 0; this.gain = 2048; this.bend = 0; this.vibrato = 0;
      this.telemetry = null; this.recorded = []; this._ctx = null; this._generation = 0;
      this._nextSeq = 0; this._held = new Map(); this._bulk = null; this._expression = null;
    }
    _emit(fn, value) { try { fn(value); } catch (_) { /* UI callbacks cannot damage packet framing. */ } }
    _state(status, error = null) { this._emit(this.onState, {ready: this.ready, mode: this.mode, connected: !!this._ctx, status, error: error ? error.message : null}); }
    _log(message) { this._emit(this.onLog, String(message)); }
    _check(ctx, setup = false) {
      if (!ctx || this._ctx !== ctx || ctx.closed || ctx.generation !== this._generation) throw new Error('连接已变化，操作已取消');
      if (!setup && !this.ready && !ctx.closing) throw new Error('FPGA 握手尚未完成');
    }
    _context() { const ctx = this._ctx; this._check(ctx); if (ctx.closing) throw new Error('连接正在关闭'); return ctx; }
    _enqueue(ctx, task, setup = false) {
      try { this._check(ctx, setup); } catch (e) { return Promise.reject(e); }
      if (ctx.queue.length >= MAX_QUEUED_REQUESTS) {
        const e = new Error('命令积压过多，连接已关闭；FPGA通信看门狗将释放远程音符');
        this._lose(ctx, e); return Promise.reject(e);
      }
      return new Promise((resolve, reject) => {
        ctx.queue.push({task, setup, resolve, reject}); this._drain(ctx);
      });
    }
    _drain(ctx) {
      if (ctx.closed || ctx.running || !ctx.queue.length) return;
      const entry = ctx.queue.shift(); ctx.running = true;
      let result;
      try { this._check(ctx, entry.setup); result = entry.task(); }
      catch (e) { result = Promise.reject(e); }
      const done = () => { ctx.running = false; this._drain(ctx); };
      Promise.resolve(result).then(value => { entry.resolve(value); done(); }, error => { entry.reject(error); done(); });
    }
    _cancelQueued(ctx, error) {
      for (const entry of ctx.queue.splice(0)) entry.reject(error);
    }
    _packet(ctx, packet) {
      if (this._ctx !== ctx || ctx.closed || ctx.generation !== this._generation) return;
      const waiter = ctx.waiters.get(packet.seq + ':' + packet.op);
      if (waiter) waiter.resolve(packet);
      if (packet.op === P.OP.TELEMETRY) {
        this.telemetry = P.telemetry(packet.payload); this._emit(this.onTelemetry, this.telemetry);
      } else if (packet.op === P.OP.EVENT) this._emit(this.onEvent, P.event(packet.payload));
    }
    // The controller mutex encloses both ACK and optional READBACK data. The
    // protocol Session by itself serializes ACKs only, which is insufficient.
    _request(ctx, op, payload = [], replyOp = null, setup = false) {
      return this._enqueue(ctx, () => this._executeRequest(ctx, op, payload, replyOp, setup), setup);
    }
    async _executeRequest(ctx, op, payload, replyOp, setup) {
        let waiter = null, dataPromise = null;
        const key = ctx.session.seq + ':' + replyOp;
        if (replyOp !== null) {
          dataPromise = new Promise((resolve, reject) => {
            waiter = {resolve, reject}; ctx.waiters.set(key, waiter);
          });
          // Receive can precede ACK or even the transport write callback.
          dataPromise.catch(() => {});
        }
        try {
          const ack = await ctx.session.send(op, payload); this._check(ctx, setup);
          // Track accepted remote pitches, including notes whose UI owners were
          // already removed by a queued NOTE OFF. Disconnect releases this ledger
          // after the in-flight transaction completes, not a stale held snapshot.
          if (op === P.OP.NOTE) {
            if (payload[4] && payload[2]) ctx.remoteNotes.set(payload[1], {midi: payload[1], timbre: payload[3]});
            else ctx.remoteNotes.delete(payload[1]);
          } else if (op === P.OP.TRANSPORT && payload[0] === 5) ctx.remoteNotes.clear();
          if (!dataPromise) return ack;
          let timer;
          const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('FPGA 数据响应超时')), this.dataTimeoutMs); });
          try { const data = await Promise.race([dataPromise, deadline]); this._check(ctx, setup); return data; }
          finally { clearTimeout(timer); }
        } catch (e) {
          if (e.message === 'FPGA 数据响应超时') this._lose(ctx, e);
          throw e;
        } finally { if (waiter && ctx.waiters.get(key) === waiter) ctx.waiters.delete(key); }
    }
    _readback(ctx, selector, index = 0, setup = false) {
      return this._request(ctx, P.OP.READBACK, [selector, ...P.le16(index)], selector === 0 ? P.OP.TELEMETRY : P.OP.EVENT, setup);
    }
    _lose(ctx, error = new Error('连接已断开')) {
      if (!ctx || this._ctx !== ctx || ctx.closed) return;
      error = errorOf(error); ctx.closed = true; this._ctx = null; this._generation++; this.ready = false;
      clearInterval(ctx.heartbeat); this.cancelBulk(); this._cancelExpression(error); this._held.clear();
      ctx.session.close(error);
      this._cancelQueued(ctx, error);
      for (const w of ctx.waiters.values()) w.reject(error);
      ctx.waiters.clear();
      for (const off of ctx.unsubscribers) { try { off(); } catch (_) {} }
      try { const p = ctx.transport.close(); if (p && p.catch) p.catch(() => {}); } catch (_) {}
      this._state(error.message, error); this._log(error.message);
    }
    async connect(transport, mode = 'ble') {
      if (!transport || ['write', 'close', 'onBytes', 'onDisconnect'].some(k => typeof transport[k] !== 'function')) throw new Error('无效连接通道');
      await this.disconnect();
      // Two connect calls can both pass the initial await while disconnected.
      // Close an attempt installed during that await before replacing it.
      if (this._ctx) this._lose(this._ctx, new Error('连接已被新的连接替换'));
      const ctx = {transport, generation: ++this._generation, closed: false, queue: [], running: false, remoteNotes: new Map(), waiters: new Map(), unsubscribers: []};
      this._ctx = ctx; this.mode = transport.isDemo ? 'demo' : mode; this.ready = false; this.telemetry = null;
      ctx.session = new P.Session(bytes => transport.write(bytes), {
        startSeq: this._nextSeq, timeoutMs: this.timeoutMs, writeTimeoutMs: this.writeTimeoutMs, retries: this.retries,
        onSequence: next => { if (this._ctx === ctx) this._nextSeq = next; },
        onPacket: packet => this._packet(ctx, packet), onFatal: error => this._lose(ctx, error)
      });
      ctx.decoder = new P.StreamDecoder(packet => { if (this._ctx === ctx && !ctx.closed) ctx.session.receive(packet); });
      try {
        const offBytes = transport.onBytes(bytes => { if (this._ctx === ctx && !ctx.closed) ctx.decoder.push(bytes); });
        const offDisconnect = transport.onDisconnect(error => this._lose(ctx, errorOf(error)));
        if (typeof offBytes === 'function') ctx.unsubscribers.push(offBytes);
        if (typeof offDisconnect === 'function') ctx.unsubscribers.push(offDisconnect);
        this._state('通道已连接，正在与 FPGA 握手');
        try { await this._readback(ctx, 0, 0, true); }
        catch (e) { if (!e.message.includes('NACK status=1')) throw e; await this._readback(ctx, 0, 0, true); }
        await this._request(ctx, P.OP.TRANSPORT, [5], null, true);
        for (let i = 0; i < 25; i++) await this._request(ctx, P.OP.MAP, [i, this.mapping[i]], null, true);
        await this._request(ctx, P.OP.CONFIG, [0, this.timbre], null, true);
        await this._request(ctx, P.OP.CONFIG, [1, this.effect], null, true);
        await this._request(ctx, P.OP.EXPRESSION, P.expression(this.gain, this.bend, this.vibrato), null, true);
        await this._readback(ctx, 0, 0, true); this._check(ctx, true); this.ready = true;
        if (this.heartbeatMs > 0) {
          ctx.heartbeat = setInterval(() => {
            if (ctx.heartbeatBusy || this._ctx !== ctx || !this.ready) return;
            ctx.heartbeatBusy = true;
            this.readStatus().catch(e => this._log(e.message)).finally(() => { ctx.heartbeatBusy = false; });
          }, this.heartbeatMs);
          if (ctx.heartbeat.unref) ctx.heartbeat.unref();
        }
        this._state(this.mode === 'demo' ? '演示模式：协议模拟，未连接硬件' : 'FPGA 握手通过'); return this.telemetry;
      } catch (e) { this._lose(ctx, e); throw e; }
    }
    disconnect() {
      const ctx = this._ctx;
      if (!ctx) return Promise.resolve();
      if (ctx.disconnectPromise) return ctx.disconnectPromise;
      this._held.clear();
      const wasReady = this.ready; ctx.closing = true; this.ready = false;
      clearInterval(ctx.heartbeat);
      const reason = cancelled('连接正在关闭，旧操作已取消');
      this.cancelBulk(); this._cancelExpression(reason); this._cancelQueued(ctx, reason);
      // Reserve the shared promise before notifying UI observers: an observer
      // may synchronously call disconnect() again during this state change.
      ctx.disconnectPromise = Promise.resolve().then(async () => {
        try {
          if (wasReady) await this._enqueue(ctx, async () => {
            for (const n of Array.from(ctx.remoteNotes.values()))
              await this._executeRequest(ctx, P.OP.NOTE, P.note(n.midi, 0, n.timbre, false), null, true);
          }, true);
        } catch (_) { /* Closing also stops heartbeat, allowing source63 expiry. */ }
        finally { this._lose(ctx, new Error('已断开')); }
      });
      this._state('正在释放远程音符并断开');
      return ctx.disconnectPromise;
    }
    async readStatus() { const p = await this._readback(this._context(), 0); return P.telemetry(p.payload); }
    noteOn(id, midi, velocity = 100, timbre = this.timbre) {
      let ctx;
      try { ctx = this._context(); number(midi, 0, 127, 'MIDI'); number(velocity, 1, 127, '力度'); number(timbre, 0, 3, '音色'); }
      catch (e) { return Promise.reject(e); }
      if (this._held.has(id)) return Promise.resolve();
      const same = Array.from(this._held.values()).find(n => n.midi === midi);
      this._held.set(id, {midi, timbre: same ? same.timbre : timbre});
      if (same) return Promise.resolve();
      return this._request(ctx, P.OP.NOTE, P.note(midi, velocity, timbre, true)).catch(e => { if (!e.cancelled) this._lose(ctx, e); throw e; });
    }
    noteOff(id) {
      const note = this._held.get(id); if (!note) return Promise.resolve();
      let ctx; try { ctx = this._context(); } catch (e) { return Promise.reject(e); }
      this._held.delete(id);
      if (Array.from(this._held.values()).some(n => n.midi === note.midi)) return Promise.resolve();
      return this._request(ctx, P.OP.NOTE, P.note(note.midi, 0, note.timbre, false)).catch(e => { if (!e.cancelled) this._lose(ctx, e); throw e; });
    }
    async releaseAll() {
      const ctx = this._ctx; if (!ctx || !this.ready) { this._held.clear(); return; }
      const pitches = new Map(Array.from(this._held.values(), n => [n.midi, n])); this._held.clear();
      // Queue the complete release batch before yielding. A new press arriving
      // while ACKs are pending must follow every old NOTE OFF for that pitch.
      const releases = Array.from(pitches.values(), n => this._request(ctx, P.OP.NOTE, P.note(n.midi, 0, n.timbre, false)));
      try { await Promise.all(releases); }
      catch (e) { if (!e.cancelled) this._lose(ctx, e); throw e; }
    }
    async panic() {
      const ctx = this._context(), reason = cancelled('已全部停止，旧操作已取消');
      this.cancelBulk(); this._cancelExpression(reason); this._held.clear(); this._cancelQueued(ctx, reason);
      // Preserve the active ACK/data boundary; cancel only requests that have
      // not started, then place PANIC before any subsequent new key presses.
      return this._request(ctx, P.OP.TRANSPORT, [5]);
    }
    async configure(target, value) {
      number(target, 0, 1, '配置目标'); number(value, 0, 3, '配置值');
      const ctx = this._context(); await this._request(ctx, P.OP.CONFIG, [target, value]); this._check(ctx);
      this[target === 0 ? 'timbre' : 'effect'] = value;
    }
    async setMapping(key, midi) {
      number(key, 0, 24, '琴键'); number(midi, 0, 127, 'MIDI');
      const ctx = this._context(); await this._request(ctx, P.OP.MAP, [key, midi]); this._check(ctx); this.mapping[key] = midi;
    }
    setExpression(values = {}) {
      let ctx, mask = 0;
      try {
        ctx = this._context();
        for (const [key, bit, lo, hi] of [['gain', 1, 0, 4095], ['bend', 2, -2400, 2400], ['vibrato', 4, 0, 100]]) {
          if (Object.prototype.hasOwnProperty.call(values, key)) { number(values[key], lo, hi, key); mask |= bit; }
        }
      } catch (e) { return Promise.reject(e); }
      if (!mask) return Promise.resolve();
      for (const key of ['gain', 'bend', 'vibrato']) if (Object.prototype.hasOwnProperty.call(values, key)) this[key] = values[key];
      if (!this._expression) this._expression = {ctx, mask: 0, waiters: [], timer: null, sending: false, last: Date.now()};
      const expr = this._expression; expr.mask |= mask;
      const result = new Promise((resolve, reject) => expr.waiters.push({resolve, reject}));
      this._pumpExpression(expr); return result;
    }
    _pumpExpression(expr) {
      if (this._expression !== expr || expr.sending || !expr.mask) return;
      clearTimeout(expr.timer);
      const wait = Math.max(0, 40 - (Date.now() - expr.last));
      expr.timer = setTimeout(async () => {
        if (this._expression !== expr) return;
        const mask = expr.mask, waiters = expr.waiters.splice(0); expr.mask = 0; expr.sending = true; expr.last = Date.now();
        const payload = P.expression(this.gain, this.bend, this.vibrato); payload[0] = mask;
        try { const ack = await this._request(expr.ctx, P.OP.EXPRESSION, payload); waiters.forEach(w => w.resolve(ack)); }
        catch (e) { waiters.forEach(w => w.reject(e)); }
        finally { expr.sending = false; if (this._expression === expr) this._pumpExpression(expr); }
      }, wait);
    }
    _cancelExpression(error) {
      const expr = this._expression; this._expression = null;
      if (expr) { clearTimeout(expr.timer); expr.waiters.splice(0).forEach(w => w.reject(error)); }
    }
    cancelBulk() { if (this._bulk) this._bulk.cancelled = true; }
    _startBulk(name) {
      if (this._bulk) throw new Error('正在' + this._bulk.name + '，请稍候或停止');
      const op = {ctx: this._context(), name, cancelled: false}; this._bulk = op; return op;
    }
    _checkBulk(op) { this._check(op.ctx); if (op.cancelled || this._bulk !== op) throw new Error(op.name + '已取消'); }
    async transportAction(action) {
      number(action, 0, 8, '播放操作'); if (action === 5) return this.panic();
      if (action === 0) this.cancelBulk();
      const ctx = this._context(), ack = await this._request(ctx, P.OP.TRANSPORT, [action]); this._check(ctx);
      if (action === 2 || action === 4) this.recorded = [];
      return ack;
    }
    async selectBuiltin() { return this._request(this._context(), P.OP.SCORE_COMMIT, [0, 0, 1]); }
    async uploadScore(doc, onProgress = () => {}) {
      const score = P.validateScore(doc, 256), op = this._startBulk('上传曲谱');
      try {
        await this._request(op.ctx, P.OP.TRANSPORT, [0]); this._checkBulk(op);
        for (let i = 0; i < score.rows.length; i++) {
          this._checkBulk(op); await this._request(op.ctx, P.OP.SCORE_WRITE, P.scoreRow(i, score.rows[i])); this._checkBulk(op);
          this._emit(onProgress, {completed: i + 1, total: score.rows.length});
        }
        await this._request(op.ctx, P.OP.SCORE_COMMIT, [...P.le16(score.rows.length), 0]); this._checkBulk(op); return score;
      } finally { if (this._bulk === op) this._bulk = null; }
    }
    async readRecording(onProgress = () => {}) {
      const op = this._startBulk('读取录音');
      try {
        await this._request(op.ctx, P.OP.TRANSPORT, [3]); this._checkBulk(op);
        const state = P.telemetry((await this._readback(op.ctx, 0)).payload); this._checkBulk(op);
        number(state.recordCount, 0, 1024, '录音数量'); const rows = [];
        for (let i = 0; i < state.recordCount; i++) {
          this._checkBulk(op); const row = P.event((await this._readback(op.ctx, 1, i)).payload); this._checkBulk(op);
          if (row.index !== i) throw new Error('录音索引不匹配'); rows.push(row);
          this._emit(onProgress, {completed: i + 1, total: state.recordCount});
        }
        this.recorded = rows; return rows;
      } finally { if (this._bulk === op) this._bulk = null; }
    }
  }

  // In-memory protocol demonstrator only. No OS device, BLE, UART or PCM exists.
  function createDemoTransport({latencyMs = 3} = {}) {
    let bytesCallback = () => {}, disconnectCallback = () => {}, closed = false, last = null;
    let playing = false, recording = false, guide = false, overflow = false, scorePosition = 0;
    let timbre = 2, effect = 0, userScore = [], selected = 'builtin', lastRecordTime = 0;
    const notes = new Map(), scoreNotes = new Set(), events = [], written = new Map(), timers = new Set();
    const builtin = [64,64,65,67,67,65,64,62,60,60,62,64,64,62,62,64].flatMap((m, i) => [
      {deltaMs: i ? 40 : 0, key: m - 60, velocity: 100, on: 1}, {deltaMs: 280, key: m - 60, velocity: 0, on: 0}]);
    const state = () => [notes.size + scoreNotes.size, (playing ? 1 : 0) | (recording ? 2 : 0) | (guide ? 4 : 0) | (overflow ? 8 : 0), ...P.le16(events.length), 0,0,0,0, ...P.le16(scorePosition)];
    function later(fn, ms) { const timer = setTimeout(() => { timers.delete(timer); if (!closed) fn(); }, ms); timers.add(timer); }
    function stopScore() { for (const timer of timers) clearTimeout(timer); timers.clear(); playing = false; guide = false; scoreNotes.clear(); }
    function startScore(silent, rows) {
      stopScore(); playing = !silent; guide = silent; scorePosition = 0; let time = 0;
      rows.forEach((row, i) => { time += row.deltaMs; later(() => { scorePosition = i + 1; if (!silent) row.on && row.velocity ? scoreNotes.add(row.key) : scoreNotes.delete(row.key); }, time); });
      later(() => { playing = false; guide = false; scoreNotes.clear(); }, time + 1);
    }
    const transport = {
      isDemo: true, requests: [],
      onBytes(fn) { bytesCallback = fn; return () => { if (bytesCallback === fn) bytesCallback = () => {}; }; },
      onDisconnect(fn) { disconnectCallback = fn; return () => { if (disconnectCallback === fn) disconnectCallback = () => {}; }; },
      async write(bytes) {
        if (closed) throw new Error('演示通道已关闭');
        const q = P.decode(bytes), p = q.payload; transport.requests.push(q);
        let replies, status = 0, data = null;
        if (last && q.seq === last.seq) {
          replies = JSON.stringify(q) === last.request ? last.replies : [P.encode(q.seq, P.OP.ACK, [q.op, 1])];
        } else {
          if (q.op === P.OP.NOTE) {
            if (p[0] > 63 || p[1] > 127 || p[2] > 127 || p[3] > 3 || p[4] > 1 || p.slice(5).some(Boolean)) status = 1;
            else {
              p[4] && p[2] ? notes.set(p[1], {timbre: p[3]}) : notes.delete(p[1]);
              if (recording) {
                const now = Date.now(); if (events.length < 1024) events.push({deltaMs: now - lastRecordTime, source: 63, midi: p[1], velocity: p[2], on: p[4], timbre: p[3]});
                else { overflow = true; recording = false; } lastRecordTime = now;
              }
            }
          } else if (q.op === P.OP.EXPRESSION) {
            const bend = (P.u16(p, 3) << 16) >> 16;
            if (!p[0] || p[0] > 7 || P.u16(p, 1) > 4095 || Math.abs(bend) > 2400 || p[5] > 100 || p.slice(6).some(Boolean)) status = 1;
          } else if (q.op === P.OP.CONFIG) {
            if (p[0] > 1 || p[1] > 3 || p.slice(2).some(Boolean)) status = 1; else if (p[0] === 0) timbre = p[1]; else effect = p[1];
          } else if (q.op === P.OP.MAP) {
            if (p[0] > 24 || p[1] > 127 || p.slice(2).some(Boolean)) status = 1;
          } else if (q.op === P.OP.TRANSPORT) {
            if (p[0] > 8 || p.slice(1).some(Boolean)) status = 1;
            else if (p[0] === 0 || p[0] === 7) stopScore();
            else if (p[0] === 5) { stopScore(); notes.clear(); recording = false; }
            else if (p[0] === 2) { if (playing || guide) status = 2; else { events.length = 0; recording = true; overflow = false; lastRecordTime = Date.now(); } }
            else if (p[0] === 3) recording = false;
            else if (p[0] === 4) { if (recording || playing || guide) status = 2; else { events.length = 0; overflow = false; } }
            else if (p[0] === 8) { if (!events.length || events.some(e => e.source < 25 || e.source > 49)) status = 1; else startScore(false, events.map(e => ({...e, key: e.source - 25}))); }
            else if (playing || guide || recording) status = 2;
            else { const rows = selected === 'builtin' ? builtin : userScore; if (!rows.length) status = 1; else startScore(p[0] === 6, rows); }
          } else if (q.op === P.OP.SCORE_WRITE) {
            const index = P.u16(p, 0);
            if (playing || guide || recording) status = 2;
            else if (index >= 256 || p[6] > 24 || p[7] > 127 || p[8] > 1 || p[9]) status = 1;
            else { if (index === 0) written.clear(); written.set(index, {deltaMs: P.u32(p, 2), key: p[6], velocity: p[7], on: p[8]}); }
          } else if (q.op === P.OP.SCORE_COMMIT) {
            const count = P.u16(p, 0);
            if (playing || guide || recording) status = 2;
            else if (p[2] > 1 || p.slice(3).some(Boolean)) status = 1;
            else if (p[2] === 1) { if (count !== 0 && count !== 32) status = 1; else selected = 'builtin'; }
            else if (!count || count > 256 || Array.from({length: count}, (_, i) => i).some(i => !written.has(i))) status = 1;
            else { userScore = Array.from({length: count}, (_, i) => written.get(i)); written.clear(); selected = 'user'; }
          } else if (q.op === P.OP.READBACK) {
            if (p[0] > 1 || p.slice(3).some(Boolean)) status = 1;
            else if (p[0] === 0) data = P.encode(q.seq, P.OP.TELEMETRY, state());
            else {
              const index = P.u16(p, 1), e = events[index];
              if (!e) status = 1; else data = P.encode(q.seq, P.OP.EVENT, [...P.le16(index), ...P.le32(e.deltaMs), e.source, e.midi, e.velocity, e.on | (e.timbre << 1)]);
            }
          } else status = 3;
          replies = [P.encode(q.seq, P.OP.ACK, [q.op, status])]; if (status === 0 && data) replies.push(data);
          last = {seq: q.seq, request: JSON.stringify(q), replies};
        }
        replies.forEach((packet, i) => later(() => bytesCallback(packet.slice()), latencyMs * (i + 1)));
      },
      async close() { if (closed) return; closed = true; stopScore(); bytesCallback = () => {}; },
      fail(message = '演示连接中断') { if (!closed) { disconnectCallback(new Error(message)); transport.close(); } }
    };
    return transport;
  }
  return {NeonController, createDemoTransport};
});
