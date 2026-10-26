/* 学习会话业务。只通过控制器请求协议；不在电脑上决定实体键是否过关。 */
(function (root) {
    "use strict";
    class LearningControl {
        constructor({ controller, getScore, getGeneration, prepareScore, runExclusive,
            onStatus = () => {}, onError = () => {} }) {
            Object.assign(this, { controller, getScore, getGeneration, prepareScore, runExclusive, onStatus, onError });
            this.generation = 0;
            this.timer = null;
        }
        cancel() {
            this.generation++;
            clearTimeout(this.timer);
            this.timer = null;
        }
        async toggle() {
            const controller = this.controller;
            if (!controller.ready) throw Error("请先连接设备，或进入离线演示。");
            this.cancel();
            const token = this.generation;
            const connection = this.getGeneration();
            const check = () => {
                if (!controller.ready || token !== this.generation || connection !== this.getGeneration())
                    throw Object.assign(Error("学习操作已取消"), { cancelled: true });
            };
            return this.runExclusive(async () => {
                // 在上传之前探测扩展，旧板上程序明确拒绝，不能偷偷启动自动指引。
                let status;
                try { status = await controller.readLearningStatus(); }
                catch (error) {
                    if (/NACK/.test(error.message)) throw Error("当前板上程序不支持学习模式，请先下载配套的 LearningMode 位流。");
                    throw error;
                }
                check();
                if (status.active) {
                    await controller.transportAction(7);
                    check();
                    this.onStatus(await controller.readLearningStatus());
                    check();
                    return false;
                }
                const score = this.getScore();
                if (!score || score.playback === "direct" || score.transport === "realtime")
                    throw Error("学习需要内置曲谱或25键映射曲谱；超出键盘的直接音高曲谱不能用实体键学习。");
                await controller.readStatus();
                check();
                if (controller.telemetry.playing || controller.telemetry.recording || controller.telemetry.guide)
                    throw Error("请先停止播放、录制或节奏指引，再开始学习。");
                await this.prepareScore(score);
                check();
                await controller.transportAction(9);
                check();
                status = await controller.readLearningStatus();
                check();
                this.onStatus(status, score.title);
                this.poll(token, connection);
                return true;
            });
        }
        poll(token, connection) {
            // 上一次返回后才排下一次。通道忙时跳过，避免查询挤占演奏队列。
            this.timer = setTimeout(async () => {
                if (token !== this.generation || connection !== this.getGeneration() || !this.controller.ready) return;
                try {
                    const status = await this.controller.readLearningStatusIfIdle();
                    if (token !== this.generation || connection !== this.getGeneration()) return;
                    if (status) {
                        this.onStatus(status);
                        if (!status.active) return;
                    }
                    this.poll(token, connection);
                } catch (error) {
                    if (token === this.generation) this.onError(error);
                }
            }, 150);
            this.timer.unref?.();
        }
    }
    if (typeof module !== "undefined") module.exports = { LearningControl };
    root.LearningControl = LearningControl;
})(typeof globalThis !== "undefined" ? globalThis : this);
