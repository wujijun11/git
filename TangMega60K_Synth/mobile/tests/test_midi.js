"use strict";
// 与Python/mido独立参考逐事件比较；包含变速、片段边界及严格容量处理。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const M = require("../web/music/smf.js");
const cases = JSON.parse(
    fs.readFileSync(
        path.resolve(__dirname, "../../verification/mobile/midi-fixtures.json"),
        "utf8",
    ),
);
const results = [];
for (const test of cases) {
    const info = M.parse(Uint8Array.from(test.bytes));
    const got = M.convert(info, test.name, test.options);
    assert.equal(info.durationMs, test.info.durationMs, test.name);
    for (const key of [
        "score",
        "canUpload",
        "maxEvents",
        "eventCount",
        "pitchCount",
        "durationMs",
        "pianoRoll",
    ])
        assert.deepEqual(got[key], test.expected[key], `${test.name}: ${key}`);
    assert.equal(got.errors.length, test.expected.errors.length);
    assert.equal(got.warnings.length, test.expected.warnings.length);
    results.push({
        name: test.name,
        pass: true,
        events: got.eventCount,
        canUpload: got.canUpload,
    });
}
const valid = Uint8Array.from(cases[0].bytes);
for (let cut = 0; cut < valid.length; cut++)
    assert.throws(
        () => M.parse(valid.slice(0, cut)),
        "truncated file must fail",
    );
const type2 = valid.slice();
type2[9] = 2;
assert.throws(() => M.parse(type2), /Type/);
const smpte = valid.slice();
smpte[12] = 128;
assert.throws(() => M.parse(smpte), /SMPTE/);
const zeroDivision = valid.slice();
zeroDivision[12] = zeroDivision[13] = 0;
assert.throws(() => M.parse(zeroDivision));
assert.throws(() => M.parse(new Uint8Array(4 * 1024 * 1024 + 1)), /4MiB/);
assert.throws(
    () =>
        M.convert(M.parse(valid), "bad", {
            ...cases[0].options,
            maxEvents: 2048,
        }),
    /容量/,
);
const result = {
    reference: "Python mido + desktop converter",
    cases: results,
    malformedFilesRejected: true,
    hardwareAccessed: false,
};
fs.writeFileSync(
    path.resolve(__dirname, "../../verification/mobile/midi-test-result.json"),
    JSON.stringify(result, null, 2),
);
console.log(JSON.stringify(result, null, 2));
