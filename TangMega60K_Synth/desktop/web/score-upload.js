/* 上传业务：键位切换、取消检查与失败恢复；不包含界面或BLE底层实现。 */
(function (root) {
    "use strict";

    async function uploadMappedScore({
        controller,
        score,
        isCancelled,
        sameConnection,
        onProgress,
        onRestoreError,
    }) {
        const oldMapping = controller.mapping.slice();
        let remapped = false;

        if (score.rows.length > controller.scoreCapacity) {
            throw new Error(
                `曲谱有${score.rows.length}条事件，所选板上程序容量为${controller.scoreCapacity}条`,
            );
        }

        function checkCurrentOperation() {
            if (isCancelled()) {
                const error = new Error("曲谱上传已取消");
                error.cancelled = true;
                throw error;
            }
        }

        try {
            checkCurrentOperation();
            const needsMapping =
                score.playback !== "direct" && score.mapping &&
                score.mapping.some((note, index) => note !== oldMapping[index]);
            if (needsMapping) {
                await controller.readStatus();
                checkCurrentOperation();
                if (controller.telemetry?.recording) {
                    throw new Error("请先结束录制，再上传需要更改键位的曲谱");
                }
                await controller.releaseAll();
                checkCurrentOperation();
                await controller.transportAction(5);
                checkCurrentOperation();
                // 部分MAP成功后也需要恢复，因此在第一个MAP之前标记。
                remapped = true;
                for (let index = 0; index < 25; index++) {
                    checkCurrentOperation();
                    await controller.setMapping(index, score.mapping[index]);
                    checkCurrentOperation();
                }
            }
            await controller.uploadScore(score, onProgress);
            checkCurrentOperation();
            return score;
        } catch (error) {
            // 不能把旧连接的恢复命令发送到重新连接后的另一个会话。
            if (remapped && controller.ready && sameConnection()) {
                try {
                    for (let index = 0; index < 25; index++) {
                        if (!controller.ready || !sameConnection()) break;
                        await controller.setMapping(index, oldMapping[index]);
                    }
                } catch (restoreError) {
                    onRestoreError(restoreError);
                }
            }
            throw error;
        }
    }

    const api = { uploadMappedScore };
    if (typeof module !== "undefined") module.exports = api;
    root.MappedScoreUpload = api;
})(typeof window !== "undefined" ? window : globalThis);
