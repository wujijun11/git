"use strict";
// 独立无头浏览器验证手机版界面，不读取用户窗口，也不连接蓝牙。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(
    process.env.TANG_PLAYWRIGHT ||
        path.join(
            process.env.USERPROFILE,
            ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright",
        ),
);
const root = path.resolve(__dirname, "../web");
const output = path.resolve(__dirname, "../../verification/mobile");
const fixtures = JSON.parse(
    fs.readFileSync(path.join(output, "midi-fixtures.json"), "utf8"),
);
const fixture = fixtures[0];
const server = http.createServer((request, response) => {
    const target = path.resolve(
        root,
        "." + decodeURIComponent(request.url.split("?")[0]),
    );
    if (!(target === root || target.startsWith(root + path.sep))) {
        response.writeHead(403).end();
        return;
    }
    const file = target === root ? path.join(root, "index.html") : target;
    const type =
        { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" }[
            path.extname(file)
        ] || "application/octet-stream";
    fs.readFile(file, (error, body) => {
        response.writeHead(error ? 404 : 200, {
            "Content-Type": type + "; charset=utf-8",
        });
        response.end(error ? "" : body);
    });
});
(async () => {
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const browser = await chromium.launch({
        headless: true,
        executablePath:
            process.env.TANG_CHROME ||
            "C:/Program Files/Google/Chrome/Application/chrome.exe",
    });
    const page = await browser.newPage({
        viewport: { width: 390, height: 844 },
    });
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    try {
        await page.addInitScript(
            ({ midi }) => {
                window.AndroidBle = {
                    disconnect() {},
                    cancelScoreLoad() {},
                    musicRequest(json, id) {
                        const request = JSON.parse(json);
                        const item = {
                            title: "<img src=x onerror=alert(1)> Bach",
                            composer: "J.S. Bach",
                            instruments: "Piano",
                            license: "Public Domain",
                            detailUrl: "https://www.mutopiaproject.org/",
                            midiUrl:
                                "https://www.mutopiaproject.org/fixture.mid",
                        };
                        const result =
                            request.action === "search"
                                ? { ok: true, items: [item], hasNext: false }
                                : {
                                      ok: true,
                                      files: [
                                          {
                                              name: "tempo.mid",
                                              base64: btoa(
                                                  String.fromCharCode(...midi),
                                              ),
                                              attribution: item,
                                          },
                                      ],
                                  };
                        setTimeout(
                            () => window.nativeMusicResult(id, result),
                            2,
                        );
                    },
                };
            },
            { midi: fixture.bytes },
        );
        await page.goto("http://127.0.0.1:" + server.address().port + "/");
        await page.locator("#musicQuery").fill("Bach");
        await page.locator("#musicSearch button").click();
        await page.locator("#musicResults article button").click();
        await page.locator("#musicAnalyze").click();
        await page.waitForFunction(() =>
            document
                .getElementById("musicAnalysis")
                .textContent.includes("4/1024"),
        );
        assert.equal(
            await page.locator("#musicResults img").count(),
            0,
            "downloaded labels must remain text",
        );
        assert.equal(await page.locator("#musicAccept").isDisabled(), true);
        await page.locator("#musicAgree").check();
        await page.locator("#musicAccept").click();
        await page.waitForFunction(() => score && score.rows.length === 4);
        assert.equal(
            await page.evaluate(() => score.attribution.license),
            "Public Domain",
        );
        // 使用真实File对象导入，不通过JSON绕过MIDI解析。
        await page
            .locator("#midiFile")
            .setInputFiles({
                name: "local.mid",
                mimeType: "audio/midi",
                buffer: Buffer.from(fixture.bytes),
            });
        await page.waitForFunction(() =>
            document
                .getElementById("musicFile")
                .textContent.includes("local.mid"),
        );
        await page.locator("#musicStart").fill("0.1");
        await page.locator("#musicEnd").fill("0.6");
        await page.locator("#musicAnalyze").click();
        await page.waitForFunction(() =>
            document
                .getElementById("musicAnalysis")
                .textContent.includes("4/1024"),
        );
        await page.locator("#musicAgree").check();
        await page.locator("#musicAccept").click();
        assert.equal(await page.evaluate(() => score.segment.startMs), 100);
        await page.locator("#simulate").click();
        await page.waitForFunction(() => controlReady);
        await page.evaluate(() => {
            window.sent = [];
            const original = Simulator.prototype.write;
            Simulator.prototype.write = function (bytes) {
                sent.push(P.decode(bytes));
                return original.call(this, bytes);
            };
        });
        await page.locator("#upload").click();
        await page.waitForFunction(() =>
            document
                .getElementById("scoreInfo")
                .textContent.includes("已提交 4"),
        );
        assert.equal(
            await page.evaluate(() => sent.filter((p) => p.op === 5).length),
            25,
        );
        // 检查跨256边界和1024条完整提交，仍使用原16字节协议。
        await page.evaluate(() => {
            sent.length = 0;
            setScore({
                version: 1,
                title: "capacity1024",
                rows: Array.from({ length: 1024 }, (_, i) => ({
                    deltaMs: i ? 1 : 0,
                    key: 0,
                    velocity: i % 2 ? 0 : 100,
                    on: i % 2 ? 0 : 1,
                })),
            });
        });
        await page.locator("#upload").click();
        await page.waitForFunction(
            () =>
                document
                    .getElementById("scoreInfo")
                    .textContent.includes("已提交 1024"),
            { timeout: 30000 },
        );
        assert.equal(
            await page.evaluate(() => sent.filter((p) => p.op === 6).length),
            1024,
        );
        assert.deepEqual(
            await page.evaluate(() =>
                sent
                    .filter((p) => p.op === 6)
                    .at(-1)
                    .payload.slice(0, 2),
            ),
            [255, 3],
        );
        assert.deepEqual(
            await page.evaluate(() =>
                sent.find((p) => p.op === 7 && p.payload[2] !== 1).payload.slice(0, 3),
            ),
            [0, 4, 0],
        );
        await page.locator("#scoreCapacity").selectOption("256");
        const before = await page.evaluate(
            () => sent.filter((p) => [4, 5, 6, 7].includes(p.op)).length,
        );
        await page.locator("#upload").click();
        await page.waitForFunction(() =>
            document.getElementById("status").textContent.includes("1..256"),
        );
        assert.equal(
            await page.evaluate(
                () => sent.filter((p) => [4, 5, 6, 7].includes(p.op)).length,
            ),
            before,
        );
        await page.locator("#musicLibrary").scrollIntoViewIfNeeded();
        await page.screenshot({
            path: path.join(output, "mobile-music-390.png"),
            fullPage: true,
        });
        assert.equal(
            await page.evaluate(
                () => document.documentElement.scrollWidth <= innerWidth,
            ),
            true,
            "390px layout must not overflow",
        );
        assert.deepEqual(errors, []);
        const result = {
            searchBridgeFixture: true,
            localMidiFile: true,
            segmentAndConsent: true,
            uploadMapping25: true,
            uploadEvents1024: true,
            legacyCapacityRejectBeforeWrite: true,
            viewport: 390,
            pageErrors: errors,
            realAndroidGatt: false,
            hardwareAccessed: false,
        };
        fs.writeFileSync(
            path.join(output, "music-ui-result.json"),
            JSON.stringify(result, null, 2),
        );
        console.log(JSON.stringify(result, null, 2));
    } finally {
        await browser.close();
        server.close();
    }
})().catch((error) => {
    console.error(error);
    server.close();
    process.exitCode = 1;
});
