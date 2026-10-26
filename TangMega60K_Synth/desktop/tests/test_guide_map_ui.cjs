"use strict";
// 真实浏览器界面与内存协议设备；测试不连接蓝牙或串口。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require(process.env.TANG_PLAYWRIGHT || path.join(process.env.USERPROFILE,
    ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"));
const root = path.resolve(__dirname, "../..");
const base = path.join(root, "desktop/web");
const output = path.join(root, "verification/guide-map-ui");
fs.mkdirSync(output, { recursive: true });
const server = http.createServer((request, response) => {
    const target = path.resolve(base, "." + decodeURIComponent(request.url.split("?")[0]));
    const file = target === base ? path.join(base, "index.html") : target;
    if (!file.startsWith(base + path.sep)) { response.writeHead(403).end(); return; }
    fs.readFile(file, (error, bytes) => {
        const type = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" }[path.extname(file)];
        response.writeHead(error ? 404 : 200, { "Content-Type": (type || "application/octet-stream") + "; charset=utf-8" });
        response.end(error ? "" : bytes);
    });
});

async function main() {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const browser = await chromium.launch({ headless: true,
        executablePath: process.env.TANG_CHROME || "C:/Program Files/Google/Chrome/Application/chrome.exe" });
    const errors = [];
    try {
        const page = await browser.newPage({ viewport: { width: 1440, height: 1300 } });
        page.on("pageerror", error => errors.push(error.message));
        await page.goto("http://127.0.0.1:" + server.address().port + "/");
        assert.equal(await page.locator(".guide-cell").count(), 25);
        assert.deepEqual(await page.locator(".guide-key-number").allTextContents(),
            Array.from({ length: 25 }, (_, i) => String(i + 1).padStart(2, "0")));
        await page.click('.guide-cell[data-key="7"]');
        assert.equal(await page.locator('.piano-key[data-index="7"].guide-locate').count(), 1);
        await page.screenshot({ path: path.join(output, "number-lookup.png"), fullPage: true });
        await page.evaluate(() => neonApp.startDemo());
        await page.waitForFunction(() => neonApp.controller.ready);
        await page.evaluate(() => { neonApp.controller._ctx.transport.requests.length = 0; });
        await page.click('.guide-cell[data-key="24"]');
        assert.equal(await page.evaluate(() => neonApp.controller._ctx.transport.requests.some(q => q.op === 1)), false);
        await page.click("#guideLocateClear");
        assert.equal(await page.locator(".guide-locate").count(), 0);

        const row = (key, on, deltaMs) => ({ key, on, deltaMs, velocity: on ? 100 : 0 });
        async function load(rows) {
            await page.setInputFiles("#fileInput", { name: "guide.json", mimeType: "application/json",
                buffer: Buffer.from(JSON.stringify({ version: 1, title: "灯位对照练习", rows })) });
            await page.waitForFunction(() => neonApp.selectedScore === "imported");
        }
        await load([row(7, 1, 0), row(11, 1, 0), row(7, 0, 1500), row(11, 0, 0),
            row(24, 1, 300), row(24, 0, 1800)]);
        await page.click("#guideButton");
        await page.waitForFunction(() => document.querySelectorAll(".guide-cell.is-target").length === 2);
        assert.deepEqual(await page.locator(".piano-key.guide-target").evaluateAll(nodes => nodes.map(n => Number(n.dataset.index))), [7, 11]);
        assert.match(await page.locator("#guideTargets").textContent(), /08 \+ 12/);
        await page.locator(".keyboard-panel").screenshot({ path: path.join(output, "guide-chord.png") });
        await page.waitForFunction(() => document.querySelector("#guideTargets").textContent.includes("松开"));
        await page.waitForFunction(() => document.querySelector('.guide-cell[data-key="24"]').classList.contains("is-target"));
        await page.click("#guideButton");
        await page.waitForFunction(() => document.querySelectorAll(".guide-target,.guide-cell.is-target").length === 0);

        // 仅测试中停止心跳，模拟没有状态回传；界面不能把长音永久亮着。
        await load([row(0, 1, 0), row(0, 0, 10000)]);
        await page.click("#guideButton");
        await page.waitForFunction(() => document.querySelectorAll(".guide-cell.is-target").length === 1);
        await page.evaluate(() => clearInterval(neonApp.controller._ctx.heartbeat));
        await page.waitForFunction(() => document.querySelector("#guideMapState").textContent === "等待状态回传");
        assert.equal(await page.locator(".piano-key.guide-target").count(), 0);
        await page.evaluate(() => neonApp.controller.readStatus());
        await page.waitForFunction(() => document.querySelectorAll(".guide-cell.is-target").length === 1);
        await page.evaluate(() => neonApp.controller.disconnect());
        await page.waitForFunction(() => document.querySelector("#guideMapState").textContent === "设备未连接");
        assert.equal(await page.locator(".guide-cell.is-target").count(), 0);

        // 编号不随MIDI映射变化，音名会更新；不伪装已弹对或实体触摸。
        await page.evaluate(() => { neonApp.controller.mapping[7] = 72; });
        await page.click('.guide-cell[data-key="7"]');
        assert.match(await page.locator("#guideLocateText").textContent(), /08.*C5/);
        assert.equal(await page.locator('.piano-key[data-index="7"] .guide-key-number').textContent(), "08");
        await page.setViewportSize({ width: 900, height: 1000 });
        await page.locator(".keyboard-panel").screenshot({ path: path.join(output, "guide-narrow.png") });
        assert.equal(await page.locator(".guide-panel").evaluate(el => el.scrollWidth <= el.clientWidth), true);
        assert.equal(await page.locator("#guideButton span").isVisible(), true);
        // 打印页独立于演奏窗口，确认两套贴纸与对照卡各含25个编号。
        const labels = await browser.newPage({ viewport: { width: 800, height: 1123 } });
        await labels.goto("http://127.0.0.1:" + server.address().port + "/guide-labels.html");
        assert.equal(await labels.locator(".labels span").count(), 50);
        assert.equal(await labels.locator(".matrix span").count(), 25);
        await labels.emulateMedia({ media: "print" });
        const lampBox = await labels.locator("#lamp").boundingBox();
        const keyBox = await labels.locator("#key").boundingBox();
        assert.equal(lampBox.y, keyBox.y, "打印时两套标签应并排，避免折到两页");
        await labels.screenshot({ path: path.join(output, "print-labels.png"), fullPage: true });
        await labels.close();
        assert.deepEqual(errors, []);
        fs.writeFileSync(path.join(output, "ui-result.json"), JSON.stringify({
            passed: true, cells: 25, fixedKeyNumbers: 25, locateDoesNotPlay: true,
            chordAndRest: true, staleAndDisconnectClear: true, mappingKeepsNumbers: true,
            width900NoPanelOverflow: true, buttonLabelVisible: true, printableLabels: 50,
            pageErrors: errors, actualHardware: false,
        }, null, 2));
        console.log("GUIDE MAP UI PASS: 25 labels, silent lookup, chord/rest targets, stale/disconnect clear, remap and 900px layout");
    } finally {
        await browser.close();
        await new Promise(resolve => server.close(resolve));
    }
}
main().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
