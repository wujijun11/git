"use strict";
// 独立无头浏览器+本地HTTP测试服务器，不读取/操作用户的浏览器或桌面。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");
const { spawn, spawnSync } = require("node:child_process");
const { chromium } = require(
    process.env.TANG_PLAYWRIGHT ||
        path.join(
            process.env.USERPROFILE,
            ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright",
        ),
);
const root = path.resolve(__dirname, "..");
const out = path.resolve(
    process.env.TANG_UI_OUTPUT ||
        path.join(root, "../verification/music-library-ui"),
);
fs.mkdirSync(out, { recursive: true });
const python =
    process.env.TANG_PYTHON ||
    path.join(root, "../tmp/desktop-python/Scripts/python.exe");
const generation = spawnSync(
    python,
    [
        path.join(__dirname, "make_music_fixture.py"),
        path.join(out, "midi-fixture.json"),
    ],
    { windowsHide: true, encoding: "utf8" },
);
if (generation.status !== 0)
    throw Error("MIDI fixture generation failed: " + generation.stderr);
const fixture = JSON.parse(
    fs.readFileSync(path.join(out, "midi-fixture.json"), "utf8"),
);
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

(async () => {
    const server = spawn(
        process.env.TANG_PYTHON ||
            path.join(root, "../tmp/desktop-python/Scripts/python.exe"),
        [
            "-m",
            "http.server",
            "8772",
            "--bind",
            "127.0.0.1",
            "--directory",
            path.join(root, "web"),
        ],
        { windowsHide: true, stdio: "ignore" },
    );
    let browser;
    try {
        let ready = false;
        for (let i = 0; i < 50; i++) {
            try {
                // 读完响应再重试，避开部分Node24中fetch连接关闭的undici断言。
                ready = await new Promise(resolve => {
                    const request = http.get("http://127.0.0.1:8772", response => {
                        response.resume();
                        response.on("end", () => resolve(response.statusCode === 200));
                    });
                    request.on("error", () => resolve(false));
                    request.setTimeout(1000, () => { request.destroy(); resolve(false); });
                });
            } catch (_) {}
            if (ready) break;
            await delay(100);
        }
        assert(ready, "test server started");
        browser = await chromium.launch({
            executablePath:
                "C:/Program Files/Google/Chrome/Application/chrome.exe",
            headless: true,
            args: [
                "--no-sandbox",
                "--autoplay-policy=no-user-gesture-required",
            ],
        });
        const page = await browser.newPage({
                viewport: { width: 1440, height: 1040 },
            }),
            errors = [];
        page.on("pageerror", (error) => errors.push(error.message));
        await page.addInitScript((data) => {
            window.fixture = data;
            window.invalidFixture = false;
            window.pywebview = {
                api: {
                    search_music: async () => ({
                        ok: true,
                        items: [
                            {
                                title: "Test public score",
                                composer: "Fixture",
                                instruments: "Piano",
                                license: "Public Domain",
                                token: "item",
                                midiUrl:
                                    "https://www.mutopiaproject.org/ftp/test.mid",
                            },
                        ],
                        hasNext: false,
                    }),
                    fetch_music: async () => ({
                        ok: true,
                        files: [
                            {
                                name: "test.mid",
                                token: "file",
                                durationMs: 1000,
                                tracks: [{ index: 0, name: "Piano", notes: 2 }],
                            },
                        ],
                    }),
                    prepare_music: async () =>
                        window.invalidFixture
                            ? {
                                  ...data,
                                  ok: true,
                                  canUpload: false,
                                  eventCount: 1026,
                                  errors: ["需要1026条事件，超过1024"],
                              }
                            : { ...data, ok: true },
                },
            };
        }, fixture);
        await page.goto("http://127.0.0.1:8772", { waitUntil: "networkidle" });
        await page.click("#connectButton");
        await page.click("[data-transport=demo]");
        await page.click("#startDemo");
        await page.waitForFunction(() => neonApp.controller.ready);
        await page.click("[data-page=scores]");
        await page.fill("#musicQuery", "Bach");
        await page.locator(".music-search button[type=submit]").click();
        await page.locator("[data-action=fetch]").click();
        await page.locator("[data-action=prepare]").click();
        await page.waitForFunction(() =>
            document
                .querySelector(".music-analysis")
                .textContent.includes("符合"),
        );
        assert(
            await page.locator("[data-action=accept]").isDisabled(),
            "explicit conversion agreement required",
        );
        await page.check(".music-agree");
        await page.locator("[data-action=accept]").click();
        assert.equal(
            await page.evaluate(() => neonApp.selectedScore),
            "imported",
        );
        await page.evaluate(() => {
            window.musicOps = [];
            const t = neonApp.controller._ctx.transport,
                w = t.write;
            t.write = async (bytes) => {
                musicOps.push(RemoteProtocol.decode(bytes));
                return w(bytes);
            };
        });
        await page.click("#uploadScore");
        await page.waitForFunction(
            () =>
                document.getElementById("scoreState").textContent === "已上传",
        );
        assert.equal(
            await page.evaluate(
                () => musicOps.filter((item) => item.op === 5).length,
            ),
            25,
        );
        assert.equal(
            await page.evaluate(
                () => musicOps.filter((item) => item.op === 6).length,
            ),
            fixture.eventCount,
        );
        assert.equal(
            await page.evaluate(() => neonApp.controller.mapping[0]),
            40,
        );
        // 真实控制器/原帧格式上传1024条：检查最高地址及提交长度的两个字节。
        const fullUpload = await page.evaluate(async () => {
            musicOps.length = 0;
            const rows = Array.from({ length: 1024 }, (_, index) => ({
                deltaMs: 1,
                key: 0,
                velocity: 100,
                on: index % 2 ? 0 : 1,
            }));
            await neonApp.controller.uploadScore({
                version: 1,
                title: "1024 boundary",
                rows,
            });
            const writes = musicOps.filter((item) => item.op === 6);
            const commit = musicOps.find((item) => item.op === 7 && item.payload[2] !== 1);
            return {
                writes: writes.length,
                lastIndex: writes.at(-1).payload.slice(0, 2),
                count: commit.payload.slice(0, 2),
            };
        });
        assert.equal(fullUpload.writes, 1024);
        assert.deepEqual(fullUpload.lastIndex, [255, 3]);
        assert.deepEqual(fullUpload.count, [0, 4]);
        await page.selectOption(".music-capacity-select", "256");
        assert.equal(
            await page.evaluate(() => neonApp.controller.scoreCapacity),
            256,
        );
        const legacyGuard = await page.evaluate(async () => {
            musicOps.length = 0;
            try {
                await neonApp.controller.uploadScore({
                    version: 1,
                    rows: Array.from({ length: 257 }, () => ({
                        deltaMs: 1,
                        key: 0,
                        velocity: 0,
                        on: 0,
                    })),
                });
                return false;
            } catch (_) {
                return musicOps.length === 0;
            }
        });
        assert(
            legacyGuard,
            "old firmware profile rejects before any hardware write",
        );
        await page.selectOption(".music-capacity-select", "1024");
        await page.evaluate(() => (window.invalidFixture = true));
        await page.locator("[data-action=prepare]").click();
        await page.waitForFunction(() =>
            document
                .querySelector(".music-analysis")
                .textContent.includes("1026"),
        );
        await page.check(".music-agree");
        assert(await page.locator("[data-action=accept]").isDisabled());
        await page.screenshot({
            path: path.join(out, "music-search-capacity.png"),
            fullPage: true,
        });
        for (const width of [1100, 768, 390]) {
            await page.setViewportSize({ width, height: 900 });
            assert(
                await page
                    .locator(".music-library")
                    .evaluate((el) => el.scrollWidth <= el.clientWidth + 2),
                "music panel fits " + width,
            );
        }
        assert.deepEqual(errors, []);
        fs.writeFileSync(
            path.join(out, "music-ui-result.json"),
            JSON.stringify(
                {
                    pass: true,
                    backend: "native API fixtures",
                    upload: "existing protocol demo only",
                    hardwareTested: false,
                    checks: [
                        "search results",
                        "MIDI tracks and segment",
                        "explicit conversion agreement",
                        "25 MAP commands",
                        "full score write count",
                        "over-capacity rejected",
                        "390/768/1100 panel layout",
                    ],
                    pageErrors: errors,
                },
                null,
                2,
            ),
        );
        // 再运行原有完整界面回归，保持已验证的蓝牙控制界面行为。
        const child = spawn(
            process.execPath,
            [path.join(__dirname, "ui_smoke.cjs")],
            {
                windowsHide: true,
                stdio: "inherit",
                env: { ...process.env, TANG_UI_URL: "http://127.0.0.1:8772" },
            },
        );
        await new Promise((resolve, reject) => {
            child.once("exit", (code) =>
                code === 0
                    ? resolve()
                    : reject(Error("original UI regression failed: " + code)),
            );
            child.once("error", reject);
        });
        console.log("MUSIC LIBRARY UI PASS");
    } finally {
        if (browser) await browser.close();
        server.kill();
    }
})().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
