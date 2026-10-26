/* 快捷键界面和输入分发。保存走本机偏好API，演奏继续调用既有声部控制器。 */
(function (root) {
    "use strict";
    const B = root.ShortcutBindings;
    const STORAGE = "tang.keyboard-bindings.v1";
    class KeyboardShortcutPanel {
        constructor({
            container,
            model,
            getAPI,
            beforeChange,
            onChange,
            message,
            canPlay,
            press,
            release,
            panic,
        }) {
            Object.assign(this, {
                model,
                getAPI,
                beforeChange,
                onChange,
                message,
                canPlay,
                press,
                release,
                panic,
            });
            this.draft = model.snapshot();
            this.revision = 0;
            this.capture = null;
            this.busy = false;
            this.section = document.createElement("section");
            this.section.id = "keyboardShortcuts";
            this.section.className = "panel data-panel keyboard-shortcuts";
            this.section.innerHTML = `<div class="section-label">COMPUTER KEYBOARD <span>/ 自定义电脑快捷键</span></div>
                <h2>用你习惯的按键演奏。</h2><p>点击下方琴键的“更改”，再按一个字母、数字或常用标点。每个电脑键只能分配一次；Esc始终为全部停止。此处不改变琴键的MIDI音高。</p>
                <p id="shortcutStatus" role="status" aria-live="polite">修改后点击“保存并应用”，重开软件仍会保留。</p>
                <div id="shortcutGrid" class="shortcut-grid"></div><div class="data-actions"><button id="saveShortcuts" class="button primary">保存并应用</button><button id="resetShortcuts" class="button">恢复默认布局</button><button id="cancelShortcuts" class="button">取消修改</button></div>`;
            container.append(this.section);
            this.status = this.section.querySelector("#shortcutStatus");
            this.grid = this.section.querySelector("#shortcutGrid");
            this.rows = [];
            for (let index = 0; index < 25; index++) {
                const row = document.createElement("div");
                row.className = "shortcut-item";
                const name = document.createElement("span");
                name.textContent = `第 ${index + 1} 琴键`;
                const value = document.createElement("kbd");
                value.id = `shortcut-value-${index}`;
                const edit = document.createElement("button");
                edit.type = "button";
                edit.textContent = "更改";
                edit.dataset.index = String(index);
                edit.className = "button compact shortcut-edit";
                edit.setAttribute(
                    "aria-label",
                    `更改第${index + 1}琴键的电脑快捷键`,
                );
                edit.onclick = () => this.beginCapture(index);
                const clear = document.createElement("button");
                clear.type = "button";
                clear.textContent = "清除";
                clear.className = "text-button shortcut-clear";
                clear.dataset.index = String(index);
                clear.setAttribute(
                    "aria-label",
                    `清除第${index + 1}琴键的电脑快捷键`,
                );
                clear.onclick = () => this.change(index, null);
                row.append(name, value, edit, clear);
                this.grid.append(row);
                this.rows.push({ row, value });
            }
            this.section.querySelector("#saveShortcuts").onclick = () =>
                this.save();
            this.section.querySelector("#resetShortcuts").onclick = () => {
                if (this.busy) return;
                this.capture = null;
                this.draft = B.defaults.slice();
                this.revision++;
                this.render();
                this.status.textContent = "已恢复默认草稿；点击保存后生效。";
            };
            this.section.querySelector("#cancelShortcuts").onclick = () => {
                if (this.busy) return;
                this.capture = null;
                this.draft = this.model.snapshot();
                this.revision++;
                this.render();
                this.status.textContent = "修改已取消，继续使用已保存布局。";
            };
            document.addEventListener(
                "keydown",
                (event) => this.keyDown(event),
                true,
            );
            document.addEventListener(
                "keyup",
                (event) => this.release("key:" + event.code),
                true,
            );
            root.addEventListener("blur", () => this.cancelCapture());
            document.addEventListener("visibilitychange", () => {
                if (document.hidden) this.cancelCapture();
            });
            root.addEventListener("pywebviewready", () => this.loadNative());
            this.loadBrowser();
            this.render();
            if (this.getAPI()?.load_key_bindings) this.loadNative();
        }
        render() {
            this.rows.forEach(({ row, value }, index) => {
                value.textContent = B.label(this.draft[index]);
                row.classList.toggle("capturing", index === this.capture);
            });
        }
        beginCapture(index) {
            if (this.busy) return;
            this.beforeChange();
            this.capture = index;
            this.revision++;
            this.render();
            this.status.textContent = `请按第${index + 1}琴键的新快捷键；Esc取消并全部停止。`;
        }
        change(index, code) {
            if (this.busy) return;
            try {
                this.draft = B.assign(this.draft, index, code);
                this.capture = null;
                this.revision++;
                this.render();
                this.status.textContent = `第${index + 1}琴键 → ${B.label(code)}；尚未保存。`;
            } catch (error) {
                this.status.textContent = error.message;
            }
        }
        cancelCapture() {
            if (this.capture === null) return;
            this.capture = null;
            this.render();
            this.status.textContent = "按键选择已取消；现有草稿保留。";
        }
        keyDown(event) {
            if (event.code === "Escape") {
                event.preventDefault();
                event.stopImmediatePropagation();
                this.cancelCapture();
                this.panic();
                return;
            }
            if (event.isComposing || event.keyCode === 229) return;
            if (this.capture !== null) {
                event.preventDefault();
                event.stopImmediatePropagation();
                if (event.repeat) return;
                if (event.ctrlKey || event.altKey || event.metaKey) {
                    this.status.textContent =
                        "请选择单个按键，不使用Ctrl、Alt或Win组合键。";
                    return;
                }
                this.change(this.capture, event.code);
                return;
            }
            if (
                event.repeat ||
                event.ctrlKey ||
                event.altKey ||
                event.metaKey ||
                !this.canPlay()
            )
                return;
            if (
                event.target.closest?.(
                    "input,select,textarea,[contenteditable]:not([contenteditable=false]),[role=textbox]",
                )
            )
                return;
            const index = this.model.index(event.code);
            if (index >= 0) {
                event.preventDefault();
                this.press("key:" + event.code, index);
            }
        }
        async save() {
            if (this.busy) return;
            this.busy = true;
            this.capture = null;
            this.render();
            this.section
                .querySelectorAll("button")
                .forEach((button) => (button.disabled = true));
            try {
                const codes = B.validate(this.draft);
                await this.beforeChange();
                const api = this.getAPI();
                if (api?.save_key_bindings) {
                    const result = await api.save_key_bindings(codes);
                    if (!result?.ok)
                        throw Error(result?.error || "快捷键保存失败");
                } else {
                    localStorage.setItem(
                        STORAGE,
                        JSON.stringify({ version: 1, codes }),
                    );
                }
                this.model.apply(codes);
                this.draft = this.model.snapshot();
                this.revision++;
                this.render();
                this.onChange();
                this.status.textContent =
                    "快捷键已保存并应用；只修改电脑操作，不改FPGA音高。";
                this.message("电脑快捷键已保存。", false);
            } catch (error) {
                this.status.textContent = error.message;
                this.message(error.message, true);
            } finally {
                this.busy = false;
                this.section
                    .querySelectorAll("button")
                    .forEach((button) => (button.disabled = false));
            }
        }
        loadBrowser() {
            try {
                const text = localStorage.getItem(STORAGE);
                if (!text) return;
                const doc = JSON.parse(text);
                if (doc.version !== 1) throw Error("配置版本无效");
                this.model.apply(doc.codes);
                this.draft = this.model.snapshot();
                this.onChange();
            } catch (_) {
                this.status.textContent = "浏览器缓存不可用，先使用默认布局。";
            }
        }
        async loadNative() {
            if (this.loadedNative || !this.getAPI()?.load_key_bindings) return;
            this.loadedNative = true;
            const revision = this.revision;
            try {
                const result = await this.getAPI().load_key_bindings();
                if (!result?.ok) throw Error(result?.error || "读取快捷键失败");
                // 迟到的启动读取不能覆盖用户已经编辑或保存的本次设置。
                if (revision !== this.revision || revision !== 0 || this.busy)
                    return;
                const codes = B.validate(result.codes || B.defaults);
                await this.beforeChange();
                if (revision !== this.revision || this.busy) return;
                this.model.apply(codes);
                this.draft = this.model.snapshot();
                this.render();
                this.onChange();
                this.status.textContent =
                    result.warning || "已读取本机保存的快捷键布局。";
            } catch (error) {
                this.status.textContent = error.message;
            }
        }
    }
    root.KeyboardShortcutPanel = KeyboardShortcutPanel;
})(window);
