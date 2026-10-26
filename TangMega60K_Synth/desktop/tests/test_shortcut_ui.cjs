"use strict";
// 独立无头浏览器与模拟协议设备，验证真实按键事件及重启存储，不操作用户桌面。
const assert = require("node:assert/strict"), fs = require("node:fs"), http = require("node:http"), path = require("node:path");
const {chromium} = require(path.join(process.env.USERPROFILE, ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"));
const root = path.resolve(__dirname, "../web"), output = path.resolve(__dirname, "../../verification/keyboard-shortcuts");
fs.mkdirSync(output, {recursive: true});
const server = http.createServer((request, response) => {
    const name = decodeURIComponent(request.url.split("?")[0]);
    const file = path.resolve(root, "." + (name === "/" ? "/index.html" : name));
    if (!file.startsWith(root + path.sep)) { response.writeHead(403).end(); return; }
    const type = {".html": "text/html", ".js": "text/javascript", ".css": "text/css"}[path.extname(file)] || "application/octet-stream";
    fs.readFile(file, (error, bytes) => { response.writeHead(error ? 404 : 200, {"Content-Type": type + "; charset=utf-8"}); response.end(error ? "" : bytes); });
});
(async () => {
    await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
    const url = "http://127.0.0.1:" + server.address().port + "/";
    const browser = await chromium.launch({headless: true, executablePath: "C:/Program Files/Google/Chrome/Application/chrome.exe"});
    const context = await browser.newContext({viewport: {width: 1440, height: 1040}});
    const errors = []; let nativeCodes = null, writes = 0, deferLoad = false, finishLoad;
    await context.exposeFunction("testLoadKeys", async () => deferLoad ? new Promise(resolve => finishLoad = () => resolve({ok:true,codes:nativeCodes})) : ({ok: true, codes: nativeCodes}));
    await context.exposeFunction("testSaveKeys", async codes => { nativeCodes = codes; writes++; return {ok: true, codes}; });
    await context.addInitScript(() => {
        window.pywebview = {api: {load_key_bindings: () => window.testLoadKeys(), save_key_bindings: codes => window.preferenceWriteFailure ? Promise.resolve({ok:false,error:'测试：磁盘拒绝写入'}) : window.testSaveKeys(codes)}};
    });
    const page = await context.newPage(); page.on("pageerror", error => errors.push(error.message));
    try {
        await page.goto(url); await page.waitForFunction(() => document.getElementById("shortcutStatus").textContent.includes("已读取"));
        await page.click("#connectButton"); await page.click("[data-transport=demo]"); await page.click("#startDemo");
        await page.waitForFunction(() => neonApp.controller.ready);
        await page.evaluate(() => { window.frames = []; const transport = neonApp.controller._ctx.transport, original = transport.write;
            transport.write = async bytes => { frames.push(RemoteProtocol.decode(bytes)); return original(bytes); }; });
        await page.click("[data-page=settings]");
        await page.click('.shortcut-edit[data-index="0"]'); await page.keyboard.press("a");
        assert.equal(await page.locator("#shortcut-value-0").textContent(), "A");
        assert.equal(await page.evaluate(() => frames.some(p => p.op === 1)), false, "capture must not play notes");
        await page.click('.shortcut-edit[data-index="1"]'); await page.keyboard.press("a");
        assert.match(await page.locator("#shortcutStatus").textContent(), /已分配/);
        assert.equal(await page.locator("#shortcut-value-1").textContent(), "S");
        await page.click("#cancelShortcuts");
        await page.click('.shortcut-edit[data-index="0"]'); await page.keyboard.press("a");
        await page.click("#saveShortcuts"); await page.waitForFunction(() => document.getElementById("shortcutStatus").textContent.includes("已保存并应用"));
        assert.equal(writes, 1); assert.equal(nativeCodes[0], "KeyA");
        assert.equal(await page.evaluate(() => frames.some(p => [3, 5].includes(p.op))), false, "shortcut changes must not write timbre or MIDI mapping");
        await page.click("[data-page=studio]");
        assert.equal(await page.locator('.piano-key[data-index="0"] .key-binding').textContent(), "A");
        await page.evaluate(() => frames.length = 0);
        await page.keyboard.down("a"); await page.waitForFunction(() => frames.some(p => p.op === 1 && p.payload[4] === 1));
        await page.keyboard.up("a"); await page.waitForFunction(() => frames.some(p => p.op === 1 && p.payload[4] === 0));
        assert.equal(await page.evaluate(() => frames.find(p => p.op === 1).payload[1]), 60);
        await page.evaluate(() => frames.length = 0); await page.keyboard.press("z"); await page.waitForTimeout(50);
        assert.equal(await page.evaluate(() => frames.some(p => p.op === 1)), false, "previous shortcut must stop triggering");
        // 输入框、组合键、IME不触发音符；Esc仍全停。
        await page.click("[data-page=settings]"); await page.evaluate(() => frames.length = 0);
        await page.locator("#map-0").focus(); await page.keyboard.press("a"); await page.keyboard.press("Control+a");
        await page.evaluate(() => document.body.dispatchEvent(new KeyboardEvent("keydown", {code: "KeyA", bubbles: true, isComposing: true})));
        assert.equal(await page.evaluate(() => frames.some(p => p.op === 1)), false);
        await page.click('.shortcut-edit[data-index="2"]'); await page.keyboard.press("Escape");
        await page.waitForFunction(() => frames.some(p => p.op === 4 && p.payload[0] === 5));
        assert.match(await page.locator("#shortcutStatus").textContent(), /取消/);
        // 同一音反复按、松开仍完整保留，不以自定义键位为由取消短音。
        await page.click("[data-page=studio]"); await page.evaluate(() => frames.length = 0);
        for (let i = 0; i < 20; i++) await page.keyboard.press("a");
        await page.waitForFunction(() => frames.filter(p => p.op === 1).length === 40);
        assert.equal(await page.evaluate(() => frames.filter(p => p.op === 1 && p.payload[4]).length), 20);
        // 保存时释放已按住的旧键；新布局要到下次按下才触发。
        await page.keyboard.down("a"); await page.waitForFunction(() => neonApp.activeKeys.size === 1);
        await page.evaluate(() => document.querySelector('[data-page=settings]').click());
        await page.click('.shortcut-edit[data-index="0"]'); await page.keyboard.press("b"); // B原有绑定，必须拒绝。
        assert.match(await page.locator("#shortcutStatus").textContent(), /已分配/);
        await page.keyboard.press("t"); assert.match(await page.locator("#shortcutStatus").textContent(), /已分配/);
        await page.keyboard.press("l"); await page.click("#saveShortcuts");
        await page.waitForFunction(() => document.getElementById("shortcutStatus").textContent.includes("已保存并应用"));
        await page.keyboard.up("a"); await page.waitForFunction(() => neonApp.activeKeys.size === 0);
        assert.equal(nativeCodes[0], "KeyL");
        // 在设置页持有音符时直接保存，必须先释放，再保留新的映射。
        await page.keyboard.down('l');await page.waitForFunction(()=>neonApp.activeKeys.size===1);
        await page.evaluate(()=>document.getElementById('saveShortcuts').click());
        await page.waitForFunction(()=>neonApp.activeKeys.size===0);await page.keyboard.up('l');
        await page.waitForFunction(()=>!document.getElementById('saveShortcuts').disabled);
        // 存储失败不能把未保存草稿变为正在使用的快捷键。
        await page.click('.shortcut-edit[data-index="0"]');await page.keyboard.press('p');
        await page.evaluate(()=>window.preferenceWriteFailure=true);await page.click('#saveShortcuts');
        await page.waitForFunction(()=>document.getElementById('shortcutStatus').textContent.includes('拒绝写入'));
        assert.equal(await page.locator('.piano-key[data-index="0"] .key-binding').textContent(),'L');
        assert.equal(nativeCodes[0],'KeyL');await page.click('#cancelShortcuts');
        // 更换网页来源模拟打包程序重启，不依赖同一来源的localStorage。
        const reopened = await context.newPage(); reopened.on("pageerror", error => errors.push(error.message));
        await reopened.goto(url.replace("127.0.0.1", "localhost")); await reopened.waitForFunction(() => document.getElementById("shortcut-value-0").textContent === "L");
        await reopened.click("[data-page=settings]");
        await reopened.waitForTimeout(450);
        await reopened.screenshot({path: path.join(output, "shortcut-settings.png"), fullPage: true});
        await reopened.locator('#keyboardShortcuts').screenshot({path:path.join(output,'shortcut-panel.png')});
        assert.equal(await reopened.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
        await reopened.click("#resetShortcuts"); await reopened.click("#saveShortcuts");
        await reopened.waitForFunction(() => document.getElementById("shortcutStatus").textContent.includes("已保存并应用"));
        assert.equal(nativeCodes[0], "KeyZ");
        await reopened.close();
        deferLoad=true;
        const racing=await context.newPage();await racing.goto(url,{waitUntil:'domcontentloaded'});
        await racing.click('[data-page=settings]');await racing.click('.shortcut-edit[data-index="0"]');await racing.keyboard.press('a');
        assert.ok(finishLoad);finishLoad();await racing.waitForTimeout(80);
        assert.equal(await racing.locator('#shortcut-value-0').textContent(),'A','late startup read must preserve the user draft');
        await racing.close();deferLoad=false;
        assert.deepEqual(errors, []);
        fs.writeFileSync(path.join(output, "ui-result.json"), JSON.stringify({customKey: true, conflictRejection: true,
            reservedEscape: true, typingAndImeGuard: true, fullFastNotes: 40, persistedNativeReload: true,
            activeNoteRelease: true, saveFailurePreservesLive: true, lateLoadPreservesDraft:true, reset: true, noHardwareConfigWrites: true, pageErrors: errors, hardwareAccessed: false}, null, 2));
        console.log("SHORTCUT UI PASS custom key, conflict, capture, typing/IME, Esc, 40 rapid note events, release, persistence and reset");
    } finally { await browser.close(); server.close(); }
})().catch(error => { console.error(error); server.close(); process.exitCode = 1; });
