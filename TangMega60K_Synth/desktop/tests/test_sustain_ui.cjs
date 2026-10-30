"use strict";
// 无设备的真实页面检查：桌面、手机及旧固件降级；没有扫描或连接蓝牙。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");
const { chromium } = require(path.join(process.env.USERPROFILE,
    ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"));
const project = path.resolve(__dirname, "../..");
const output = path.join(project, "verification/sustain/browser");
fs.mkdirSync(output, { recursive: true });
const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    const phone = url.pathname.startsWith("/phone/");
    const root = path.join(project, phone ? "mobile/web" : "desktop/web");
    const relative = decodeURIComponent(url.pathname.replace(/^\/(phone|desktop)\//, ""));
    const file = path.resolve(root, relative || "index.html");
    if (!file.startsWith(root + path.sep) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
        response.writeHead(404); response.end(); return;
    }
    const mime = { ".html": "text/html; charset=utf-8", ".js": "application/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" };
    response.setHeader("Content-Type", mime[path.extname(file)] || "application/octet-stream");
    response.end(fs.readFileSync(file));
});

async function main() {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const base = "http://127.0.0.1:" + server.address().port;
    const browser = await chromium.launch({ executablePath: "C:/Program Files/Google/Chrome/Application/chrome.exe",
        headless: true, args: ["--no-sandbox"] });
    const errors = [];
    try {
        const desktop = await browser.newPage({ viewport: { width: 1440, height: 1040 } });
        desktop.on("pageerror", error => errors.push(error.message));
        await desktop.goto(base + "/desktop/");
        assert.equal(await desktop.locator("#sustainEnabled").isDisabled(), true);
        await desktop.click("#connectButton");
        await desktop.click('[data-transport="demo"]');
        await desktop.click("#startDemo");
        await desktop.waitForFunction(() => neonApp.controller.ready && !document.getElementById("sustainEnabled").disabled);
        await desktop.click("#sustainEnabled");
        await desktop.waitForFunction(() => document.getElementById("sustainStatus").textContent.includes("已开启"));
        await desktop.screenshot({ path: path.join(output, "Windows延音开关_协议模拟.png"), fullPage: true });
        await desktop.evaluate(async () => { await neonApp.controller.panic(); await neonApp.controller.readSustainState(); });
        await desktop.waitForFunction(() => !document.getElementById("sustainEnabled").checked);
        const phone = await browser.newPage({ viewport: { width: 430, height: 1000 } });
        phone.on("pageerror", error => errors.push(error.message));
        await phone.goto(base + "/phone/");
        await phone.click("#simulate");
        await phone.waitForFunction(() => controlReady && !document.getElementById("sustainEnabled").disabled);
        await phone.click("#sustainEnabled");
        await phone.waitForFunction(() => document.getElementById("sustainStatus").textContent.includes("已开启"));
        await phone.screenshot({ path: path.join(output, "Android延音开关_协议模拟.png"), fullPage: true });
        await phone.reload();
        await phone.evaluate(() => {
            const previous = Simulator.prototype.write;
            Simulator.prototype.write = async function (bytes) {
                const packet = P.decode(bytes);
                if (packet.op === 8 && packet.payload[0] === 5) {
                    this.deliver(P.encode(packet.seq, 128, [8, 1])); return;
                }
                return previous.call(this, bytes);
            };
        });
        await phone.click("#simulate");
        await phone.waitForFunction(() => controlReady);
        assert.equal(await phone.locator("#sustainEnabled").isDisabled(), true);
        assert.match(await phone.locator("#sustainStatus").textContent(), /尚不支持/);
        assert.equal(await phone.locator("#timbre").isDisabled(), false);
        assert.deepEqual(errors, []);
        const result = { passed: true, desktopSwitch: true, desktopPanic: true, phoneSwitch: true,
            oldFirmwareFallback: true, pageErrors: errors, hardwareTested: false };
        fs.writeFileSync(path.join(output, "summary.json"), JSON.stringify(result, null, 2));
        console.log("SUSTAIN UI PASS desktop, phone, panic, legacy fallback; no real BLE");
    } finally { await browser.close(); server.close(); }
}
main().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
