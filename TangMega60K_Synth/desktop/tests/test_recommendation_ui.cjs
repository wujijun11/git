"use strict";
// 真实DOM验证电脑/手机推荐刷新与原导入的衔接，所有网络桥与BLE均为固定激励。
const assert=require('node:assert/strict'),fs=require('node:fs'),http=require('node:http'),path=require('node:path');
const {chromium}=require(path.join(process.env.USERPROFILE,'.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright'));
const project=path.resolve(__dirname,'../..'),output=process.env.TANG_UI_OUTPUT||path.join(project,'verification/recommendations');
fs.mkdirSync(output,{recursive:true});
const midi=JSON.parse(fs.readFileSync(path.join(project,'verification/mobile/midi-fixtures.json'),'utf8'))[0].bytes;
const server=http.createServer((request,response)=>{
    const pathname=decodeURIComponent(request.url.split('?')[0]);
    const surface=pathname.startsWith('/phone/')?'mobile':'desktop';
    const root=path.join(project,surface,'web');
    const relative=pathname.replace(/^\/(phone|desktop)\//,'');
    const file=path.resolve(root,relative||'index.html');
    if(!file.startsWith(root+path.sep)){response.writeHead(403).end();return;}
    const types={'.html':'text/html','.js':'text/javascript','.css':'text/css'};
    fs.readFile(file,(error,bytes)=>{response.writeHead(error?404:200,{'Content-Type':(types[path.extname(file)]||'application/octet-stream')+'; charset=utf-8'});response.end(error?'':bytes);});
});
(async()=>{
    await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
    const browser=await chromium.launch({headless:true,executablePath:'C:/Program Files/Google/Chrome/Application/chrome.exe'}),errors=[];
    try{
        for(const phone of [false,true]){
            const page=await browser.newPage({viewport:{width:phone?390:1440,height:phone?844:1040}});
            page.on('pageerror',error=>errors.push(error.message));
            await page.addInitScript(({phone,midi})=>{
                window.recommendCalls=[];window.forceOffline=false;window.failRecommendation=false;
                const items=batch=>Array.from({length:6},(_,i)=>({title:`第${batch}批曲目${i} <img src=x onerror=alert(1)>`,composer:'Public Composer',instruments:'for Piano',license:'Public Domain',token:'song-'+batch+'-'+i,midiUrl:'https://www.mutopiaproject.org/test.mid',recommendationReason:'优先探索钢琴独奏'}));
                const recommendation=(batch,refresh)=>{
                    recommendCalls.push({batch,refresh});
                    if(failRecommendation)return {ok:false,error:'测试网络失败'};
                    return {ok:true,items:items(batch),offline:forceOffline,cached:forceOffline,offlineReason:forceOffline?'FileNotFoundError: TLS data <img src=x onerror=alert(1)>':undefined,note:'推荐尚需检查25键和事件容量'};
                };
                if(phone){
                    window.AndroidBle={cancelScoreLoad(){},disconnect(){},musicRequest(raw,id){
                        const request=JSON.parse(raw);
                        const result=request.action==='recommend'?recommendation(request.batch,request.refresh):
                            request.action==='search'?{ok:true,items:[items(99)[0]],hasNext:false}:
                            {ok:true,files:[{name:'recommended.mid',base64:btoa(String.fromCharCode(...midi)),attribution:items(0)[0]}]};
                        setTimeout(()=>nativeMusicResult(id,result),5);
                    }};
                }else{
                    window.pywebview={api:{recommend_music:async(batch,refresh)=>recommendation(batch,refresh),
                        search_music:async()=>({ok:true,items:[items(99)[0]],hasNext:false}),
                        fetch_music:async()=>({ok:true,files:[{name:'recommended.mid',token:'file',durationMs:1000,tracks:[{index:0,name:'Piano',notes:2}]}]})}};
                }
            },{phone,midi});
            const base='http://127.0.0.1:'+server.address().port;
            await page.goto(base+(phone?'/phone/':'/desktop/'));
            if(!phone)await page.click('[data-page=scores]');
            const next=phone?'#musicRecommendNext':'[data-action=recommend-next]',refresh=phone?'#musicRecommendRefresh':'[data-action=recommend-refresh]',
                list=phone?'#musicRecommendList':'.music-recommend-list',status=phone?'#musicRecommendStatus':'.music-recommend-status';
            await page.locator(next).scrollIntoViewIfNeeded();
            await page.waitForFunction(()=>recommendCalls.length===1);
            await page.waitForFunction(selector=>document.querySelector(selector).querySelectorAll('article').length===6,list);
            assert.equal(await page.locator(list+' img').count(),0,'untrusted title must remain text');
            assert.equal(await page.evaluate(()=>recommendCalls[0].batch),0);
            await page.click(next);await page.waitForFunction(()=>recommendCalls.length===2);
            assert.equal(await page.evaluate(()=>recommendCalls[1].batch),1);
            await page.locator(list+' button').first().click();
            const start=phone?'#musicStart':'.music-start',editor=phone?'#musicEditor':'.music-editor';
            await page.locator(editor).waitFor({state:'visible'});await page.locator(start).fill('0.123');
            await page.evaluate(()=>forceOffline=true);await page.click(refresh);
            await page.waitForFunction(selector=>document.querySelector(selector).textContent.includes('旧缓存'),status);
            if(!phone){
                assert.match(await page.locator(status).textContent(),/FileNotFoundError/,'cached cards must expose the real failure reason');
                assert.equal(await page.locator(status+' img').count(),0,'error details must remain plain text');
            }
            assert.deepEqual(await page.evaluate(()=>recommendCalls.at(-1)),{batch:1,refresh:true});
            assert.equal(await page.locator(start).inputValue(),'0.123','refresh must not replace current preview');
            const old=await page.locator(list).textContent();
            await page.evaluate(()=>failRecommendation=true);await page.click(refresh);
            await page.waitForFunction(selector=>document.querySelector(selector).textContent.includes('网络失败'),status);
            assert.equal(await page.locator(list).textContent(),old,'failed refresh must retain visible recommendations');
            assert.equal(await page.locator(refresh).isDisabled(),false);
            const query=phone?'#musicQuery':'#musicQuery';await page.locator(query).fill('Bach');
            await page.locator(phone?'#musicSearch button':'.music-search button[type=submit]').click();
            await page.locator(phone?'#musicResults article':'.music-results article').waitFor();
            assert.equal(await page.evaluate(phone=>phone?session===null:!neonApp.controller._ctx,phone),true,'recommend/search must never connect or send hardware commands');
            await page.locator(next).scrollIntoViewIfNeeded();await page.waitForTimeout(350);
            await page.locator(phone?'#musicRecommendations':'.music-recommendations').screenshot({path:path.join(output,phone?'phone-recommendations.png':'desktop-recommendations.png')});
            assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true);
            await page.close();
        }
        assert.deepEqual(errors,[]);
        const result={desktopAndPhone:true,autoLoad:true,batchChanges:true,refreshForcesNetworkFlag:true,
            offlineLabeled:true,failedRefreshPreservesCards:true,previewPreserved:true,importFromRecommendation:true,
            searchPreserved:true,textInjectionRejected:true,pageErrors:errors,hardwareAccessed:false};
        fs.writeFileSync(path.join(output,'ui-result.json'),JSON.stringify(result,null,2));
        console.log('RECOMMENDATION UI PASS desktop/phone auto load, new batch, forced refresh, offline/failure retention, preview/import/search and no hardware calls');
    }finally{await browser.close();server.close();}
})().catch(error=>{console.error(error);server.close();process.exitCode=1;});
