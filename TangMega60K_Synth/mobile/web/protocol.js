(function (root) {
    "use strict";
    const UUID = Object.freeze({
        service: "6e400001-b5a3-f393-e0a9-e50e24dcca9e",
        rx: "6e400002-b5a3-f393-e0a9-e50e24dcca9e",
        tx: "6e400003-b5a3-f393-e0a9-e50e24dcca9e",
    });
    const OP = Object.freeze({
        NOTE: 1,
        EXPRESSION: 2,
        CONFIG: 3,
        TRANSPORT: 4,
        MAP: 5,
        SCORE_WRITE: 6,
        SCORE_COMMIT: 7,
        READBACK: 8,
        ACK: 128,
        TELEMETRY: 129,
        EVENT: 130,
        MODE_STATUS: 131,
        SCORE_CAPABILITIES: 132,
    });
    function integer(v, min, max, name) {
        if (!Number.isInteger(v) || v < min || v > max)
            throw new Error(name + " 必须为 " + min + ".." + max + " 的整数");
        return v;
    }
    function crc8(bytes) {
        let c = 0;
        for (const b of bytes) {
            c ^= b;
            for (let i = 0; i < 8; i++)
                c = (c & 128 ? (c << 1) ^ 7 : c << 1) & 255;
        }
        return c;
    }
    function encode(seq, op, payload = []) {
        integer(seq, 0, 255, "seq");
        integer(op, 0, 255, "op");
        if (payload.length > 10) throw new Error("payload > 10");
        const a = new Uint8Array(16);
        a.set([165, 90, 1, seq, op]);
        payload.forEach((v, i) => (a[5 + i] = integer(v, 0, 255, "payload")));
        a[15] = crc8(a.subarray(2, 15));
        return a;
    }
    function decode(a) {
        if (
            a.length !== 16 ||
            a[0] !== 165 ||
            a[1] !== 90 ||
            a[2] !== 1 ||
            a[15] !== crc8(a.subarray(2, 15))
        )
            throw new Error("无效帧/CRC");
        return { seq: a[3], op: a[4], payload: Array.from(a.subarray(5, 15)) };
    }
    function u16(p, i) {
        return p[i] + 256 * p[i + 1];
    }
    function u32(p, i) {
        return (
            (p[i] + 256 * p[i + 1] + 65536 * p[i + 2] + 16777216 * p[i + 3]) >>>
            0
        );
    }
    function le16(n) {
        return [n & 255, (n >> 8) & 255];
    }
    function le32(n) {
        return [n & 255, (n >>> 8) & 255, (n >>> 16) & 255, (n >>> 24) & 255];
    }
    function note(midi, velocity, timbre, on) {
        return [
            63,
            integer(midi, 0, 127, "MIDI"),
            integer(velocity, 0, 127, "velocity"),
            integer(timbre, 0, 3, "timbre"),
            on ? 1 : 0,
        ];
    }
    function expression(gain, bend, vibrato) {
        integer(gain, 0, 4095, "gain Q1.11");
        integer(bend, -32768, 32767, "bend");
        integer(vibrato, 0, 255, "vibrato");
        return [7, ...le16(gain), ...le16(bend), vibrato];
    }
    function validateScore(doc, maxRows = 1024) {
        const direct = doc?.version === 2 && doc?.playback === "direct";
        if (
            !doc ||
            (doc.version !== 1 && !direct) ||
            !Array.isArray(doc.rows) ||
            !doc.rows.length ||
            doc.rows.length > maxRows
        )
            throw new Error("曲谱须为键位version=1或直接播放version=2，rows数量1.." + maxRows);
        if(direct && doc.mapping!==undefined)throw Error("直接播放不能修改实体键位mapping");
        const result = {
            version: direct ? 2 : 1,
            title:
                typeof doc.title === "string"
                    ? doc.title.slice(0, 120)
                    : "在线曲谱",
            rows: doc.rows.map((r, i) => {
                if (!r || typeof r !== "object") throw new Error("row " + i);
                return {
                    deltaMs: integer(r.deltaMs, 0, 4294967295, "deltaMs"),
                    ...(direct ? {midi: integer(r.midi,0,127,"MIDI")} : {key: integer(r.key,0,24,"key")}),
                    velocity: integer(r.velocity, 0, 127, "velocity"),
                    on: integer(r.on, 0, 1, "on"),
                };
            }),
        };
        if(direct)result.playback="direct";
        if (doc.mapping !== undefined) {
            if (!Array.isArray(doc.mapping) || doc.mapping.length !== 25)
                throw new Error("mapping必须为25个音高");
            result.mapping = doc.mapping.map((n) => integer(n, 0, 127, "MIDI"));
        }
        for (const key of ["attribution", "segment"])
            if (doc[key] && typeof doc[key] === "object")
                result[key] = doc[key];
        return result;
    }
    function scoreRow(i, r) {
        return [
            ...le16(integer(i, 0, 65535, "row")),
            ...le32(r.deltaMs),
            r.midi === undefined ? r.key : r.midi,
            r.velocity,
            r.on,
            ...(r.midi === undefined ? [] : [1]),
        ];
    }
    function scoreCapabilities(p) {
        if(p[0]!==1 || p[1]!==1 || !u16(p,2) || u16(p,2)>1024 || p[4]!==127 || p[5]!==64 || p[6]!==62 || p.slice(7).some(Boolean))
            throw Error("无效直接曲谱能力响应");
        return {direct:true,capacity:u16(p,2),maxMidi:p[4],voices:p[5],source:p[6]};
    }
    function telemetry(p) {
        return {
            activeVoices: p[0],
            playing: !!(p[1] & 1),
            recording: !!(p[1] & 2),
            guide: !!(p[1] & 4),
            overflow: !!(p[1] & 8),
            recordCount: u16(p, 2),
            audioUnderruns: u32(p, 4),
            scorePosition: u16(p, 8),
        };
    }
    function event(p) {
        return {
            index: u16(p, 0),
            deltaMs: u32(p, 2),
            source: p[6],
            midi: p[7],
            velocity: p[8],
            on: p[9] & 1,
            timbre: (p[9] >> 1) & 3,
        };
    }
    // 只读菜单状态：音区是有符号半音，不用显示值反向写配置。
    function modeStatus(p) {
        if (
            p[0] !== 1 ||
            p[1] & 192 ||
            p[2] > 3 ||
            p[3] > 3 ||
            p[4] > 3 ||
            p[6] > 3 ||
            p[8] ||
            p[9]
        )
            throw Error("无效模式状态");
        return {
            version: 1,
            mainMenu: !!(p[1] & 1),
            busy: !!(p[1] & 2),
            playing: !!(p[1] & 4),
            recording: !!(p[1] & 8),
            guide: !!(p[1] & 16),
            menuEnabled: !!(p[1] & 32),
            page: p[2],
            zone: p[3],
            timbre: p[4],
            transpose: p[5] > 127 ? p[5] - 256 : p[5],
            effect: p[6],
            error: p[7],
        };
    }
    class StreamDecoder {
        constructor(onPacket) {
            this.buffer = [];
            this.onPacket = onPacket;
            this.errors = 0;
        }
        push(bytes) {
            this.buffer.push(...bytes);
            while (this.buffer.length >= 2) {
                if (this.buffer[0] !== 165 || this.buffer[1] !== 90) {
                    this.buffer.shift();
                    continue;
                }
                if (this.buffer.length < 16) return;
                let p;
                try {
                    p = decode(Uint8Array.from(this.buffer.slice(0, 16)));
                } catch (e) {
                    this.errors++;
                    this.buffer.shift();
                    continue;
                }
                this.buffer.splice(0, 16);
                this.onPacket(p);
            }
        }
        reset() {
            this.buffer = [];
        }
    }
    // Only one in-flight command. A retry preserves the exact seq and packet.
    // The FPGA router owns duplicate suppression and repeats the cached ACK.
    class Session {
        constructor(
            write,
            {
                timeoutMs = 1500,
                writeTimeoutMs = 4000,
                retries = 2,
                startSeq = 0,
                onPacket = () => {},
                onFatal = () => {},
                onSequence = () => {},
            } = {},
        ) {
            this.write = write;
            this.timeoutMs = timeoutMs;
            this.writeTimeoutMs = writeTimeoutMs;
            this.retries = retries;
            this.seq = startSeq & 255;
            this.onPacket = onPacket;
            this.onFatal = onFatal;
            this.onSequence = onSequence;
            this.queue = [];
            this.pending = null;
            this.closed = false;
        }
        send(op, payload = []) {
            if (this.closed) return Promise.reject(new Error("连接已关闭"));
            try {
                payload = Array.from(payload);
                encode(0, op, payload);
            } catch (e) {
                return Promise.reject(e);
            }
            if (this.queue.length >= 128) {
                const e = new Error(
                    "命令队列已满，连接已关闭；FPGA通信看门狗将释放手机音符",
                );
                this.close(e);
                this.onFatal(e);
                return Promise.reject(e);
            }
            return new Promise((resolve, reject) => {
                this.queue.push({ op, payload, resolve, reject });
                this.pump();
            });
        }
        pump() {
            if (this.closed || this.pending || !this.queue.length) return;
            const q = this.queue.shift();
            q.seq = this.seq;
            this.seq = (this.seq + 1) & 255;
            q.bytes = encode(q.seq, q.op, q.payload);
            q.attempt = 0;
            this.pending = q;
            // Reserve the in-flight request before notifying observers: a callback
            // may synchronously enqueue another command or close this session.
            try {
                this.onSequence(this.seq);
            } catch (error) {
                if (this.closed) return;
                const failure =
                    error instanceof Error ? error : new Error(String(error));
                this.close(failure);
                try {
                    this.onFatal(failure);
                } catch (_) {
                    /* Preserve the original failure. */
                }
                return;
            }
            this.transmit(q);
        }
        async transmit(q) {
            if (this.pending !== q || this.closed) return;
            q.attempt++;
            q.writing = true;
            clearTimeout(q.timer);
            q.writeTimer = setTimeout(() => {
                if (this.pending !== q || this.closed) return;
                const e = new Error("BLE 写入超时：连接已关闭，请重新连接");
                this.close(e);
                this.onFatal(e);
            }, this.writeTimeoutMs);
            try {
                await this.write(q.bytes);
            } catch (e) {
                clearTimeout(q.writeTimer);
                if (this.pending !== q || this.closed) return;
                this.close(e);
                this.onFatal(e);
                return;
            }
            clearTimeout(q.writeTimer);
            q.writing = false;
            if (this.pending !== q || this.closed) return;
            if (q.ack) {
                this.finish(q, q.ack);
                return;
            }
            q.timer = setTimeout(() => {
                if (q.attempt <= this.retries) this.transmit(q);
                else {
                    const e = new Error(
                        "ACK 超时：连接中断，演奏状态未知；重新连接将发送全部停止",
                    );
                    this.close(e);
                    this.onFatal(e);
                }
            }, this.timeoutMs);
        }
        finish(q, p) {
            if (this.pending !== q) return;
            clearTimeout(q.timer);
            clearTimeout(q.writeTimer);
            this.pending = null;
            if (p.payload[1] === 0) q.resolve(p);
            else q.reject(new Error("FPGA NACK status=" + p.payload[1]));
            this.pump();
        }
        receive(p) {
            const q = this.pending;
            if (
                p.op === OP.ACK &&
                q &&
                p.seq === q.seq &&
                p.payload[0] === q.op
            ) {
                q.ack = p;
                clearTimeout(q.timer);
                if (!q.writing) this.finish(q, p);
            }
            this.onPacket(p);
        }
        close(error = new Error("BLE 连接关闭")) {
            this.closed = true;
            if (this.pending) {
                clearTimeout(this.pending.timer);
                clearTimeout(this.pending.writeTimer);
                this.pending.reject(error);
                this.pending = null;
            }
            for (const q of this.queue) q.reject(error);
            this.queue = [];
        }
    }
    const api = {
        UUID,
        OP,
        crc8,
        encode,
        decode,
        le16,
        le32,
        u16,
        u32,
        note,
        expression,
        validateScore,
        scoreRow,
        scoreCapabilities,
        telemetry,
        event,
        modeStatus,
        StreamDecoder,
        Session,
    };
    if (typeof module !== "undefined") module.exports = api;
    root.RemoteProtocol = api;
})(typeof window !== "undefined" ? window : globalThis);
