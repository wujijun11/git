/* 桌面曲谱播放协调层：连接生命周期、远程音符归属和播放状态显示。
 * Windows原生连接使用native-score-player；网页/Demo保留realtime-score调度。
 */
class DesktopRealtimePlayback {
    constructor({ controller, getConnection, getScore, assertIdle, statusNode, message, beforeStart = () => {} }) {
        Object.assign(this, { controller, getConnection, getScore, assertIdle, statusNode, message, beforeStart });
        this.starting = false;
        this.notes = new Set();
        this.player = new RealtimeScore.Player({
            send: event => this.send(event),
            release: () => this.release(),
            onState: state => this.render(state),
        });
        this.nativePlayer = new NativeScorePlayer(controller, state => this.render(state));
    }
    get busy() { return this.starting || this.player.busy || this.nativePlayer.busy; }
    sameConnection() { return this.connection === this.getConnection() && this.controller.ready; }
    async send(event) {
        if (!this.sameConnection()) throw Error("蓝牙连接已变化，实时播放停止");
        const id = "realtime:" + event.midi;
        if (event.on) {
            this.notes.add(id);
            await this.controller.noteOn(id, event.midi, event.velocity, this.timbre);
        } else {
            await this.controller.noteOff(id);
            this.notes.delete(id);
        }
    }
    async release() {
        // 不向重连后的设备发送旧曲谱松键，也不释放其他手动琴键。
        const ids = [...this.notes];
        this.notes.clear();
        if (!this.sameConnection()) return;
        for (const id of ids) await this.controller.noteOff(id);
    }
    render(state) {
        const names = { playing: "实时播放", stopping: "正在停止", stopped: "已停止",
            finished: "播放完成", error: "播放中止" };
        this.statusNode.textContent = `${names[state.state]} · ${state.completed}/${state.total} 条事件 · 最大发送至确认滞后 ${state.maxLateMs.toFixed(1)} ms` +
            (state.error ? " · " + state.error : "");
        if (state.error) this.message(state.error, true);
    }
    start() {
        if (this.busy) throw Error("实时曲谱正在播放或停止中");
        this.assertIdle();
        if (!this.controller.ready) throw Error("请先连接FPGA");
        const score = this.getScore();
        if (score.builtin) throw Error("板上内置曲谱没有本地事件；请选择小星星或导入MIDI");
        const snapshot = RealtimeScore.validate(score, this.controller.mapping);
        this.beforeStart();
        this.connection = this.getConnection();
        this.cancelled = false;
        this.starting = true;
        // 先登记任务，停止/断开在准备阶段也能取消。设备ACK之后才设曲谱时间起点。
        this.done = Promise.resolve().then(async () => {
            try {
                const check = () => {
                    if (this.cancelled || !this.sameConnection()) throw Error("实时播放已取消");
                };
                check();
                await this.controller.releaseAll();
                check();
                const state = await this.controller.readStatus();
                check();
                if (state.recording) throw Error("请先停止录制再实时播放");
                await this.controller.transportAction(0);
                check();
                if (this.controller.boardMode) await this.controller.readBoardMode();
                check();
                this.timbre = this.controller.timbre;
                this.starting = false;
                if (this.controller.supportsNativePlayback())
                    return await this.nativePlayer.start(snapshot, this.timbre);
                return await this.player.start(snapshot);
            } finally { this.starting = false; }
        });
        return this.done;
    }
    stop() {
        this.cancelled = true;
        if (this.player.busy) this.player.stop().catch(() => {});
        if (this.nativePlayer.busy) this.nativePlayer.stop().catch(() => {});
        return this.done ? this.done.catch(() => {}) : Promise.resolve();
    }
}
window.DesktopRealtimePlayback = DesktopRealtimePlayback;
