/* 手机曲库界面：搜索/分页、选轨、片段检查和显式导入，不管理BLE连接。 */
(function (root) {
    "use strict";
    class MobileMusicPanel {
        constructor({ getMapping, getCapacity, accept, message }) {
            Object.assign(this, { getMapping, getCapacity, accept, message });
            this.api = new root.MobileMusicLibrary();
            this.offset = 0;
            this.busy = false;
            this.result = null;
            this.recommendBatch = 0;
            this.recommendBusy = false;
            this.recommendLoaded = false;
            this.$ = (id) => document.getElementById(id);
            this.$("musicSearch").onsubmit = (event) => {
                event.preventDefault();
                this.offset = 0;
                this.query = this.$("musicQuery").value.trim();
                this.run(() => this.search());
            };
            this.$("musicPrevious").onclick = () =>
                this.run(() => {
                    this.offset = Math.max(0, this.offset - 10);
                    return this.search();
                });
            this.$("musicNext").onclick = () =>
                this.run(() => {
                    this.offset += 10;
                    return this.search();
                });
            this.$("midiFile").onchange = () =>
                this.run(async () => {
                    const file = this.$("midiFile").files[0];
                    if (file) this.load(await this.api.open(file));
                });
            this.$("musicFile").onchange = () => this.select();
            this.$("musicAnalyze").onclick = () =>
                this.run(() => this.analyze());
            this.$("musicAccept").onclick = () =>
                this.run(() => {
                    if (
                        !this.result ||
                        !(this.result.canUpload || this.result.canStream) ||
                        !this.$("musicAgree").checked
                    )
                        throw Error("请先分析并确认转换提示");
                    this.accept(this.result.score);
                    this.$("musicStatus").textContent =
                        this.result.canStream ? "已导入实时曲谱；连接FPGA后点击“蓝牙实时播放”。" :
                        "已导入当前曲谱；连接FPGA后点击“上传并提交曲谱”。";
                });
            this.$("musicAgree").onchange = () => this.buttons();
            for (const id of ["musicStart", "musicEnd", "musicCompact"])
                this.$(id).onchange = () => this.invalidate();
            this.$("musicDirect").onchange=()=>{
                this.$("musicCompact").disabled=this.$("musicDirect").checked;
                this.invalidate();
            };
            this.$("musicTransport").onchange = () => {
                const realtime = this.$("musicTransport").value === "realtime";
                this.$("musicDirect").disabled = realtime;
                this.$("musicCompact").disabled = realtime || this.$("musicDirect").checked;
                this.invalidate();
            };
            this.$("musicRecommendNext").onclick = () =>
                this.recommend(this.recommendBatch + 1, false);
            this.$("musicRecommendRefresh").onclick = () =>
                this.recommend(this.recommendBatch, true);
            const observer = new IntersectionObserver((entries) => {
                if (
                    entries.some((entry) => entry.isIntersecting) &&
                    !this.recommendLoaded &&
                    root.AndroidBle?.musicRequest
                ) {
                    this.recommendLoaded = true;
                    this.recommend(0, false);
                    observer.disconnect();
                }
            });
            observer.observe(this.$("musicRecommendations"));
        }
        async run(action) {
            if (this.busy) return;
            this.busy = true;
            this.$("musicLibrary").setAttribute("aria-busy", "true");
            try {
                await action();
            } catch (error) {
                this.$("musicStatus").textContent = error.message;
                this.message(error.message);
            } finally {
                this.busy = false;
                this.$("musicLibrary").removeAttribute("aria-busy");
            }
        }
        async search() {
            this.$("musicStatus").textContent = "正在搜索公开授权曲库…";
            const data = await this.api.search(this.query, this.offset);
            const list = this.$("musicResults");
            list.replaceChildren();
            for (const item of data.items) {
                const row = document.createElement("article"),
                    title = document.createElement("strong"),
                    detail = document.createElement("p"),
                    button = document.createElement("button");
                title.textContent = item.title;
                detail.textContent = `${item.composer} · ${item.instruments}\n${item.license}`;
                button.textContent = item.midiUrl
                    ? "查看音轨与片段"
                    : "没有MIDI";
                button.disabled = !item.midiUrl;
                button.onclick = () =>
                    this.run(async () => {
                        this.load(await this.api.fetch(item));
                    });
                row.append(title, detail, button);
                list.append(row);
            }
            this.$("musicPrevious").disabled = this.offset === 0;
            this.$("musicNext").disabled = !data.hasNext;
            this.$("musicStatus").textContent =
                `${data.items.length}首 · 第${this.offset / 10 + 1}页${data.offline ? " · 离线旧缓存" : data.cached ? " · 本机缓存" : ""}。流行歌曲未必有公开授权MIDI。`;
        }
        async recommend(batch, refresh) {
            if (this.recommendBusy) return;
            this.recommendBusy = true;
            const status = this.$("musicRecommendStatus");
            this.$("musicRecommendNext").disabled = this.$(
                "musicRecommendRefresh",
            ).disabled = true;
            status.textContent = refresh
                ? "正在重新读取曲库…"
                : "正在寻找曲目…";
            try {
                const data = await this.api.recommend(batch, refresh),
                    fragment = document.createDocumentFragment();
                for (const item of data.items) {
                    const row = document.createElement("article"),
                        title = document.createElement("strong"),
                        detail = document.createElement("p"),
                        button = document.createElement("button");
                    title.textContent = item.title;
                    detail.textContent = `${item.composer} · ${item.license}\n${item.recommendationReason || "尚需检查容量"}`;
                    button.textContent = "查看并导入";
                    button.onclick = () =>
                        this.run(async () =>
                            this.load(await this.api.fetch(item)),
                        );
                    row.append(title, detail, button);
                    fragment.append(row);
                }
                this.$("musicRecommendList").replaceChildren(fragment);
                this.recommendBatch = batch;
                this.recommendLoaded = true;
                status.textContent = `${data.items.length}首推荐${data.offline ? " · 联网失败，显示旧缓存" : data.cached ? " · 本机缓存" : " · 已读取曲库"}。${data.note || "先查看音轨与片段，再分析容量。"}`;
            } catch (error) {
                status.textContent =
                    error.message + "；已有推荐保留，可重试或导入本地MIDI。";
            } finally {
                this.recommendBusy = false;
                this.$("musicRecommendNext").disabled = this.$(
                    "musicRecommendRefresh",
                ).disabled = false;
            }
        }
        load(files) {
            this.files = files;
            const select = this.$("musicFile");
            select.replaceChildren();
            files.forEach((file, i) =>
                select.add(new Option(file.name, String(i))),
            );
            this.$("musicEditor").hidden = false;
            this.select();
        }
        select() {
            const file = this.files[Number(this.$("musicFile").value)];
            if (!file) return;
            this.$("musicStart").value = "0";
            this.$("musicEnd").value = String(file.durationMs / 1000);
            const tracks = this.$("musicTracks");
            tracks.replaceChildren();
            for (const track of file.tracks) {
                const label = document.createElement("label"),
                    check = document.createElement("input");
                check.type = "checkbox";
                check.value = String(track.index);
                check.checked = track.notes > 0;
                check.onchange = () => this.invalidate();
                label.append(
                    check,
                    document.createTextNode(
                        `${track.name}（${track.notes}个音）`,
                    ),
                );
                tracks.append(label);
            }
            this.invalidate();
            this.$("musicStatus").textContent =
                `${file.name} · ${(file.durationMs / 1000).toFixed(2)}秒。可只选择旋律轨或较短片段。`;
        }
        invalidate() {
            this.result = null;
            this.$("musicAgree").checked = false;
            this.$("musicAnalysis").textContent =
                "选择音轨及片段后，点击分析。";
            this.buttons();
        }
        buttons() {
            this.$("musicAccept").disabled =
                !this.result ||
                !(this.result.canUpload || this.result.canStream) ||
                !this.$("musicAgree").checked;
        }
        analyze() {
            const file = this.files[Number(this.$("musicFile").value)];
            this.result = this.api.prepare(file.token, {
                tracks: [
                    ...this.$("musicTracks").querySelectorAll("input:checked"),
                ].map((el) => Number(el.value)),
                startMs: Math.round(Number(this.$("musicStart").value) * 1000),
                endMs: Math.round(Number(this.$("musicEnd").value) * 1000),
                compact: this.$("musicCompact").checked,
                direct: this.$("musicDirect").checked,
                realtime: this.$("musicTransport").value === "realtime",
                mapping: this.getMapping(),
                maxEvents: this.getCapacity(),
            });
            this.$("musicAgree").checked = false;
            const result = this.result;
            this.$("musicAnalysis").textContent =
                `${result.eventCount}/${result.maxEvents}条事件 · ${result.pitchCount}种音高\n` +
                [...result.errors, ...result.warnings].join("\n") +
                (result.canStream ? "\n可以导入；之后点击蓝牙实时播放，保持应用前台运行。" : result.canUpload
                    ? "\n可以导入；声音由FPGA当前音色实时合成。"
                    : "\n请缩短片段或减少音轨后重试。");
            this.buttons();
        }
    }
    root.MobileMusicPanel = MobileMusicPanel;
})(typeof globalThis === "undefined" ? window : globalThis);
