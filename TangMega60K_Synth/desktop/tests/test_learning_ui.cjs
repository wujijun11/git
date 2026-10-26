"use strict";
// 浏览器+二进制协议模拟器联测，不连接硬件。截图可用于核对按钮和同号灯位。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const http = require("node:http");
const { chromium } = require(process.env.TANG_PLAYWRIGHT || path.join(process.env.USERPROFILE,
    ".cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright"));
const root = path.resolve(__dirname, "../..");
const base = path.join(root, "desktop/web");
const output = path.join(root, "verification/learning-mode/ui");
fs.mkdirSync(output,{recursive:true});
const server = http.createServer((req,res)=>{
    const target = path.resolve(base,"."+decodeURIComponent(req.url.split("?")[0]));
    const file = target===base ? path.join(base,"index.html") : target;
    if(!file.startsWith(base+path.sep)){res.writeHead(403).end();return;}
    fs.readFile(file,(error,data)=>{
        res.writeHead(error?404:200,{"Content-Type":({".js":"text/javascript",".html":"text/html",".css":"text/css"}[path.extname(file)]||"application/octet-stream")+"; charset=utf-8"});
        res.end(error?"":data);
    });
});
async function main(){
    await new Promise(resolve=>server.listen(0,"127.0.0.1",resolve));
    const browser=await chromium.launch({headless:true,executablePath:process.env.TANG_CHROME||"C:/Program Files/Google/Chrome/Application/chrome.exe"});
    const errors=[];
    try{
        const page=await browser.newPage({viewport:{width:1440,height:1250}});
        page.on("pageerror",e=>errors.push(e.message));
        await page.goto("http://127.0.0.1:"+server.address().port+"/");
        await page.evaluate(()=>neonApp.startDemo());
        const row=(key,on,deltaMs)=>({key,on,deltaMs,velocity:on?100:0});
        const score={version:1,title:"慢慢来：重复音与和弦",rows:[row(0,1,0),row(0,0,50),row(0,1,50),row(0,0,50),
            row(2,1,50),row(4,1,0),row(7,1,0),row(2,0,50),row(4,0,0),row(7,0,0)]};
        await page.setInputFiles("#fileInput",{name:"learning.json",mimeType:"application/json",buffer:Buffer.from(JSON.stringify(score))});
        await page.waitForFunction(()=>neonApp.selectedScore==="imported");
        await page.click("#learningButton");
        await page.waitForFunction(()=>document.querySelector("#guideTargets").textContent==="01 号键");
        await page.waitForTimeout(700);
        assert.match(await page.locator("#guideScoreName").textContent(),/已完成 0 步/);
        assert.equal(await page.locator(".guide-cell.is-target").count(),1);
        // 错键不会过关，鼠标操作走原有琴键业务与协议，而不是直接改画面。
        await page.click('.piano-key[data-index="1"]');
        await page.waitForTimeout(250);
        assert.match(await page.locator("#guideScoreName").textContent(),/已完成 0 步/);
        await page.click('.piano-key[data-index="0"]');
        await page.waitForFunction(()=>document.querySelector("#guideScoreName").textContent.includes("已完成 1 步"));
        await page.click('.piano-key[data-index="0"]');
        await page.waitForFunction(()=>document.querySelector("#guideTargets").textContent==="03 + 05 + 08 号键");
        assert.equal(await page.locator(".piano-key.guide-target").count(),3);
        await page.locator(".keyboard-panel").screenshot({path:path.join(output,"wait-for-chord.png")});
        // 模拟同时按住三键；普通UI单鼠标无法同时保持三个指针。
        await page.evaluate(async()=>{
            await neonApp.controller.noteOn("chord1",62,100,2);
            await neonApp.controller.noteOn("chord2",64,100,2);
        });
        const partial=await page.evaluate(()=>neonApp.controller.readLearningStatus());
        assert.equal(partial.completedSteps,2);
        await page.evaluate(async()=>{
            await neonApp.controller.noteOn("chord3",67,100,2);
            for(const id of ["chord1","chord2","chord3"])await neonApp.controller.noteOff(id);
        });
        await page.waitForFunction(()=>document.querySelector("#guideMapState").textContent==="本曲学习完成");
        assert.match(await page.locator("#guideScoreName").textContent(),/已完成 3 步/);
        await page.click("#learningButton");
        await page.waitForFunction(()=>document.querySelector("#guideTargets").textContent==="01 号键");
        await page.click("#learningButton");
        await page.waitForFunction(()=>document.querySelector("#guideMapState").textContent==="学习已停止");
        assert.equal(await page.locator(".guide-cell.is-target").count(),0);
        // 普通节奏指引仍可独立启动。
        await page.click("#guideButton");
        await page.waitForTimeout(500);
        await page.evaluate(()=>neonApp.controller.readStatus());
        assert.equal(await page.evaluate(()=>neonApp.controller.telemetry.guide),false);
        await page.setViewportSize({width:900,height:1000});
        await page.click("#learningButton");
        await page.waitForFunction(()=>document.querySelector("#guideTargets").textContent==="01 号键");
        assert.equal(await page.locator(".guide-panel").evaluate(el=>el.scrollWidth<=el.clientWidth),true);
        await page.locator(".keyboard-panel").screenshot({path:path.join(output,"learning-narrow.png")});
        await page.evaluate(()=>neonApp.controller.disconnect());
        await page.waitForFunction(()=>document.querySelector("#guideMapState").textContent==="设备未连接");
        assert.equal(await page.locator(".guide-cell.is-target").count(),0);
        assert.deepEqual(errors,[]);
        fs.writeFileSync(path.join(output,"result.json"),JSON.stringify({passed:true,hardwareTested:false,
            wait:true,wrongKey:true,repeatedKey:true,chord:true,restart:true,stop:true,disconnect:true,narrowLayout:true,pageErrors:errors},null,2));
        console.log("LEARNING UI PASS: waiting, wrong/repeated key, chord, completion, restart/stop, old timed guide, disconnect and 900px layout");
    }finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
}
main().catch(e=>{console.error(e);server.close();process.exitCode=1;});
