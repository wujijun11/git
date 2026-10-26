/* 蓝牙曲谱调度器。只调用已有NOTE指令；不生成PCM、不写板上曲谱RAM。
 * 桌面/手机共用此模块，手机副本由 scripts/sync-realtime-score.ps1 同步。
 */
(function (root, factory) {
    const api = factory();
    if (typeof module === "object" && module.exports) module.exports = api;
    root.RealtimeScore = api;
})(typeof globalThis === "undefined" ? this : globalThis, function () {
    "use strict";
    const MAX_EVENTS = 100000;
    const MAX_DURATION_MS = 6 * 60 * 60 * 1000;

    function integer(value, low, high, label) {
        if (!Number.isInteger(value) || value < low || value > high)
            throw Error(label + "必须为" + low + ".." + high + "的整数");
        return value;
    }

    // 返回快照，播放期间更换曲谱/键位不会改变已排定的音高。
    function validate(doc, fallbackMapping) {
        const direct = doc?.version === 2 && doc.playback === "direct";
        if (!doc || (!direct && doc.version !== 1) ||
            !Array.isArray(doc.rows) || !doc.rows.length || doc.rows.length > MAX_EVENTS)
            throw Error("实时曲谱须为version=1或直接音高version=2，事件数1.." + MAX_EVENTS);
        if (direct && doc.mapping !== undefined) throw Error("直接音高曲谱不能包含键位映射");
        const mapping = doc.mapping || fallbackMapping;
        if (!direct && (!Array.isArray(mapping) || mapping.length !== 25))
            throw Error("键位曲谱需要25个音高映射");
        if (!direct) mapping.forEach(n => integer(n, 0, 127, "映射音高"));
        let elapsed = 0;
        const active = new Set();
        const rows = doc.rows.map((row, index) => {
            if (!row || typeof row !== "object") throw Error("无效事件" + index);
            const deltaMs = integer(row.deltaMs, 0, MAX_DURATION_MS, "事件间隔ms");
            elapsed += deltaMs;
            if (elapsed > MAX_DURATION_MS) throw Error("实时曲谱最长6小时");
            const midi = direct ? integer(row.midi, 0, 127, "MIDI音高") :
                mapping[integer(row.key, 0, 24, "键位")];
            const on = integer(row.on, 0, 1, "按下/松开");
            const velocity = integer(row.velocity, on ? 1 : 0, 127, "力度");
            if (on && active.has(midi)) throw Error("同音高重叠，请先松开再重新触发：MIDI " + midi);
            if (!on && !active.has(midi)) throw Error("没有对应按下的松开事件：MIDI " + midi);
            if (on) active.add(midi); else active.delete(midi);
            if (active.size > 64) throw Error("同时按住的音符超过64个");
            return { deltaMs, midi, on, velocity };
        });
        if (active.size) throw Error("曲谱结尾缺少松开事件，请补齐后播放");
        return {
            version: 2, playback: "direct", transport: "realtime",
            title: String(doc.title || "实时曲谱").slice(0, 120), rows,
            attribution: doc.attribution || {}, segment: doc.segment,
        };
    }

    class Player {
        // send(event)须在原有协议ACK后resolve。release()只释放本次远程曲谱音符。
        // now为单调毫秒时钟；maxLateMs是中止阈值，不是实测音频延迟保证。
        constructor({ send, release, onState = () => {}, now = () => performance.now(),
            setTimer = (callback, delay) => setTimeout(callback, delay),
            clearTimer = timer => clearTimeout(timer), maxLateMs = 250 }) {
            Object.assign(this, { send, release, onState, now, setTimer, clearTimer, maxLateMs });
            this.run = null;
        }
        get busy() { return !!this.run; }
        emit(run, state, extra = {}) {
            try { this.onState({ state, completed: run.index, total: run.rows.length,
                maxLateMs: run.maxLateMs, ...extra }); } catch (_) { /* 界面错误不能中断释放 */ }
        }
        wait(run, delay) {
            return new Promise(resolve => {
                run.wake = () => { this.clearTimer(run.timer); run.wake = null; resolve(); };
                run.timer = this.setTimer(run.wake, Math.max(0, Math.min(delay, 1000)));
            });
        }
        start(doc, mapping) {
            if (this.busy) throw Error("实时曲谱正在播放或停止中");
            const snapshot = validate(doc, mapping);
            const run = { rows: snapshot.rows, index: 0, maxLateMs: 0, cancelled: false };
            this.run = run;
            run.done = Promise.resolve().then(() => this.play(run));
            this.emit(run, "playing");
            return run.done;
        }
        async play(run) {
            // 所有事件共用一次起点。ACK等待不会逐音累加为新的节拍间隔。
            let due = this.now(), failure = null;
            try {
                for (const event of run.rows) {
                    due += event.deltaMs;
                    while (!run.cancelled && this.now() < due)
                        await this.wait(run, due - this.now());
                    if (run.cancelled) break;
                    const late = Math.max(0, this.now() - due);
                    run.maxLateMs = Math.max(run.maxLateMs, late);
                    if (late > this.maxLateMs)
                        throw Error("发送落后曲谱超过" + this.maxLateMs + "ms，已停止；请减少音轨或降低曲速后重试");
                    // 始终最多一条曲谱NOTE等待ACK，不把未来整首曲子塞入发送队列。
                    await this.send({ ...event });
                    run.index++;
                    run.maxLateMs = Math.max(run.maxLateMs, this.now() - due);
                    if (!run.cancelled && this.now() - due > this.maxLateMs)
                        throw Error("蓝牙确认落后曲谱超过" + this.maxLateMs + "ms，已停止");
                    this.emit(run, run.cancelled ? "stopping" : "playing");
                }
            } catch (error) { failure = error; }
            finally {
                // 停止发生在NOTE ON待确认时，也必须等它落定后再发送对应NOTE OFF。
                try { await this.release(); }
                catch (error) { failure ||= error; }
                this.run = null;
                this.emit(run, failure ? "error" : run.cancelled ? "stopped" : "finished",
                    { error: failure?.message || null });
            }
            if (failure) throw failure;
            return { completed: run.index, total: run.rows.length, maxLateMs: run.maxLateMs,
                stopped: run.cancelled };
        }
        stop() {
            const run = this.run;
            if (!run) return Promise.resolve();
            run.cancelled = true;
            run.wake?.();
            this.emit(run, "stopping");
            return run.done;
        }
    }
    return { Player, validate, MAX_EVENTS, MAX_DURATION_MS };
});
