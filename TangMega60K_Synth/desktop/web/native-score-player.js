/* Windows原生播放适配器：页面定时器仅刷新进度，延迟刷新不影响发送。
 * Demo/网页继续使用原JS调度器；不改变手机版。
 */
(function (root) {
    "use strict";
    let nextToken = 0;
    class NativeScorePlayer {
        constructor(controller, onState) {
            Object.assign(this, { controller, onState });
            this.run = null;
        }
        get busy() { return !!this.run; }
        async start(snapshot, timbre) {
            if (this.busy) throw Error("原生实时曲谱正在播放");
            const run = { token: "score_" + Date.now() + "_" + (++nextToken) };
            this.run = run;
            this.onState({ state: "playing", completed: 0, total: snapshot.rows.length, maxLateMs: 0 });
            const refresh = async () => {
                try {
                    const state = await this.controller.nativeScoreStatus(run.token);
                    if (this.run === run && state.state !== "idle") this.onState(state);
                } catch (_) { /* 断连由控制器处理；进度查询不承担保活职责。 */ }
                if (this.run === run) run.timer = setTimeout(refresh, 250);
            };
            run.timer = setTimeout(refresh, 250);
            run.done = this.controller.playNativeScore(snapshot, timbre, run.token);
            try {
                const result = await run.done;
                this.onState(result);
                if (result.error) throw Error(result.error);
                return result;
            } finally {
                clearTimeout(run.timer);
                if (this.run === run) this.run = null;
            }
        }
        async stop() {
            if (!this.run) return;
            this.controller.cancelBulk();
            await this.run.done?.catch(() => {});
        }
    }
    root.NativeScorePlayer = NativeScorePlayer;
    if (typeof module === "object" && module.exports) module.exports = { NativeScorePlayer };
})(typeof globalThis === "undefined" ? this : globalThis);
