/* 逐键指引业务：选择当前曲谱、启动/停止板上指引；不直接操作 BLE 或灯珠。 */
(function (root) {
    "use strict";

    /**
     * controller 使用既有 V1 远程协议；动作 6 开始、7 停止指引。
     * getGeneration 返回当前连接和播放操作的标识，防止上传结束后误启动旧操作。
     * prepareScore 必须先完整选择/上传曲谱；runExclusive 复用界面的数据操作锁。
     * 返回 Promise<boolean>：true 已启动、false 已停止；失败抛错供界面显示。
     */
    async function toggle({ controller, getScore, getGeneration, prepareScore, runExclusive,
        onStartPending = () => {} }) {
        if (!controller.ready) {
            throw new Error("请先连接设备，或进入离线演示。");
        }
        const generation = getGeneration();
        const score = getScore();
        function checkCurrent() {
            if (!controller.ready || getGeneration() !== generation) {
                throw new Error("灯光指引操作已取消");
            }
        }

        return runExclusive(async () => {
            // 读取板上实际状态，避免上次指引已结束但按钮状态尚未刷新。
            await controller.readStatus();
            checkCurrent();
            if (controller.telemetry?.guide) {
                await controller.transportAction(7);
                checkCurrent();
                await controller.readStatus();
                checkCurrent();
                return false;
            }
            if (!score || score.playback === "direct" || score.transport === "realtime") {
                throw new Error("灯光指引需要板上内置曲谱或可上传的25键映射曲谱；当前直接音高/实时曲谱不支持。");
            }
            if (controller.telemetry?.playing || controller.telemetry?.recording) {
                throw new Error("请先停止播放或录制，再开始灯光指引。");
            }
            // 不能只发启动命令，否则 FPGA 可能继续使用上一首曲谱。
            await prepareScore(score);
            checkCurrent();
            // 曲谱已准备好，此刻才让屏幕跟谱器建立本次会话；无需新增协议查询。
            onStartPending(score);
            await controller.transportAction(6);
            checkCurrent();
            await controller.readStatus();
            checkCurrent();
            return true;
        });
    }

    const api = { toggle };
    if (typeof module !== "undefined") module.exports = api;
    root.DesktopGuideControl = api;
})(typeof window !== "undefined" ? window : globalThis);
