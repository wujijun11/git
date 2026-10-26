"use strict";
const assert = require("node:assert/strict");
const { uploadMappedScore } = require("../web/score-upload");

function fixture(fail = () => false) {
    const log = [];
    const controller = {
        ready: true,
        scoreCapacity: 1024,
        mapping: Array.from({ length: 25 }, (_, index) => 60 + index),
        telemetry: { recording: false },
        readStatus: async () => {},
        releaseAll: async () => log.push("release"),
        transportAction: async (action) => log.push(["action", action]),
        setMapping: async (key, note) => {
            if (fail(key, note)) throw Error("MAP failure");
            controller.mapping[key] = note;
            log.push(["map", key, note]);
        },
        uploadScore: async () => log.push("score"),
    };
    const options = {
        controller,
        score: {
            mapping: Array.from({ length: 25 }, (_, index) => 40 + index),
            rows: [],
        },
        isCancelled: () => false,
        sameConnection: () => true,
        onProgress: () => {},
        onRestoreError: (error) => {
            throw error;
        },
    };
    return { controller, log, options };
}

(async () => {
    const normal = fixture();
    await uploadMappedScore(normal.options);
    assert.equal(normal.log.filter((entry) => entry[0] === "map").length, 25);
    assert.equal(normal.controller.mapping[0], 40);
    assert.equal(normal.log.at(-1), "score");

    const recording = fixture();
    recording.controller.telemetry.recording = true;
    await assert.rejects(uploadMappedScore(recording.options), /结束录制/);
    assert.deepEqual(recording.log, []);

    let failed = false;
    const rollback = fixture((key, note) => {
        if (key === 5 && note === 45 && !failed) {
            failed = true;
            return true;
        }
        return false;
    });
    await assert.rejects(uploadMappedScore(rollback.options), /MAP failure/);
    assert.equal(rollback.controller.mapping[0], 60);
    assert.equal(rollback.controller.mapping[24], 84);
    assert(!rollback.log.includes("score"));

    const cancelled = fixture();
    cancelled.options.isCancelled = () =>
        cancelled.log.some((entry) => entry[0] === "map");
    await assert.rejects(
        uploadMappedScore(cancelled.options),
        (error) => error.cancelled === true,
    );
    assert.equal(cancelled.controller.mapping[0], 60);
    assert(!cancelled.log.includes("score"));

    const reconnect = fixture();
    reconnect.options.isCancelled = () =>
        reconnect.log.some((entry) => entry[0] === "map");
    reconnect.options.sameConnection = () => false;
    await assert.rejects(
        uploadMappedScore(reconnect.options),
        (error) => error.cancelled === true,
    );
    assert.equal(reconnect.log.filter((entry) => entry[0] === "map").length, 1);
    console.log(
        "MAPPED SCORE UPLOAD PASS mapping, recording guard, rollback, cancel and reconnect isolation",
    );
})().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
