/* 仅供Windows离线演示的学习模型；实物判定在FPGA learning_stepper中完成。 */
(function (root) {
    "use strict";
    class LearningDemo {
        constructor() { this.stop(); }
        stop() {
            this.active = false;
            this.finished = false;
            this.targetMask = 0;
            this.completedSteps = 0;
            this.position = 0;
            this.waitingRelease = false;
            this.waitingPress = false;
        }
        start(rows, touchMask) {
            this.stop();
            this.rows = rows;
            this.active = true;
            this.next();
            this.touch(touchMask);
        }
        next() {
            let mask = 0;
            while (this.position < this.rows.length) {
                const row = this.rows[this.position];
                if (mask && row.deltaMs) break;
                if (row.on && row.velocity) mask |= 1 << row.key;
                this.position++;
            }
            this.targetMask = mask;
            this.waitingRelease = !!mask;
            this.waitingPress = false;
            if (!mask) { this.active = false; this.finished = true; }
        }
        touch(mask) {
            if (!this.active) return;
            if (this.waitingRelease) {
                if (!mask) { this.waitingRelease = false; this.waitingPress = true; }
            } else if (this.waitingPress && mask === this.targetMask) {
                this.completedSteps++;
                this.next();
            }
        }
        payload(P) {
            return [1, 1 | (this.active ? 2 : 0) | (this.waitingRelease ? 4 : 0) |
                (this.waitingPress ? 8 : 0) | (this.finished ? 16 : 0) | 32,
                ...P.le16(this.completedSteps), ...P.le32(this.targetMask), ...P.le16(this.position)];
        }
    }
    if (typeof module !== "undefined") module.exports = { LearningDemo };
    root.LearningDemo = LearningDemo;
})(typeof globalThis !== "undefined" ? globalThis : this);
