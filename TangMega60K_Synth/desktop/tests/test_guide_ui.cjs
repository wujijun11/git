"use strict";
// 无头浏览器使用真实界面和协议模拟器；不扫描蓝牙、不访问板卡。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(process.env.TANG_PLAYWRIGHT || path.join(process.env.USERPROFILE,
    ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"));
const { toggle } = require("../web/guide-control.js");
const root = path.resolve(__dirname, "../..");
const webRoot = path.join(root, "desktop/web");
const output = path.join(root, "verification/guide-ui");
fs.mkdirSync(output, { recursive: true });

// 上传过程中停止或更换会话，不能在旧上传完成后再启动指引。
async function checkCancellation() {
    let generation = 0;
    const actions = [];
    await assert.rejects(toggle({
        controller: { ready: true, telemetry: {}, readStatus: async () => {},
            transportAction: async action => actions.push(action) },
        getScore: () => ({ builtin: true }),
        getGeneration: () => generation,
        prepareScore: async () => { generation++; },
        runExclusive: operation => operation(),
    }), /已取消/);
    assert.deepEqual(actions, []);
}

const server = http.createServer((request, response) => {
    const target = path.resolve(webRoot, "." + decodeURIComponent(request.url.split("?")[0]));
    const file = target === webRoot ? path.join(webRoot, "index.html") : target;
    if (!file.startsWith(webRoot + path.sep)) {
        response.writeHead(403).end();
        return;
    }
    fs.readFile(file, (error, bytes) => {
        const type = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" }[path.extname(file)];
        response.writeHead(error ? 404 : 200, { "Content-Type": (type || "application/octet-stream") + "; charset=utf-8" });
        response.end(error ? "" : bytes);
    });
});

async function main() {
    await checkCancellation();
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const browser = await chromium.launch({ headless: true,
        executablePath: process.env.TANG_CHROME || "C:/Program Files/Google/Chrome/Application/chrome.exe" });
    const errors = [];
    try {
        const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
        page.on("pageerror", error => errors.push(error.message));
        await page.goto("http://127.0.0.1:" + server.address().port + "/");
        await page.evaluate(() => neonApp.startDemo());
        await page.waitForFunction(() => neonApp.controller.ready);
        assert.equal(await page.locator("#guideButton").isDisabled(), false);
        const resetRequests = () => page.evaluate(() => { neonApp.controller._ctx.transport.requests.length = 0; });
        const requests = () => page.evaluate(() => neonApp.controller._ctx.transport.requests);
        async function stopGuide() {
            await page.click("#guideButton");
            await page.waitForFunction(() => document.querySelector("#guideButton").getAttribute("aria-pressed") === "false");
        }
        await resetRequests();
        await page.click("#guideButton");
        await page.waitForFunction(() => document.querySelector("#guideButton").getAttribute("aria-pressed") === "true");
        let sent = await requests();
        const selectIndex = sent.findIndex(q => q.op === 7 && q.payload[2] === 1);
        const startIndex = sent.findIndex(q => q.op === 4 && q.payload[0] === 6);
        assert(selectIndex >= 0 && startIndex > selectIndex, "必须先选择内置曲谱再指引");
        assert.equal(await page.evaluate(() => neonApp.controller.telemetry.playing), false);
        await stopGuide();
        assert((await requests()).some(q => q.op === 4 && q.payload[0] === 7));

        // 验证校准文件经真实导入、上传、提交后才启动，不依赖上一首曲谱。
        await page.setInputFiles("#fileInput", path.join(root, "hardware/led25/calibration-25.json"));
        await page.waitForFunction(() => neonApp.selectedScore === "imported");
        await resetRequests();
        await page.click("#guideButton");
        await page.waitForFunction(() => document.querySelector("#guideButton").getAttribute("aria-pressed") === "true");
        sent = await requests();
        assert.equal(sent.filter(q => q.op === 6).length, 50);
        const commitIndex = sent.findIndex(q => q.op === 7 && q.payload[2] === 0);
        assert(commitIndex >= 0 && sent.findIndex(q => q.op === 4 && q.payload[0] === 6) > commitIndex);
        assert.equal(sent.filter(q => q.op === 1).length, 0, "静音指引不得发送演奏音符");
        await page.screenshot({ path: path.join(output, "desktop-guide.png"), fullPage: true });
        await stopGuide();

        // 没有25键映射的曲谱必须给出解释，不能误启动板上上一次的曲谱。
        const direct = { version: 2, playback: "direct", title: "无键位测试",
            rows: [{ deltaMs: 0, midi: 36, velocity: 80, on: 1 },
                { deltaMs: 5000, midi: 36, velocity: 0, on: 0 }] };
        await page.setInputFiles("#fileInput", { name: "direct.json", mimeType: "application/json",
            buffer: Buffer.from(JSON.stringify(direct)) });
        await page.waitForFunction(() => document.querySelector("#currentTrack").textContent === "无键位测试");
        await resetRequests();
        await page.click("#guideButton");
        await page.waitForFunction(() => document.querySelector("#toast").textContent.includes("25键映射曲谱"));
        assert.equal((await requests()).some(q => q.op === 4 && q.payload[0] === 6), false);
        assert.deepEqual(errors, []);
        fs.writeFileSync(path.join(output, "ui-result.json"), JSON.stringify({
            passed: true, builtInSelectedBeforeStart: true, mappedRowsUploaded: 50,
            stopCommand: 7, directScoreRejected: true, cancellationChecked: true,
            guideIsSilent: true, pageErrors: errors, actualHardwareTested: false,
        }, null, 2));
        console.log("GUIDE UI PASS: builtin, 50 calibration events, start/stop, silent guide, direct-score guard and cancellation");
    } finally {
        await browser.close();
        await new Promise(resolve => server.close(resolve));
    }
}
main().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
