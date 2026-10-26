/* 灯位与琴键对照界面。只渲染编号、定位和估计目标，不改变键位或控制硬件。 */
(function (root) {
    "use strict";
    const names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"];
    const noteName = midi => names[midi % 12] + (Math.floor(midi / 12) - 1);
    const number = key => String(key + 1).padStart(2, "0");

    class GuidePanel {
        constructor({ container, keyboard, getMapping, guideButton, learningButton }) {
            this.keyboard = keyboard;
            this.getMapping = getMapping;
            this.model = new root.GuideTimeline.GuideTimeline();
            this.located = null;
            this.lesson = null;
            this.learningButton = learningButton;
            this.lastRender = "";
            container.className = "guide-panel";
            container.innerHTML = `
                <div class="guide-diagram">
                    <div class="guide-diagram-title"><strong>灯位对照</strong><span>正面朝向你 ↑</span></div>
                    <div class="guide-matrix" id="guideMatrix" role="group" aria-label="5乘5灯位，编号1至25"></div>
                    <span class="guide-diagram-caption">点击编号，只定位，不发声</span>
                </div>
                <div class="guide-instructions">
                    <div class="guide-heading"><h3>灯亮哪一号，就弹哪一键</h3><span class="guide-state" id="guideMapState">编号对照</span></div>
                    <p>在灯板与琴键上贴相同的 1–25 编号。琴键从左到右编号，包含黑键。</p>
                    <div class="guide-current"><span>当前提示</span><strong id="guideTargets">等待开始</strong></div>
                    <p class="guide-score-name" id="guideScoreName">先选择曲谱，再开始灯光指引。</p>
                    <div class="guide-actions" id="guideActions"></div>
                    <div class="guide-location"><span id="guideLocateText">例如：点灯位 08，看下方同号琴键。</span><button type="button" id="guideLocateClear" hidden>清除定位</button></div>
                    <p class="guide-limit" id="guideMapNote">绿色为应按的键，紫框为编号定位。灯板到货后需校准实际灯位。</p>
                    <p class="guide-limit">节奏指引按时间走；学习模式等实体键按对才前进，每步先全部松开。</p>
                </div>`;
            this.nodes = Object.fromEntries(["guideMatrix", "guideMapState", "guideTargets", "guideScoreName",
                "guideActions", "guideLocateText", "guideLocateClear", "guideMapNote"].map(id => [id, container.querySelector("#" + id)]));
            this.nodes.guideActions.append(guideButton);
            if (learningButton) this.nodes.guideActions.append(learningButton);
            this.nodes.guideLocateClear.onclick = () => this.locate(null);
            this.cells = [];
            for (let key = 0; key < 25; key++) {
                const cell = document.createElement("button");
                cell.type = "button";
                cell.className = "guide-cell";
                cell.dataset.key = String(key);
                cell.innerHTML = `<strong>${number(key)}</strong><small></small>`;
                cell.onclick = () => this.locate(key);
                this.nodes.guideMatrix.append(cell);
                this.cells.push(cell);
                const badge = document.createElement("span");
                badge.className = "guide-key-number";
                badge.textContent = number(key);
                badge.setAttribute("aria-hidden", "true");
                this.keyboard.children[key].append(badge);
            }
            this.render(performance.now());
            this.frame = () => {
                this.render(performance.now());
                this.frameId = requestAnimationFrame(this.frame);
            };
            this.frameId = requestAnimationFrame(this.frame);
        }

        locate(key) {
            this.located = key;
            this.render(performance.now());
        }

        learning(status, title, demo) {
            this.lesson = { ...status, title: title || this.lesson?.title || "板上曲谱", demo, at: performance.now() };
            this.render(performance.now());
        }

        arm(score, demo) {
            this.lesson = null;
            this.model.arm(score, performance.now(), demo);
            this.render(performance.now());
        }

        accept(status) {
            this.model.accept(status, performance.now());
            this.render(performance.now());
        }

        clear(reason = "idle") {
            this.model.clear(reason);
            this.lesson = null;
            this.render(performance.now());
        }

        render(now) {
            const lesson = this.lesson;
            const stale = lesson?.active && now - lesson.at > 3000;
            const state = lesson ? {phase: stale ? "stale" : lesson.active ? "learning" : lesson.finished ? "learned" : "idle",
                mask: stale ? 0 : lesson.targetMask, title: lesson.title, demo: lesson.demo} : this.model.snapshot(now);
            const mapping = this.getMapping();
            const signature = JSON.stringify([state.phase, state.mask, state.title, this.located, mapping, lesson?.completedSteps, lesson?.waitingRelease, lesson?.sensorReady]);
            if (signature === this.lastRender) return;
            this.lastRender = signature;
            const targets = [];
            for (let key = 0; key < 25; key++) {
                const lit = !!(state.mask & (1 << key));
                const located = this.located === key;
                const description = `灯位${number(key)}，琴键${number(key)}，映射${noteName(mapping[key])}`;
                this.cells[key].classList.toggle("is-target", lit);
                this.cells[key].classList.toggle("is-located", located);
                this.cells[key].setAttribute("aria-pressed", String(located));
                this.cells[key].setAttribute("aria-label", description + (lit ? "，当前应按" : ""));
                this.cells[key].querySelector("small").textContent = noteName(mapping[key]);
                this.keyboard.children[key].classList.toggle("guide-target", lit);
                this.keyboard.children[key].classList.toggle("guide-locate", located);
                if (lit) targets.push(number(key));
            }
            if (this.learningButton) {
                this.learningButton.textContent = lesson?.active ? "停止学习" : "等我弹对";
                this.learningButton.classList.toggle("on", !!lesson?.active);
                this.learningButton.setAttribute("aria-pressed", String(!!lesson?.active));
            }
            const active = state.phase === "active";
            const statusText = { idle: "编号对照", pending: "等待开始确认", finished: "指引已结束",
                unknown: "板上指引运行中", mismatch: "曲谱对应已失效", stale: "等待状态回传", disconnected: "设备未连接" };
            this.nodes.guideMapState.textContent = active ? (state.demo ? "离线演示跟谱" : "跟谱估计") : statusText[state.phase] || "编号对照";
            this.nodes.guideTargets.textContent = active ? (targets.length ? targets.join(" + ") + " 号键" : "松开，等待下一拍") : "—";
            this.nodes.guideTargets.classList.toggle("has-target", targets.length > 0);
            this.nodes.guideScoreName.textContent = state.title ? `正在跟随：${state.title}` : "先选择曲谱，再从本页开始灯光指引。";
            this.nodes.guideLocateClear.hidden = this.located === null;
            this.nodes.guideLocateText.textContent = this.located === null
                ? "例如：点灯位 08，看下方同号琴键。"
                : `灯位 ${number(this.located)} ↔ 琴键 ${number(this.located)} · 映射 ${noteName(mapping[this.located])}`;
            this.nodes.guideMapNote.textContent = state.phase === "stale"
                ? "状态回传暂缺，已暂停屏幕高亮；这不代表板上灯已停止。"
                : ["unknown", "mismatch"].includes(state.phase)
                    ? "无法确认板上正在使用哪首曲谱。请停止后从本页重新开始指引。"
                    : active || state.phase === "pending"
                        ? "屏幕按曲谱估计进度，并用板上回传校正；可能有延迟，不是实物灯反馈。"
                        : "绿色为应按的键，紫框为编号定位。灯板到货后需校准实际灯位。";
            if (lesson && !stale) {
                this.nodes.guideMapState.textContent = lesson.active ? (lesson.demo ? "离线模拟学习" : "板上学习中") : lesson.finished ? "本曲学习完成" : "学习已停止";
                this.nodes.guideTargets.textContent = lesson.active
                    ? !lesson.sensorReady ? "等待触摸传感器就绪"
                    : lesson.waitingRelease ? "先松开全部琴键"
                    : targets.length ? targets.join(" + ") + " 号键" : "正在准备下一组"
                    : lesson.finished ? "完成！" : "—";
                this.nodes.guideScoreName.textContent = `${lesson.title} · 已完成 ${lesson.completedSteps} 步`;
                this.nodes.guideMapNote.textContent = lesson.demo
                    ? "离线演示可用电脑琴键练习；实物模式由FPGA读取实体触摸键判断。"
                    : "绿色目标直接来自FPGA状态。按错不前进；和弦要全部按齐且不多按。此模式不考核节奏。";
            }
        }

        dispose() {
            cancelAnimationFrame(this.frameId);
        }
    }
    root.GuidePanel = GuidePanel;
})(typeof window !== "undefined" ? window : globalThis);
