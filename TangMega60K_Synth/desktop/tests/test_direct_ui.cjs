"use strict";
// 独立浏览器验证真实曲谱界面；后端转换结果取Python参考，协议设备为模拟器。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(path.join(process.env.USERPROFILE,
    ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"));
const root = path.resolve(__dirname, "../..");
const output = path.join(root, "verification/direct-score/ui");
fs.mkdirSync(output, { recursive: true });
const fixture = JSON.parse(fs.readFileSync(path.join(root,
    "verification/mobile/midi-fixtures.json"), "utf8")).find(item => item.name === "direct-128-pitches");
assert(fixture, "generate MIDI fixtures first");
const server = http.createServer((request, response) => {
    const pathname = decodeURIComponent(request.url.split("?")[0]);
    const phone = pathname.startsWith("/phone/");
    const base = path.join(root, phone ? "mobile/web" : "desktop/web");
    const file = path.resolve(base, pathname.replace(/^\/(phone|desktop)\//, "") || "index.html");
    if (!file.startsWith(base + path.sep)) { response.writeHead(403).end(); return; }
    const type = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" }[path.extname(file)];
    fs.readFile(file, (error, bytes) => {
        response.writeHead(error ? 404 : 200, { "Content-Type": (type || "application/octet-stream") + "; charset=utf-8" });
        response.end(error ? "" : bytes);
    });
});
(async () => {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const browser = await chromium.launch({ headless: true,
        executablePath: "C:/Program Files/Google/Chrome/Application/chrome.exe" });
    const errors = [];
    try {
        const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
        page.on("pageerror", error => errors.push(error.message));
        await page.addInitScript(data => {
            window.prepareCalls = [];
            window.pywebview = { api: {
                search_music: async () => ({ ok: true, items: [], hasNext: false }),
                load_midi: async () => ({ ok: true, files: [{ token: "fixture", name: data.name,
                    durationMs: data.info.durationMs, tracks: data.info.tracks }] }),
                prepare_music: async (_token, options) => {
                    prepareCalls.push(options);
                    return options.direct ? { ok: true, ...data.expected } : {
                        ok: true, ...data.expected, canUpload: false, errors: ["超过25键映射"], warnings: [],
                    };
                },
            } };
        }, fixture);
        const base = "http://127.0.0.1:" + server.address().port;
        await page.goto(base + "/desktop/");
        await page.evaluate(() => neonApp.startDemo());
        await page.waitForFunction(() => neonApp.controller.ready);
        // 原连接握手会同步25键；专项只统计后续曲谱上传，不能混入握手命令。
        await page.evaluate(() => { neonApp.controller._ctx.transport.requests.length = 0; });
        await page.click("[data-page=scores]");
        await page.click("[data-action=local]");
        await page.locator(".music-editor").waitFor({ state: "visible" });
        await page.click("[data-action=prepare]");
        await page.waitForFunction(() => document.querySelector(".music-analysis").textContent.includes("超过25"));
        assert(await page.locator("[data-action=accept]").isDisabled());
        await page.check(".music-direct");
        assert(await page.locator(".music-compact").isDisabled());
        await page.click("[data-action=prepare]");
        await page.waitForFunction(() => prepareCalls.at(-1)?.direct);
        await page.check(".music-agree");
        await page.click("[data-action=accept]");
        await page.waitForFunction(() => document.querySelector("#scoreMeta").textContent.includes("直接音高"));
        assert.doesNotMatch(await page.locator("#scorePreview").textContent(), /undefined|NaN/);
        await page.click("#uploadScore");
        await page.waitForFunction(() => document.querySelector("#scoreState").textContent === "已上传");
        const commands = await page.evaluate(() => neonApp.controller._ctx.transport.requests);
        assert.equal(commands.filter(q => q.op === 6).length, 256);
        assert.equal(commands.filter(q => q.op === 5).length, 0);
        await page.click("#scorePlay");
        await page.waitForTimeout(400);
        await page.click("[data-page=studio]");
        await page.waitForTimeout(100);
        await page.click("#playButton");
        await page.screenshot({ path: path.join(output, "desktop-direct.png") });
        await page.close();

        const phone = await browser.newPage({ viewport: { width: 390, height: 844 } });
        phone.on("pageerror", error => errors.push(error.message));
        await phone.goto(base + "/phone/");
        await phone.setInputFiles("#midiFile", { name: "all-pitches.mid", mimeType: "audio/midi",
            buffer: Buffer.from(fixture.bytes) });
        await phone.locator("#musicEditor").waitFor({ state: "visible" });
        await phone.check("#musicDirect");
        assert(await phone.locator("#musicCompact").isDisabled());
        await phone.click("#musicAnalyze");
        await phone.waitForFunction(() => musicPanel.result?.canUpload);
        assert.equal(await phone.evaluate(() => musicPanel.result.pitchCount), 128);
        await phone.check("#musicAgree");
        await phone.click("#musicAccept");
        assert.equal(await phone.evaluate(() => score.playback), "direct");
        assert.equal(await phone.evaluate(() => score.rows[254].midi), 127);
        assert.equal(await phone.evaluate(() => score.mapping), undefined);
        await phone.locator("#musicDirect").scrollIntoViewIfNeeded();
        await phone.screenshot({ path: path.join(output, "phone-direct.png") });
        assert.deepEqual(errors, []);
        fs.writeFileSync(path.join(output, "result.json"), JSON.stringify({
            passed: true, desktopAndPhone: true, pitches: 128, explicitOption: true,
            noRemapping: true, legacyGuard: true, uploadRows: 256, demoPlayback: true,
            pageErrors: errors, actualHardware: false,
        }, null, 2));
        console.log("DIRECT UI PASS desktop/phone 128 pitches, optional mode, no remapping, explicit import/upload, demo playback and no errors");
    } finally { await browser.close(); server.close(); }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
