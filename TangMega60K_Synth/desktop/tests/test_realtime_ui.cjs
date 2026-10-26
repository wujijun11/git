"use strict";
// 独立无头浏览器验证两端真实界面与既有协议模拟器，不连接用户蓝牙/串口。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");
const { chromium } = require(process.env.TANG_PLAYWRIGHT ||
    path.join(process.env.USERPROFILE, ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"));
const root = path.resolve(__dirname, "../..");
const output = path.join(root, "verification/realtime-score");
const note = (midi, on, deltaMs = 0) => ({ midi, on, deltaMs, velocity: on ? 90 : 0 });
const score = rows => ({ version: 2, playback: "direct", transport: "realtime", title: "实时播放测试", rows });
const short = score([note(60, 1), note(64, 1), note(60, 0, 100), note(64, 0), note(67, 1, 100), note(67, 0, 100)]);
const long = score(Array.from({ length: 1200 }, (_, i) => note(36 + Math.floor(i / 2) % 60, i % 2 === 0 ? 1 : 0, 50)));
const server = http.createServer((request, response) => {
    const target = path.resolve(root, "." + decodeURIComponent(request.url.split("?")[0]));
    if (!target.startsWith(root + path.sep)) { response.writeHead(403).end(); return; }
    fs.readFile(target, (error, data) => {
        response.writeHead(error ? 404 : 200, { "Content-Type": { ".js": "application/javascript", ".html": "text/html", ".css": "text/css" }[path.extname(target)] || "application/octet-stream" });
        response.end(error ? "missing" : data);
    });
});
async function main() {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const base = "http://127.0.0.1:" + server.address().port;
    const browser = await chromium.launch({ headless: true,
        executablePath: process.env.TANG_CHROME || "C:/Program Files/Google/Chrome/Application/chrome.exe" });
    const results = [], errors = [];
    try {
        for (const client of ["desktop", "mobile"]) {
            const page = await browser.newPage({ viewport: { width: client === "desktop" ? 1440 : 440, height: 980 } });
            page.on("pageerror", error => errors.push(client + ": " + error.message));
            await page.goto(base + "/" + client + "/web/index.html");
            if (client === "desktop") {
                await page.evaluate(() => neonApp.startDemo());
                await page.click("[data-page=scores]");
                await page.evaluate(() => {
                    window.noteCalls = [];
                    const c = neonApp.controller, execute = c._executeRequest.bind(c);
                    c._executeRequest = (...args) => { noteCalls.push({ op: args[1], p: args[2] }); return execute(...args); };
                });
            } else {
                await page.click("#simulate");
                await page.waitForFunction(() => controlReady);
                await page.evaluate(() => {
                    window.noteCalls = [];
                    const send = session.send.bind(session);
                    session.send = (op, p) => { noteCalls.push({ op, p }); return send(op, p); };
                });
            }
            const load = async doc => {
                if (client === "desktop") {
                    await page.setInputFiles("#fileInput", { name: "stream.json", mimeType: "application/json", buffer: Buffer.from(JSON.stringify(doc)) });
                    await page.waitForFunction(() => neonApp.selectedScore === "imported" && document.getElementById("scoreMeta").textContent.includes("实时曲谱"));
                } else await page.evaluate(doc => setScore(doc), doc);
            };
            await load(short);
            await page.click("#realtimePlay");
            try {
                await page.waitForFunction(() => document.getElementById("realtimeStatus").textContent.includes("播放完成"), null, { timeout: 8000 });
            } catch (error) {
                console.error(client, await page.evaluate(() => ({ status: document.getElementById("realtimeStatus").textContent,
                    footer: document.getElementById("footerMessage")?.textContent,
                    log: document.getElementById("log")?.textContent, calls: noteCalls })), errors);
                await page.screenshot({ path: path.join(output, client + "-failure.png"), fullPage: true });
                throw error;
            }
            let notes = await page.evaluate(() => noteCalls.filter(x => x.op === 1).map(x => x.p.slice(1, 5)));
            assert.deepEqual(notes, short.rows.map(x => [x.midi, x.velocity, 2, x.on]));
            assert.equal(await page.evaluate(() => noteCalls.some(x => x.op === 6 || x.op === 7)), false, "不得写入板上曲谱RAM");

            await load(long); // 超过1024仍能导入，停止后没有旧曲谱继续补弹。
            await page.evaluate(() => { noteCalls.length = 0; });
            await page.click("#realtimePlay");
            await page.waitForFunction(() => noteCalls.some(x => x.op === 1 && x.p[4]));
            await page.click("#realtimeStop");
            await page.waitForFunction(() => document.getElementById("realtimeStatus").textContent.includes("已停止"));
            const count = await page.evaluate(() => noteCalls.filter(x => x.op === 1).length);
            await page.waitForTimeout(180);
            assert.equal(await page.evaluate(() => noteCalls.filter(x => x.op === 1).length), count);
            const held = new Set();
            notes = await page.evaluate(() => noteCalls.filter(x => x.op === 1).map(x => x.p));
            for (const p of notes) p[4] ? held.add(p[1]) : held.delete(p[1]);
            assert.equal(held.size, 0, "停止必须释放已发送的音符");

            // 从停止状态重启，然后模拟进入后台。Windows窗口切换后台不应停止实时任务。
            await page.evaluate(() => { noteCalls.length = 0; });
            await page.click("#realtimePlay");
            await page.waitForFunction(() => noteCalls.some(x => x.op === 1 && x.p[4]));
            await page.evaluate(() => {
                Object.defineProperty(document, "hidden", { configurable: true, value: true });
                document.dispatchEvent(new Event("visibilitychange"));
            });
            if (client === "desktop") {
                await page.waitForFunction(() => noteCalls.filter(x => x.op === 1).length > 1);
                assert.equal(await page.evaluate(() => document.getElementById("realtimeStatus").textContent.includes("实时播放已停止")), false);
                await page.click("#realtimeStop");
                await page.waitForFunction(() => document.getElementById("realtimeStatus").textContent.includes("已停止"));
            } else {
                // 本轮只改变Windows；手机仍保留原来的进入后台保护。
                await page.waitForFunction(() => document.getElementById("realtimeStatus").textContent.includes("已停止"));
            }
            await page.evaluate(() => Object.defineProperty(document, "hidden", { configurable: true, value: false }));
            await page.screenshot({ path: path.join(output, client + "-realtime.png"), fullPage: true });
            await page.evaluate(() => { noteCalls.length = 0; });
            await page.click("#realtimePlay");
            await page.waitForFunction(() => noteCalls.some(x => x.op === 1 && x.p[4]));
            if (client === "desktop") await page.evaluate(() => neonApp.controller.disconnect());
            else await page.evaluate(() => disconnect());
            const disconnectedCount = await page.evaluate(() => noteCalls.filter(x => x.op === 1).length);
            await page.waitForTimeout(180);
            assert.equal(await page.evaluate(() => noteCalls.filter(x => x.op === 1).length), disconnectedCount);
            results.push({ client, shortEvents: 6, longEventsImported: 1200, stopReleased: true,
                backgroundStopped: client === "mobile", backgroundContinued: client === "desktop",
                disconnectStopped: true, scoreRamWrites: 0 });
            await page.close();
        }
        assert.deepEqual(errors, []);
        fs.writeFileSync(path.join(output, "ui-result.json"), JSON.stringify({ results, errors, actualBluetoothTested: false }, null, 2));
        console.log("REALTIME UI PASS: NOTE stream, no RAM upload, >1024 events; Windows continues in background, mobile stops; stop/restart/disconnect");
    } finally { await browser.close(); await new Promise(resolve => server.close(resolve)); }
}
main().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
