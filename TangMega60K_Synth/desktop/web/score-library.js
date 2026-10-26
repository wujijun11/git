"use strict";
/* 曲库界面：不直接操作BLE/UART。接收准备好的事件，交给原有上传流程。 */
class ScoreLibraryPanel {
    constructor({
        root,
        getAPI,
        getMapping,
        getCapacity,
        setCapacity,
        accept,
        message,
    }) {
        Object.assign(this, {
            getAPI,
            getMapping,
            getCapacity,
            setCapacity,
            accept,
            message,
        });
        this.offset = 0;
        this.query = "";
        this.files = [];
        this.prepared = null;
        this.busy = false;
        this.previewToken = 0;
        this.recommendBatch = 0;
        this.recommendBusy = false;
        this.recommendLoaded = false;
        root.insertAdjacentHTML(
            "afterbegin",
            `<section class="panel music-library" aria-labelledby="musicLibraryTitle">
   <div class="panel-top"><h2 id="musicLibraryTitle">找一首，弹起来</h2><span>Mutopia 公开曲库</span></div>
   <p>搜索曲名或作者，也可以打开自己的 MIDI。先选音轨与片段，再选择播放方式；板上上传容量 <span class="music-capacity">1024</span> 条事件，蓝牙实时曲谱最多10万条。</p>
   <label class="music-profile">板上曲谱程序 <select class="music-capacity-select"><option value="1024">新版 · 1024 条</option><option value="256">旧版兼容 · 256 条</option></select> 请与已下载的程序匹配；软件不能自动识别旧固件容量。</label>
   <form class="music-search"><label for="musicQuery">曲名 / 作者</label><input id="musicQuery" maxlength="80" placeholder="例如 Bach、Mozart、sonata" required><button class="button primary" type="submit">搜索</button><button class="button" type="button" data-action="local">打开 MIDI / ZIP</button></form>
   <p class="music-status" role="status">搜索需要网络；已搜索过的结果可从本机缓存读取。不是所有流行歌曲都有公开 MIDI。</p>
   <section class="music-recommendations" aria-labelledby="recommendTitle"><div class="music-recommend-heading"><div><h3 id="recommendTitle">不知道弹什么？看看这些</h3><p>从公开曲库轮换推荐，优先展示钢琴独奏。先查看音轨和片段，再检查能否上传。</p></div><div class="data-actions"><button class="button" data-action="recommend-next" type="button">换一批</button><button class="button" data-action="recommend-refresh" type="button">刷新曲库</button></div></div><p class="music-recommend-status" role="status">打开曲库页后加载推荐，也可点击“换一批”。</p><div class="music-recommend-list"></div></section>
   <div class="music-workspace"><div><div class="music-results"></div><div class="data-actions"><button class="button" data-action="previous" disabled>上一页</button><button class="button" data-action="next" disabled>下一页</button></div></div>
   <div class="music-editor" hidden><label>文件<select class="music-file"></select></label><fieldset><legend>导入哪些音轨</legend><div class="music-tracks"></div></fieldset>
    <div class="music-range"><label>开始（秒）<input class="music-start" type="number" min="0" step="0.001" value="0"></label><label>结束（秒）<input class="music-end" type="number" min="0.001" step="0.001"></label></div>
    <label>播放方式<select class="music-transport"><option value="board">上传后由 FPGA 定时播放</option><option value="realtime">蓝牙实时播放 · 曲谱留在上位机</option></select></label>
    <label class="music-check"><input class="music-direct" type="checkbox">脱离25键直接播放（FPGA当前音色，上传需 DirectScore 新版板上程序）</label>
    <small>上传受板上容量限制；蓝牙实时播放支持最多10万条事件、MIDI 0–127，窗口切到后台仍会继续。请保持程序运行和设备连接。两者共用64声部。</small>
    <label class="music-check"><input class="music-compact" type="checkbox">按片段音高重新安排 25 键（将更改实体琴键音高）</label>
    <button class="button" data-action="prepare">分析所选片段</button>
    <div class="music-analysis" aria-live="polite"></div><canvas class="music-roll" width="720" height="160" aria-label="所选片段的音符与时间预览"></canvas>
    <label class="music-check"><input class="music-agree" type="checkbox">已确认转换提示：使用 FPGA 当前音色，导入音符与力度，忽略原 MIDI 的音色及未支持控制。</label>
    <div class="data-actions"><button class="button" data-action="listen" disabled>电脑试听片段</button><button class="button" data-action="quiet">停止试听</button><button class="button primary" data-action="accept" disabled>导入为当前曲谱</button></div>
    <small>导入后，按所选方式点击“上传到 FPGA”或“蓝牙实时播放”。电脑试听不代表 FPGA 实际音色。</small>
   </div></div></section>`,
        );
        this.root = root.querySelector(".music-library");
        this.$ = (selector) => this.root.querySelector(selector);
        this.root.querySelector("form").onsubmit = (event) => {
            event.preventDefault();
            this.run(() => {
                this.query = this.$("#musicQuery").value.trim();
                this.offset = 0;
                return this.search();
            });
        };
        this.root.addEventListener("click", (event) => {
            const button = event.target.closest("[data-action]");
            if (!button) return;
            const action = button.dataset.action;
            if (action === "recommend-next") {
                this.recommend(this.recommendBatch + 1, false);
                return;
            }
            if (action === "recommend-refresh") {
                this.recommend(this.recommendBatch, true);
                return;
            }
            if (action === "quiet") return this.stopPreview();
            this.run(async () => {
                if (action === "local") {
                    const result = this.check(await this.api().load_midi());
                    if (!result.cancelled) this.loadFiles(result.files);
                }
                if (action === "previous") {
                    this.offset = Math.max(0, this.offset - 10);
                    await this.search();
                }
                if (action === "next") {
                    this.offset += 10;
                    await this.search();
                }
                if (action === "fetch")
                    this.loadFiles(
                        this.check(
                            await this.api().fetch_music(button.dataset.token),
                        ).files,
                    );
                if (action === "prepare") await this.prepare();
                if (action === "listen") await this.listen();
                if (action === "accept") {
                    if (
                        !(this.prepared?.canUpload || this.prepared?.canStream) ||
                        !this.$(".music-agree").checked
                    )
                        throw Error("请先分析片段并确认转换提示");
                    this.accept(this.prepared.score);
                }
            });
        });
        this.$(".music-file").onchange = () => this.selectFile();
        this.$(".music-capacity-select").value = String(this.getCapacity());
        this.$(".music-capacity-select").onchange = () => {
            try {
                this.setCapacity(
                    Number(this.$(".music-capacity-select").value),
                );
                this.$(".music-capacity").textContent = String(
                    this.getCapacity(),
                );
                this.invalidate();
            } catch (error) {
                this.message(error.message, true);
            } finally {
                this.$(".music-capacity-select").value = String(
                    this.getCapacity(),
                );
            }
        };
        this.$(".music-editor").addEventListener("change", (event) => {
            if (event.target.matches(".music-transport")) {
                const realtime = event.target.value === "realtime";
                this.$(".music-direct").disabled = realtime;
                this.$(".music-compact").disabled = realtime || this.$(".music-direct").checked;
            }
            if (event.target.matches(".music-direct")) {
                this.$(".music-compact").disabled=event.target.checked;
            }
            if (event.target.matches(".music-agree")) this.updateButtons();
            else if (!event.target.matches(".music-file")) this.invalidate();
        });
        window.addEventListener("beforeunload", () => this.stopPreview());
        document.addEventListener("visibilitychange", () => {
            if (document.hidden) this.stopPreview();
        });
        const observer = new IntersectionObserver((entries) => {
            if (
                entries.some((entry) => entry.isIntersecting) &&
                !this.recommendLoaded &&
                this.getAPI()?.recommend_music
            ) {
                this.recommendLoaded = true;
                this.recommend(0, false);
                observer.disconnect();
            }
        });
        observer.observe(this.$(".music-recommendations"));
    }
    api() {
        const api = this.getAPI();
        if (!api?.search_music)
            throw Error("请使用包含曲库功能的新版 Windows 程序");
        return api;
    }
    check(result) {
        if (!result?.ok) throw Error(result?.error || "曲库操作失败");
        return result;
    }
    async run(action) {
        if (this.busy) return;
        this.busy = true;
        this.root.setAttribute("aria-busy", "true");
        try {
            await action();
        } catch (error) {
            this.$(".music-status").textContent = error.message;
            this.message(error.message, true);
        } finally {
            this.busy = false;
            this.root.removeAttribute("aria-busy");
        }
    }
    async search() {
        this.$(".music-status").textContent = "正在搜索…";
        const result = this.check(
            await this.api().search_music(this.query, this.offset),
        );
        this.$(".music-results").replaceChildren();
        for (const item of result.items) {
            const row = document.createElement("article");
            row.className = "music-result";
            const title = document.createElement("h3");
            title.textContent = item.title;
            const detail = document.createElement("p");
            detail.textContent = `${item.composer} · ${item.instruments}`;
            const credit = document.createElement("p");
            credit.textContent = item.license;
            const button = document.createElement("button");
            button.className = "button";
            button.dataset.action = "fetch";
            button.dataset.token = item.token;
            button.textContent = item.midiUrl ? "查看音轨与片段" : "没有 MIDI";
            button.disabled = !item.midiUrl;
            row.append(title, detail, credit, button);
            this.$(".music-results").append(row);
        }
        this.$("[data-action=previous]").disabled = this.offset === 0;
        this.$("[data-action=next]").disabled = !result.hasNext;
        this.$(".music-status").textContent =
            `${result.items.length} 首结果 · 第 ${Math.floor(this.offset / 10) + 1} 页${result.offline ? " · 联网失败，显示旧缓存" + (result.offlineReason ? "（" + result.offlineReason + "）" : "") : result.cached ? " · 本机缓存" : " · 已实时联网"}。保留每首曲目的来源与授权信息。`;
    }
    async recommend(batch, refresh) {
        if (this.recommendBusy) return;
        this.recommendBusy = true;
        const status = this.$(".music-recommend-status");
        this.root
            .querySelectorAll("[data-action^=recommend-]")
            .forEach((button) => (button.disabled = true));
        status.textContent = refresh ? "正在重新读取曲库…" : "正在寻找曲目…";
        try {
            if (!this.getAPI()?.recommend_music)
                throw Error("请使用包含推荐功能的新版Windows程序");
            const result = this.check(
                await this.getAPI().recommend_music(batch, refresh),
            );
            const fragment = document.createDocumentFragment();
            for (const item of result.items) {
                const row = document.createElement("article");
                row.className = "music-recommend-card";
                const title = document.createElement("h4"),
                    detail = document.createElement("p"),
                    reason = document.createElement("small"),
                    button = document.createElement("button");
                title.textContent = item.title;
                detail.textContent = `${item.composer} · ${item.license}`;
                reason.textContent =
                    item.recommendationReason || "曲库推荐 · 尚需检查容量";
                button.className = "button";
                button.dataset.action = "fetch";
                button.dataset.token = item.token;
                button.textContent = "查看并导入";
                row.append(title, detail, reason, button);
                fragment.append(row);
            }
            this.$(".music-recommend-list").replaceChildren(fragment);
            this.recommendBatch = batch;
            this.recommendLoaded = true;
            status.textContent = `${result.items.length}首推荐${result.offline ? " · 联网失败，显示旧缓存" + (result.offlineReason ? "（" + result.offlineReason + "）" : "") : result.cached ? " · 本机缓存" : " · 已实时联网"}。${result.note || "点击曲目查看音轨，再分析容量。"}`;
        } catch (error) {
            status.textContent =
                error.message +
                "；已有推荐保留，可重试或直接搜索/导入本地MIDI。";
        } finally {
            this.recommendBusy = false;
            this.root
                .querySelectorAll("[data-action^=recommend-]")
                .forEach((button) => (button.disabled = false));
        }
    }
    loadFiles(files) {
        this.stopPreview();
        this.files = files;
        const select = this.$(".music-file");
        select.replaceChildren();
        for (const [index, file] of files.entries()) {
            const option = new Option(file.name, String(index));
            select.add(option);
        }
        this.$(".music-editor").hidden = false;
        this.selectFile();
    }
    selectFile() {
        const file = this.files[Number(this.$(".music-file").value)];
        if (!file) return;
        this.$(".music-start").value = "0";
        this.$(".music-end").value = String(file.durationMs / 1000);
        this.$(".music-tracks").replaceChildren();
        for (const track of file.tracks) {
            const label = document.createElement("label"),
                check = document.createElement("input");
            check.type = "checkbox";
            check.value = String(track.index);
            check.checked = track.notes > 0;
            label.append(
                check,
                document.createTextNode(
                    `${track.name}（${track.notes} 次触发）`,
                ),
            );
            this.$(".music-tracks").append(label);
        }
        this.$(".music-status").textContent =
            `已打开 ${file.name}，${(file.durationMs / 1000).toFixed(2)} 秒。可取消伴奏轨或选择更短片段。`;
        this.invalidate();
    }
    invalidate() {
        this.stopPreview();
        this.prepared = null;
        this.$(".music-agree").checked = false;
        this.$(".music-analysis").textContent =
            "选择音轨与时间后，点击“分析所选片段”。";
        this.updateButtons();
    }
    updateButtons() {
        this.$("[data-action=accept]").disabled =
            !(this.prepared?.canUpload || this.prepared?.canStream) || !this.$(".music-agree").checked;
        this.$("[data-action=listen]").disabled =
            !this.prepared?.pianoRoll.length;
    }
    async prepare() {
        this.stopPreview();
        this.prepared = null;
        this.updateButtons();
        const file = this.files[Number(this.$(".music-file").value)];
        const options = {
            tracks: [
                ...this.root.querySelectorAll(".music-tracks input:checked"),
            ].map((el) => Number(el.value)),
            startMs: Math.round(Number(this.$(".music-start").value) * 1000),
            endMs: Math.round(Number(this.$(".music-end").value) * 1000),
            compact: this.$(".music-compact").checked,
            direct: this.$(".music-direct").checked,
            realtime: this.$(".music-transport").value === "realtime",
            mapping: this.getMapping().slice(),
            maxEvents: this.getCapacity(),
        };
        const result = this.check(
            await this.api().prepare_music(file.token, options),
        );
        this.prepared = result;
        this.$(".music-agree").checked = false;
        this.$(".music-analysis").textContent =
            `${result.eventCount} / ${result.maxEvents} 条事件，${result.pitchCount} 种音高，${(result.durationMs / 1000).toFixed(2)} 秒。\n` +
            [...result.errors, ...result.warnings].join("\n") +
            (result.canStream ? "\n可导入为蓝牙实时曲谱，导入后点击“蓝牙实时播放”。" : result.canUpload
                ? "\n片段容量符合当前 FPGA。"
                : "\n尚不能上传，请调整后重新分析。");
        this.drawRoll(result);
        this.updateButtons();
    }
    drawRoll(result) {
        const canvas = this.$("canvas"),
            ctx = canvas.getContext("2d");
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        const events = result.pianoRoll,
            pitches = events.map((event) => event.midi);
        if (!events.length) return;
        const low = pitches.reduce((a, b) => Math.min(a, b), 127) - 1;
        const high = pitches.reduce((a, b) => Math.max(a, b), 0) + 1,
            held = new Map();
        ctx.fillStyle = "#a9ead6";
        for (const event of events) {
            if (event.on) held.set(event.midi, event.ms);
            else if (held.has(event.midi)) {
                const start = held.get(event.midi);
                held.delete(event.midi);
                ctx.fillRect(
                    (start / result.durationMs) * canvas.width,
                    ((high - event.midi) / (high - low)) * 140 + 5,
                    Math.max(
                        2,
                        ((event.ms - start) / result.durationMs) * canvas.width,
                    ),
                    4,
                );
            }
        }
    }
    async listen() {
        this.stopPreview();
        const result = this.prepared;
        if (!result) return;
        if (result.pianoRoll.length > 4096 || result.durationMs > 600000)
            throw Error("电脑试听请选择10分钟内且不超过4096条事件的片段");
        const token = this.previewToken;
        this.audio ||= new AudioContext();
        await this.audio.resume();
        if (token !== this.previewToken) return;
        const base = this.audio.currentTime + 0.05,
            active = new Map(),
            nodes = [];
        this.previewNodes = nodes;
        for (const event of result.pianoRoll) {
            const time = base + event.ms / 1000;
            if (event.on) {
                const oscillator = this.audio.createOscillator(),
                    envelope = this.audio.createGain();
                oscillator.type = "triangle";
                oscillator.frequency.value =
                    440 * 2 ** ((event.midi - 69) / 12);
                envelope.gain.setValueAtTime(0, time);
                envelope.gain.linearRampToValueAtTime(
                    (event.velocity / 127) * 0.035,
                    time + 0.006,
                );
                oscillator.connect(envelope);
                envelope.connect(this.audio.destination);
                oscillator.start(time);
                active.set(event.midi, { oscillator, envelope });
                nodes.push({ oscillator, envelope });
            } else if (active.has(event.midi)) {
                const node = active.get(event.midi);
                active.delete(event.midi);
                node.envelope.gain.setTargetAtTime(0, time, 0.025);
                node.oscillator.stop(time + 0.2);
            }
        }
        this.previewCleanup = setTimeout(
            () => this.stopPreview(),
            result.durationMs + 500,
        );
    }
    stopPreview() {
        this.previewToken++;
        clearTimeout(this.previewCleanup);
        for (const { oscillator, envelope } of this.previewNodes || []) {
            try {
                oscillator.stop();
            } catch (_) {}
            oscillator.disconnect();
            envelope.disconnect();
        }
        this.previewNodes = [];
    }
}
window.ScoreLibraryPanel = ScoreLibraryPanel;
