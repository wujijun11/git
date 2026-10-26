/* 跟谱数据模型。仅从曲谱与已回传的事件位置估计目标键，不发送命令或生成声音。 */
(function (root) {
    "use strict";

    // 当前工程performance_controller.builtin_row的32条事件。
    // 演示器的内置谱节奏不同，必须分别取值，不能冒充板上实测。
    function builtinRows(demo = false) {
        const keys = demo
            ? [4, 4, 5, 7, 7, 5, 4, 2, 0, 0, 2, 4, 4, 2, 2, 4]
            : [4, 4, 5, 7, 7, 5, 4, 2, 0, 0, 2, 4, 4, 2, 2, 0];
        return keys.flatMap((key, index) => [
            { key, on: 1, velocity: 100, deltaMs: index ? (demo ? 40 : 100) : 0 },
            { key, on: 0, velocity: 0, deltaMs: demo ? 280 : (index === 15 ? 800 : 400) },
        ]);
    }

    /** 将0–24键位、毫秒间隔的事件编译成时间及25位目标掩码快照。 */
    function compile(score, demo = false) {
        if (!score || score.playback === "direct" || score.transport === "realtime") {
            throw new Error("跟谱灯图需要25键映射曲谱");
        }
        const rows = score.builtin ? builtinRows(demo) : score.rows;
        if (!Array.isArray(rows) || !rows.length || rows.length > 1024) {
            throw new Error("跟谱曲谱必须包含1–1024条事件");
        }
        const times = [], masks = [0];
        let elapsed = 0, mask = 0;
        for (const row of rows) {
            if (!Number.isInteger(row.key) || row.key < 0 || row.key > 24 ||
                !Number.isInteger(row.deltaMs) || row.deltaMs < 0 || row.deltaMs > 0xffffffff ||
                ![0, 1].includes(row.on) || !Number.isInteger(row.velocity) ||
                row.velocity < 0 || row.velocity > 127) {
                throw new Error("无效的25键指引事件");
            }
            elapsed += row.deltaMs;
            times.push(elapsed);
            // 与RTL一致：力度为0的NoteOn也释放该键；重复按下不会累计计数。
            mask = row.on && row.velocity ? mask | (1 << row.key) : mask & ~(1 << row.key);
            masks.push(mask);
        }
        return { title: String(score.title || "当前曲谱"), times, masks, count: rows.length };
    }

    class GuideTimeline {
        constructor({ staleMs = 1800 } = {}) {
            this.staleMs = staleMs;
            this.clear();
        }

        clear(reason = "idle") {
            this.score = null;
            this.phase = reason;
            this.position = 0;
            this.lastStatusAt = null;
        }

        /** 在启动命令发送前调用。now为performance.now()的单调毫秒数。 */
        arm(score, now, demo = false) {
            this.score = compile(score, demo);
            this.epoch = now;
            this.position = 0;
            this.lastStatusAt = null;
            this.phase = "pending";
            this.demo = demo;
        }

        /** position为FPGA已经处理的事件数量，必须从同一连接的状态回传获得。 */
        accept(status, now) {
            if (!status.guide) {
                if (this.score) this.clear("finished");
                else if (this.phase === "unknown") this.clear();
                return;
            }
            if (!this.score) {
                this.phase = "unknown";
                return;
            }
            const position = status.scorePosition;
            if (status.playing || status.recording || !Number.isInteger(position) ||
                position < this.position || position > this.score.count) {
                this.clear("mismatch");
                return;
            }
            // 协议没有板端时间戳。利用事件位置限定估计进度，而非声称读取实物灯色。
            const lower = position ? this.score.times[position - 1] : 0;
            const upper = position < this.score.count ? this.score.times[position] : Infinity;
            const estimated = Math.max(0, now - this.epoch);
            if (estimated < lower) this.epoch = now - lower;
            else if (estimated >= upper && upper > lower) this.epoch = now - Math.max(lower, upper - 1);
            this.position = position;
            this.lastStatusAt = now;
            this.phase = "active";
        }

        snapshot(now) {
            const base = { phase: this.phase, mask: 0, title: this.score?.title || "", demo: this.demo };
            if (this.phase !== "active") return base;
            if (now - this.lastStatusAt > this.staleMs) return { ...base, phase: "stale" };
            const elapsed = Math.max(0, now - this.epoch);
            // 二分查找一次处理同一时刻的所有音符，和弦同时高亮；不排队补播旧动画。
            let left = this.position, right = this.score.count;
            while (left < right) {
                const middle = (left + right) >>> 1;
                if (this.score.times[middle] <= elapsed) left = middle + 1;
                else right = middle;
            }
            return { ...base, mask: left === this.score.count ? 0 : this.score.masks[left], position: left };
        }
    }

    const api = { GuideTimeline, compile, builtinRows };
    if (typeof module !== "undefined") module.exports = api;
    root.GuideTimeline = api;
})(typeof window !== "undefined" ? window : globalThis);
