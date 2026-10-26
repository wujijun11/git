/* 标准MIDI文件解析和事件转换。无音频数据、无BLE依赖；浏览器和Node可复用。 */
(function (root) {
    "use strict";
    const LIMIT = 4 * 1024 * 1024;
    function need(ok, message) {
        if (!ok) throw Error(message);
    }
    function parse(input) {
        const bytes =
            input instanceof Uint8Array ? input : new Uint8Array(input);
        need(bytes.length <= LIMIT, "MIDI超过4MiB");
        let pos = 0;
        const byte = () => {
            need(pos < bytes.length, "MIDI文件截断");
            return bytes[pos++];
        };
        const word = () => byte() * 256 + byte();
        const dword = () => word() * 65536 + word();
        const tag = () => String.fromCharCode(byte(), byte(), byte(), byte());
        const vlq = () => {
            let n = 0;
            for (let i = 0; i < 4; i++) {
                const b = byte();
                n = n * 128 + (b & 127);
                if (!(b & 128)) return n;
            }
            throw Error("无效的MIDI可变长度字段");
        };
        need(tag() === "MThd", "请选择标准MID/MIDI文件");
        const size = dword(),
            headerEnd = pos + size;
        need(size >= 6 && headerEnd <= bytes.length, "无效MIDI文件头");
        const format = word(),
            count = word(),
            division = word();
        need(
            (format === 0 || format === 1) && division > 0 && division < 32768,
            "只支持Type 0/1和拍数时间；不支持Type 2或SMPTE",
        );
        need(
            count > 0 && count <= 128 && (format !== 0 || count === 1),
            "MIDI音轨数量无效或超过128",
        );
        pos = headerEnd;
        const tracks = [],
            messages = [];
        for (let track = 0; track < count; track++) {
            need(tag() === "MTrk", "缺少MTrk音轨");
            const length = dword(),
                end = pos + length;
            need(end <= bytes.length, "MIDI音轨截断");
            let tick = 0,
                running = 0,
                notes = 0,
                name = "",
                order = 0;
            while (pos < end) {
                tick += vlq();
                need(Number.isSafeInteger(tick), "MIDI时间溢出");
                let status = byte(),
                    data = [];
                if (status < 128) {
                    need(running >= 128, "无效的MIDI运行状态");
                    data.push(status);
                    status = running;
                }
                let event = { tick, track, order: order++, type: "other" };
                if (status === 255) {
                    const type = byte(),
                        length = vlq();
                    need(pos + length <= end, "MIDI元消息截断");
                    if (type === 81) {
                        need(length === 3, "无效速度消息");
                        event.type = "tempo";
                        event.tempo =
                            bytes[pos] * 65536 +
                            bytes[pos + 1] * 256 +
                            bytes[pos + 2];
                        need(event.tempo > 0, "MIDI速度必须大于零");
                    }
                    if (type === 3)
                        name = String.fromCharCode(
                            ...bytes.slice(pos, pos + Math.min(length, 120)),
                        ).replace(/[\x00-\x1f]/g, " ");
                    pos += length;
                } else if (status === 240 || status === 247) {
                    const length = vlq();
                    need(pos + length <= end, "系统消息截断");
                    pos += length;
                    running = 0;
                    event.type = "control";
                } else {
                    need(status >= 128 && status < 240, "不支持的MIDI状态");
                    running = status;
                    const type = status >> 4,
                        length = type === 12 || type === 13 ? 1 : 2;
                    while (data.length < length) data.push(byte());
                    need(
                        data.every((b) => b < 128),
                        "无效的MIDI数据字节",
                    );
                    event.channel = status & 15;
                    if (type === 8 || type === 9) {
                        event.type = "note";
                        event.midi = data[0];
                        event.velocity = data[1];
                        event.on = type === 9 && data[1] > 0;
                        if (event.on) notes++;
                    } else if ([10, 11, 13, 14].includes(type))
                        event.type = "control";
                }
                need(pos <= end, "MIDI事件超出音轨边界");
                messages.push(event);
                need(messages.length <= 200000, "MIDI超过20万消息");
            }
            tracks.push({
                index: track,
                name: name || `音轨 ${track + 1}`,
                notes,
            });
        }
        messages.sort(
            (a, b) => a.tick - b.tick || a.track - b.track || a.order - b.order,
        );
        // 与Windows/mido一致，以秒累计并使用偶数舍入，避免0.5ms边界两端相差1ms。
        const roundEven = (value) =>
            value % 1 === 0.5 ? 2 * Math.round(value / 2) : Math.round(value);
        let tempo = 500000,
            tick = 0,
            seconds = 0;
        for (const event of messages) {
            seconds += (event.tick - tick) * ((tempo * 1e-6) / division);
            tick = event.tick;
            event.ms = roundEven(seconds * 1000);
            if (event.type === "tempo") tempo = event.tempo;
        }
        need(seconds <= 24 * 3600, "MIDI超过24小时，请先裁剪");
        return { tracks, durationMs: roundEven(seconds * 1000), messages };
    }

    // 输出与Windows端相同的key事件结构。时间单位毫秒，越界只报错，不截曲。
    function convert(info, title, options, attribution = {}) {
        const {
            tracks: selected,
            startMs: start = 0,
            endMs: end = info.durationMs,
            maxEvents: boardCapacity = 1024,
            compact = false,
            direct: directOption = false,
            realtime = false,
        } = options;
        const direct = directOption || realtime, maxEvents = realtime ? 100000 : boardCapacity;
        let mapping = (
            options.mapping || Array.from({ length: 25 }, (_, i) => 60 + i)
        ).slice();
        need([256, 1024].includes(boardCapacity), "曲谱容量应为256或1024");
        need(typeof directOption === "boolean" && typeof realtime === "boolean", "播放选项必须为布尔值");
        need(
            Array.isArray(selected) &&
                selected.length &&
                selected.every(
                    (i) =>
                        Number.isInteger(i) &&
                        info.tracks.some((t) => t.index === i),
                ),
            "请选择有效音轨",
        );
        need(
            Number.isInteger(start) &&
                Number.isInteger(end) &&
                0 <= start &&
                start < end &&
                end <= Math.max(1, info.durationMs),
            "片段起止时间无效",
        );
        need(!realtime || end - start <= 21600000, "实时曲谱最长6小时");
        need(
            mapping.length === 25 &&
                mapping.every((n) => Number.isInteger(n) && n >= 0 && n <= 127),
            "映射必须为25个MIDI音高",
        );
        const held = new Map(),
            pitchesHeld = new Map(),
            velocities = new Map(),
            output = [],
            warnings = new Set();
        let seeded = false;
        const emit = (ms, midi, velocity, on) =>
            output.push({ ms, midi, velocity, on });
        const seed = () => {
            if (seeded) return;
            [...pitchesHeld]
                .sort((a, b) => a[0] - b[0])
                .forEach(([n, count]) => {
                    if (count) emit(0, n, velocities.get(n), 1);
                });
            seeded = true;
        };
        for (const event of info.messages) {
            if (!selected.includes(event.track)) continue;
            if (event.ms >= start) seed();
            if (event.ms >= end) break;
            if (event.type === "control")
                warnings.add(
                    "踏板、弯音、触后及其他控制消息未导入，只导入音符与力度",
                );
            if (event.type !== "note") continue;
            if (event.channel === 9)
                warnings.add(
                    "含打击乐通道，将用当前乐器音色演奏其音高；可取消该音轨",
                );
            const id = `${event.track}:${event.channel}:${event.midi}`,
                old = pitchesHeld.get(event.midi) || 0;
            if (event.on) {
                velocities.set(event.midi, event.velocity);
                held.set(id, (held.get(id) || 0) + 1);
                pitchesHeld.set(event.midi, old + 1);
                if (old)
                    warnings.add(
                        "相同音高重叠已合并为一个键位，不能保留各声部原音色",
                    );
                if (event.ms >= start && !old)
                    emit(event.ms - start, event.midi, event.velocity, 1);
            } else if (held.get(id)) {
                held.set(id, held.get(id) - 1);
                pitchesHeld.set(event.midi, old - 1);
                if (event.ms >= start && old === 1)
                    emit(event.ms - start, event.midi, 0, 0);
            }
        }
        seed();
        [...pitchesHeld]
            .sort((a, b) => a[0] - b[0])
            .forEach(([n, count]) => {
                if (count) emit(end - start, n, 0, 0);
            });
        const pitches = [...new Set(output.map((e) => e.midi))].sort(
                (a, b) => a - b,
            ),
            errors = [];
        if (compact && !direct) {
            if (pitches.length > 25)
                errors.push(
                    `片段含${pitches.length}种音高，超过25键，请减少音轨或缩短片段`,
                );
            else {
                mapping = [
                    ...new Set([
                        ...pitches,
                        ...Array.from({ length: 25 }, (_, i) => 60 + i),
                        ...Array.from({ length: 128 }, (_, i) => i),
                    ]),
                ].slice(0, 25);
                warnings.add(
                    "上传时将重新设置25个实体琴键的音高；播放前请把滑条音区设为标准",
                );
            }
        }
        const missing = pitches.filter((n) => !mapping.includes(n));
        if (missing.length && !direct)
            errors.push("以下MIDI音高不在当前25键映射：" + missing.join(", "));
        if (!output.length) errors.push("所选片段没有可演奏音符");
        if (output.length > maxEvents)
            errors.push(
                `片段需要${output.length}条事件，当前播放方式最多${maxEvents}条；请缩短片段`,
            );
        const activePitches=new Set();let peakPolyphony=0;
        for(const event of output){
            if(event.on)activePitches.add(event.midi);else activePitches.delete(event.midi);
            peakPolyphony=Math.max(peakPolyphony,activePitches.size);
        }
        if(direct){
            warnings.add(realtime ? "蓝牙实时播放：保持连接和应用前台运行，不改键位，不提供逐键灯光指引；密集和弦受传输速度限制" : "脱离25键直接播放：需新版FPGA支持，使用板上当前音色，不改实体键位，不提供逐键灯光指引");
            warnings.add("与手动演奏共用64声部，释放尾音也占声部；密集片段可能达到上限");
            if(peakPolyphony>64)errors.push(`片段同时按住${peakPolyphony}个音，超过64声部；请选择较少音轨`);
        }
        let previous = 0;
        const rows = output.map((e) => {
            const row = {
                deltaMs: e.ms - previous,
                ...(direct ? {midi:e.midi} : {key:Math.max(0,mapping.indexOf(e.midi))}),
                velocity: e.velocity,
                on: e.on,
            };
            previous = e.ms;
            return row;
        });
        return {
            canUpload: !errors.length && !realtime,
            canStream: !errors.length && realtime,
            errors,
            warnings: [...warnings].sort(),
            maxEvents,
            eventCount: rows.length,
            pitchCount: pitches.length,
            peakPolyphony,
            durationMs: end - start,
            pianoRoll: output,
            score: {
                version: direct ? 2 : 1,
                title: String(title).slice(0, 120),
                rows,
                ...(direct ? {playback:"direct"} : {mapping}),
                ...(realtime ? {transport:"realtime"} : {}),
                attribution,
                segment: {
                    startMs: start,
                    endMs: end,
                    tracks: selected.slice(),
                },
            },
        };
    }
    const api = { parse, convert };
    if (typeof module !== "undefined") module.exports = api;
    root.MidiScore = api;
})(typeof globalThis === "undefined" ? window : globalThis);
