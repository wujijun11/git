/* 手机播放协调层。NOTE仍走已有Session；记录发送时的会话和音色，防止重连串音。 */
class MobileRealtimePlayback {
    constructor({ getSession, isReady, getScore, getMapping, getTimbre, assertIdle,
        prepare, sendNote, statusNode, message }) {
        Object.assign(this, { getSession, isReady, getScore, getMapping, getTimbre,
            assertIdle, prepare, sendNote, statusNode, message });
        this.starting = false;
        this.notes = new Set();
        this.player = new RealtimeScore.Player({
            send: event => this.send(event), release: () => this.release(),
            onState: state => {
                const names = { playing: "实时播放", stopping: "正在停止", stopped: "已停止",
                    finished: "播放完成", error: "播放中止" };
                statusNode.textContent = `${names[state.state]} · ${state.completed}/${state.total} 条事件 · 最大发送至确认滞后 ${state.maxLateMs.toFixed(1)} ms` +
                    (state.error ? " · " + state.error : "");
                if (state.error) message(state.error);
            },
        });
    }
    get busy() { return this.starting || this.player.busy; }
    sameConnection() { return this.owner === this.getSession() && this.isReady(); }
    async send(event) {
        if (!this.sameConnection()) throw Error("蓝牙连接已变化，实时播放停止");
        if (event.on) this.notes.add(event.midi);
        await this.sendNote(event, this.timbre, this.owner);
        if (!event.on) this.notes.delete(event.midi);
    }
    async release() {
        const notes = [...this.notes];
        this.notes.clear();
        if (!this.sameConnection()) return;
        for (const midi of notes)
            await this.sendNote({ midi, velocity: 0, on: 0 }, this.timbre, this.owner);
    }
    start() {
        if (this.busy) throw Error("实时曲谱正在播放或停止中");
        this.assertIdle();
        if (!this.isReady()) throw Error("请先连接FPGA");
        const snapshot = RealtimeScore.validate(this.getScore(), this.getMapping());
        this.owner = this.getSession();
        this.cancelled = false;
        this.starting = true;
        this.done = Promise.resolve().then(async () => {
            try {
                const check = () => {
                    if (this.cancelled || !this.sameConnection()) throw Error("实时播放已取消");
                };
                check();
                await this.prepare(this.owner, check);
                check();
                this.timbre = this.getTimbre();
                this.starting = false;
                return await this.player.start(snapshot);
            } finally { this.starting = false; }
        });
        return this.done;
    }
    stop() {
        this.cancelled = true;
        if (this.player.busy) this.player.stop().catch(() => {});
        return this.done ? this.done.catch(() => {}) : Promise.resolve();
    }
}
window.MobileRealtimePlayback = MobileRealtimePlayback;
