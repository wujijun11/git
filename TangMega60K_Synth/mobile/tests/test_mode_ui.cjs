"use strict";
// 独立浏览器模拟板端模式帧；不连接真实蓝牙或读取用户桌面。
const assert = require("node:assert/strict"),
    fs = require("node:fs"),
    http = require("node:http"),
    path = require("node:path");
const { chromium } = require(
    path.join(
        process.env.USERPROFILE,
        ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright",
    ),
);
const root = path.resolve(__dirname, "../web"),
    out = path.resolve(__dirname, "../../verification/mobile");
const server = http.createServer((request, response) => {
    const name = decodeURIComponent(request.url.split("?")[0]),
        file = path.resolve(root, "." + (name === "/" ? "/index.html" : name));
    if (!file.startsWith(root + path.sep)) {
        response.writeHead(403).end();
        return;
    }
    fs.readFile(file, (error, bytes) => {
        response.writeHead(error ? 404 : 200, {
            "Content-Type": file.endsWith(".js")
                ? "text/javascript"
                : file.endsWith(".css")
                  ? "text/css"
                  : "text/html; charset=utf-8",
        });
        response.end(error ? "" : bytes);
    });
});
(async () => {
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    const browser = await chromium.launch({
        headless: true,
        executablePath: "C:/Program Files/Google/Chrome/Application/chrome.exe",
    });
    try {
        const page = await browser.newPage({
                viewport: { width: 390, height: 844 },
            }),
            errors = [];
        page.on("pageerror", (error) => errors.push(error.message));
        await page.goto("http://127.0.0.1:" + server.address().port + "/");
        await page.evaluate(async () => {
            window.writes = [];
            window.boardSnapshot = [1, 32, 1, 3, 3, 244, 2, 0, 0, 0];
            const mock = new Simulator();
            const owner = createSession((bytes) => {
                const q = P.decode(bytes);
                writes.push(q);
                if (q.op === 8 && q.payload[0] === 2) {
                    decoder.push(P.encode(q.seq, 131, boardSnapshot));
                    decoder.push(P.encode(q.seq, 128, [8, 0]));
                    return Promise.resolve();
                }
                return mock.write(bytes);
            }, true);
            mock.deliver = (bytes) => decoder.push(bytes);
            await handshake(owner);
        });
        assert.equal(await page.locator("#timbre").inputValue(), "3");
        assert.equal(await page.locator("#effect").inputValue(), "2");
        assert.match(
            await page.locator("#boardMode").textContent(),
            /-12 半音/,
        );
        assert.equal(
            await page.evaluate(() => writes.some((p) => p.op === 3)),
            false,
        );
        await page.evaluate(() => {
            boardSnapshot = [1, 41, 2, 0, 1, 12, 1, 0, 0, 0];
        });
        await page.waitForFunction(() =>
            document.getElementById("boardMode").textContent.includes("录制中"),
        );
        assert.match(await page.locator("#boardMode").textContent(), /总菜单/);
        assert.equal(await page.locator("#timbre").inputValue(), "1");
        assert.equal(
            await page.evaluate(() => writes.some((p) => p.op === 3)),
            false,
        );
        await page
            .locator("#boardMode")
            .screenshot({ path: path.join(out, "mode-sync-view.png") });
        assert.deepEqual(errors, []);
        fs.writeFileSync(
            path.join(out, "mode-sync-ui.json"),
            JSON.stringify(
                {
                    connectedModeAdoption: true,
                    idleRefresh: true,
                    noWriteback: true,
                    hardwareAccessed: false,
                },
                null,
                2,
            ),
        );
        console.log(
            "MOBILE MODE UI PASS actual mode adopted, idle refresh, no implicit CONFIG writes",
        );
    } finally {
        await browser.close();
        server.close();
    }
})().catch((error) => {
    console.error(error);
    server.close();
    process.exitCode = 1;
});
