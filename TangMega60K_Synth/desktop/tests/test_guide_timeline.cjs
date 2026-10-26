"use strict";
// 和弦、休止、重触发、回传校正、失联及未知曲谱；不连接硬件。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { GuideTimeline, compile } = require("../web/guide-timeline.js");
const row = (key, on, deltaMs, velocity = on ? 100 : 0) => ({ key, on, deltaMs, velocity });
const score = { title: "和弦与休止", rows: [row(7, 1, 0), row(11, 1, 0),
    row(7, 0, 500), row(11, 0, 0), row(24, 1, 200), row(24, 0, 300)] };
const model = new GuideTimeline();
model.arm(score, 100);
assert.equal(model.snapshot(100).mask, 0, "未收到启动状态前不高亮");
model.accept({ guide: true, scorePosition: 2 }, 110);
assert.equal(model.snapshot(200).mask, (1 << 7) | (1 << 11));
assert.equal(model.snapshot(600).mask, 0, "休止清灯");
assert.equal(model.snapshot(850).mask, 1 << 24);
model.accept({ guide: true, scorePosition: 5 }, 850);
assert.equal(model.snapshot(1100).mask, 0, "结束等待确认时清灯");
model.accept({ guide: false, scorePosition: 6 }, 1110);
assert.equal(model.snapshot(1110).phase, "finished");

const sustained = { title: "长音", rows: [row(0, 1, 0), row(0, 0, 10000)] };
model.arm(sustained, 0);
model.accept({ guide: true, scorePosition: 1 }, 20);
assert.equal(model.snapshot(1800).mask, 1);
assert.equal(model.snapshot(1821).phase, "stale");
assert.equal(model.snapshot(1821).mask, 0);
model.accept({ guide: true, scorePosition: 1 }, 1900);
assert.equal(model.snapshot(1900).mask, 1, "恢复回传后恢复提示");
model.clear("disconnected");
assert.equal(model.snapshot(2000).mask, 0);
model.accept({ guide: true, scorePosition: 1 }, 2100);
assert.equal(model.snapshot(2100).phase, "unknown");
assert.equal(model.snapshot(2100).mask, 0, "未知板上曲谱不能套用本机选择");

model.arm(score, 0);
model.accept({ guide: true, scorePosition: 4 }, 500);
model.accept({ guide: true, scorePosition: 1 }, 501);
assert.equal(model.snapshot(501).phase, "mismatch");
model.arm(score, 0);
model.accept({ guide: true, scorePosition: 99 }, 1);
assert.equal(model.snapshot(1).phase, "mismatch");
model.arm(score, 0);
model.accept({ guide: true, scorePosition: 2 }, 550);
assert.equal(model.snapshot(550).mask, (1 << 7) | (1 << 11), "回传校正超前估计");

const repeated = compile({ rows: [row(0, 1, 0), row(0, 1, 20), row(0, 1, 20, 0)] });
assert.deepEqual(repeated.masks, [0, 1, 1, 0]);
assert.equal(compile({ builtin: true }).times.at(-1), 8300);
assert.equal(compile({ builtin: true }, true).times.at(-1), 5080);
assert.throws(() => compile({ playback: "direct", rows: [row(0, 1, 0)] }), /25键/);
assert.throws(() => compile({ rows: [row(25, 1, 0)] }), /无效/);
const output = path.resolve(__dirname, "../../verification/guide-map-ui");
fs.mkdirSync(output, { recursive: true });
fs.writeFileSync(path.join(output, "timeline-result.json"), JSON.stringify({
    passed: true, chordAndRest: true, telemetryCorrection: true, staleClears: true,
    unknownScoreClears: true, retriggerAndZeroVelocity: true, builtinProfilesSeparate: true,
    actualHardware: false,
}, null, 2));
console.log("GUIDE TIMELINE PASS: chords/rest/retrigger, telemetry correction, stale/disconnect/unknown guards, builtin profiles");
