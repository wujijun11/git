'use strict';
(() => {
 const APP_VERSION='1.5.0-local';
 const $=id=>document.getElementById(id), P=RemoteProtocol;
 const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const names=['C','C♯','D','D♯','E','F','F♯','G','G♯','A','A♯','B'];
 const noteName=m=>names[m%12]+(Math.floor(m/12)-1);
 const shortcutModel=new ShortcutBindings.KeyboardBindings();
 const bindings=shortcutModel.snapshot();
 const bindLabel=ShortcutBindings.label;
 const presetNames=['纯净正弦','经典风琴','参数钢琴','FM 电钢琴'];
 const presetDescriptions=['一束纯净的声音，探索合成的起点。','饱满、明亮，铺展开温暖的和声。','温润、清晰，让每一个音符自然流动。','清脆的泛音，为灵感添一点电流。'];
 let nativeTransport=null,connecting=false,selectedTransport='ble',previewEnabled=false,localAudio=null,activeKeys=new Map(),keyRefs=new Map(),noteTrails=[],lastNote=null,toastTimer,logs=[],lastTelemetryAt=0,selectedScore='builtin',uploadedScore=null,visualMic=null,recordCache=[],fileLoadGeneration=0;
 let playbackTimer=null,playbackToken=0,previewPlaying=false,realtimePlayback=null,guidePanel=null,learningControl=null;
 let currentConnectionGeneration=0,playGeneration=0,dataBusy=false,lastBridgeDiagnostics=null,lastControllerState=null;
 const controller=new NeonController({onState:onState,onTelemetry:onTelemetry,onLog:log,onEvent:()=>{},modeSync:true,onBoardMode:onBoardMode,
  onTiming:t=>{if(t.op===P.OP.NOTE)$('latencyDetails').textContent='最近按键：本机排队 '+t.queueMs.toFixed(1)+' ms · 请求至确认 '+t.serviceMs.toFixed(1)+' ms';}});
 realtimePlayback = new DesktopRealtimePlayback({controller,
  getConnection:()=>currentConnectionGeneration, getScore:()=>scores[selectedScore],
  assertIdle:()=>{if(dataBusy)throw Error('等待当前数据操作完成');},
  statusNode:$('realtimeStatus'), message,
  beforeStart:()=>{guidePanel?.clear();clearVisualKeys();stopPreviewScore();playGeneration++;}});
 bind('realtimePlay',()=>realtimePlayback.start());
 bind('realtimeStop',()=>realtimePlayback.stop());
 document.addEventListener('visibilitychange',()=>{
  if(document.hidden && realtimePlayback.busy)
   message('窗口已进入后台，蓝牙实时曲谱继续发送；请勿关闭程序或断开设备。');
 });
 function onBoardMode(state){
  if(!state){$('boardMode').textContent='板上模式：等待状态回传；旧程序可能不支持';return;}
  const pages=['音色','音区','录放','曲谱 / 指引'];
  $('boardMode').textContent='板上模式：'+(state.mainMenu?'总菜单':pages[state.page])+' · '+presetNames[state.timbre]+' · 音区 '+(state.transpose>0?'+':'')+state.transpose+' 半音 · '+(state.recording?'录制中':state.playing?'播放中':state.guide?'指引中':'待机')+(state.busy?' · 切换中':'');
  updatePreset(state.timbre);$('effect').value=String(state.effect);
 }
 window.neonApp={controller,get activeKeys(){return activeKeys},get recordCache(){return recordCache},get selectedScore(){return selectedScore},get bridgeDiagnostics(){return lastBridgeDiagnostics},startDemo:()=>connectDemo()};
 function log(message){logs.unshift(new Date().toLocaleTimeString('zh-CN',{hour12:false})+'  '+message);logs=logs.slice(0,180);$('connectionLog').textContent=logs.join('\n');}
 function message(text,error=false){$('footerMessage').textContent=text;$('toast').textContent=text;$('toast').className='toast visible'+(error?' error':'');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').classList.remove('visible'),error?6500:3500);if(error)log(text);}
 async function run(fn){try{return await fn();}catch(e){if(!e.cancelled)message(e.message||String(e),true);return null;}}
 async function dataOperation(fn){if(realtimePlayback?.busy)throw Error('请先停止蓝牙实时播放');if(dataBusy)throw new Error('数据操作正在进行，请等待完成或点击停止。');dataBusy=true;const elements=document.querySelectorAll('#recordStart,#recordStop,#readRecording,#exportRecording,#replayRecording,#clearRecording,#uploadScore,#scorePlay,#playButton,#guideButton,#learningButton,#importScore,.score-card,#resetMapping,.map-item input');for(const el of elements)el.disabled=true;try{return await fn();}finally{dataBusy=false;for(const el of elements)el.disabled=false;}}
 function clearRecordCache(){recordCache=[];controller.recorded=[];renderRecording([]);$('recordInfo').textContent='本会话尚未回读事件';}
 function bind(id,fn){$(id).addEventListener('click',()=>run(fn));}
 function onState(state){
  lastControllerState=state;
  if (!state.ready && !state.connected) { learningControl?.cancel(); guidePanel?.clear('disconnected'); }
  const demo=state.mode==='demo';$('connectionStatus').className='connection-pill'+(state.ready?(demo?' demo':' connected'):'');
  $('connectionStatus').querySelector('span').textContent=state.ready?(demo?'离线演示':'FPGA 已连接'):state.connected?'正在握手':'设备未连接';
  $('connectButton').innerHTML='<svg><use href="#i-plug"/></svg>'+(state.ready?'设备连接':'连接设备');
  $('modeValue').textContent=state.ready?(demo?'演示 · 无硬件':state.mode==='ble'?'蓝牙 BLE':'USB-UART'):'离线';
  $('modalStatus').textContent=state.status;$('keyboardHint').textContent=state.ready?(demo?'演示模式 · 可开启电脑试听':'演奏命令发送至 FPGA · 音源由开发板合成'):'连接设备或进入演示，即可开始演奏';
  $('footerMessage').textContent=state.status;
  if(!state.ready&&!state.connected)$('boardMode').textContent='板上模式：未连接，无法确认当前状态';
  if(!state.ready&&!state.connected){realtimePlayback?.stop();playGeneration++;clearVisualKeys();stopPreviewScore();clearRecordCache();$('voiceCount').innerHTML='—<em> / 64</em>';$('latencyValue').innerHTML='—<em> ms</em>';$('underrunValue').textContent='—';$('recordDot').classList.remove('on');}
  for(const el of document.querySelectorAll('.piano-key'))el.setAttribute('aria-disabled',String(!state.ready));
 }
 function onTelemetry(t){
  guidePanel?.accept(t);
  lastTelemetryAt=performance.now();$('voiceCount').innerHTML=t.activeVoices+'<em> / 64</em>';$('underrunValue').textContent=String(t.audioUnderruns);
  $('sessionTag').textContent=t.recording?'RECORDING':t.playing?'PLAYING':t.guide?'GUIDE':'IDLE';
  $('recordCount').textContent=String(t.recordCount).padStart(4,'0');$('recordDot').classList.toggle('on',t.recording);$('guideButton').classList.toggle('on',t.guide);$('guideButton').setAttribute('aria-pressed',String(t.guide));
  $('playButton').innerHTML='<svg><use href="'+(t.playing?'#i-stop':'#i-play')+'"/></svg>';$('playButton').setAttribute('aria-label',t.playing?'停止曲谱':'播放所选曲谱');
  const rows=selectedScore==='builtin'?64:scores[selectedScore]?.rows.length||64;$('trackProgress').style.width=(t.playing?Math.min(100,t.scorePosition/rows*100):0)+'%';
  if(t.overflow)$('footerMessage').textContent='FPGA 报告资源溢出，请点击“全部停止”并检查设备。';
 }
 const keyboard=$('keyboard');let whites=[];
 for(let i=0;i<25;i++)if(![1,3,6,8,10].includes(i%12))whites.push(i);
 for(let i=0;i<25;i++){
  const black=[1,3,6,8,10].includes(i%12),el=document.createElement('button');el.className='piano-key'+(black?' black':'');el.dataset.index=i;el.setAttribute('aria-label','琴键 '+(i+1)+'，'+noteName(60+i)+'，电脑键 '+bindLabel(bindings[i]));
  if(black){const before=whites.filter(w=>w<i).length;el.style.left='calc(4px + (100% - 8px) * '+(before/15)+' - 2.075%)';}
  el.innerHTML='<span class="key-note">'+noteName(60+i)+'</span><span class="key-binding">'+bindLabel(bindings[i])+'</span>';
  el.addEventListener('pointerdown',e=>{e.preventDefault();if(!controller.ready){message('先连接 FPGA，或在连接窗口选择“离线演示”。');return;}el.setPointerCapture(e.pointerId);pressKey('pointer:'+e.pointerId,i);});
  el.addEventListener('pointerup',e=>releaseKey('pointer:'+e.pointerId));el.addEventListener('pointercancel',e=>releaseKey('pointer:'+e.pointerId));el.addEventListener('lostpointercapture',e=>releaseKey('pointer:'+e.pointerId));keyboard.append(el);
 }
 // 灯位图和琴键共享固定1–25编号；定位操作不触发音符，也不更改实际灯珠顺序。
 const guideContainer = document.createElement('section');
 guideContainer.setAttribute('aria-label', '灯位与琴键对照');
 keyboard.before(guideContainer);
 const learningButton = document.createElement('button');
 learningButton.id = 'learningButton';
 learningButton.type = 'button';
 learningButton.className = 'guide-button';
 learningButton.textContent = '等我弹对';
 guidePanel = new GuidePanel({
  container: guideContainer,
  keyboard,
  getMapping: () => controller.mapping,
  guideButton: $('guideButton'),
  learningButton,
 });
 function pressKey(id,index){
  if(realtimePlayback.busy){message('实时播放期间请使用实体琴键；电脑琴键暂不发送。');return;}
  if(!controller.ready||activeKeys.has(id))return;
  const midi=controller.mapping[index],vel=Number($('velocity').value);activeKeys.set(id,{index,midi});keyRefs.set(index,(keyRefs.get(index)||0)+1);keyboard.children[index].classList.add('pressed');
  lastNote={midi,time:performance.now()};$('activeNote').textContent=noteName(midi);$('activeMidi').textContent='MIDI '+midi+' / VEL '+vel;noteTrails.push({index,midi,start:performance.now(),end:null,id});
  if(previewEnabled)audio().noteOn(id,midi,vel,controller.timbre);
  const sent=performance.now();controller.noteOn(id,midi,vel,controller.timbre).then(()=>{$('latencyValue').innerHTML=Math.round(performance.now()-sent)+'<em> ms</em>';}).catch(e=>{if(!e.cancelled)message(e.message,true);});
 }
 function releaseKey(id){const held=activeKeys.get(id);if(!held)return;activeKeys.delete(id);const refs=(keyRefs.get(held.index)||1)-1;keyRefs.set(held.index,refs);if(!refs)keyboard.children[held.index].classList.remove('pressed');for(const trail of noteTrails)if(trail.id===id&&trail.end===null)trail.end=performance.now();localAudio?.noteOff(id);controller.noteOff(id).catch(e=>{if(!e.cancelled)message(e.message,true);});}
 function clearVisualKeys(){activeKeys.clear();keyRefs.clear();for(const el of keyboard.children)el.classList.remove('pressed','guided');for(const t of noteTrails)if(t.end===null)t.end=performance.now();localAudio?.allOff();}
 function releaseAll(){clearVisualKeys();return controller.releaseAll().catch(e=>log(e.message));}
 function releaseOnFocusLoss(){
  // 实时曲谱占用自己的远程音符集合。切换窗口时不能调用releaseAll，
  // 否则会把正在播放的曲谱音符误当作手动琴键释放。
  if(realtimePlayback.busy)return;
  releaseAll();
 }
 window.addEventListener('blur',releaseOnFocusLoss);document.addEventListener('visibilitychange',()=>{if(document.hidden)releaseOnFocusLoss();});
 function updateShortcutLabels(){
  const codes=shortcutModel.snapshot();
  for(let i=0;i<25;i++){
   const el=keyboard.children[i];el.querySelector('.key-binding').textContent=bindLabel(codes[i]);
   el.setAttribute('aria-label','琴键 '+(i+1)+'，'+noteName(controller.mapping[i])+'，电脑键 '+bindLabel(codes[i]));
  }
  document.querySelector('.keyboard-footer>span').textContent=shortcutModel.isDefault()?'默认电脑布局 · 按琴键下方标记演奏 · 可在设置中自定义':'自定义电脑布局 · 按琴键下方标记演奏 · 可在设置中修改';
 }
 const shortcutPanel=new KeyboardShortcutPanel({container:$('page-settings'),model:shortcutModel,getAPI:nativeAPI,
  beforeChange:releaseAll,onChange:updateShortcutLabels,message,canPlay:()=>controller.ready&&!$('connectDialog').open,
  press:pressKey,release:releaseKey,panic:()=>run(panic)});
 function audio(){if(!localAudio)localAudio=new PreviewSynth();localAudio.ctx.resume().catch(()=>{});return localAudio;}
 class PreviewSynth{
  constructor(){this.ctx=new AudioContext();this.master=this.ctx.createGain();this.master.gain.value=.2;const comp=this.ctx.createDynamicsCompressor();this.master.connect(comp);comp.connect(this.ctx.destination);this.notes=new Map();}
  noteOn(id,midi,velocity,timbre){if(this.notes.has(id))return;const now=this.ctx.currentTime,env=this.ctx.createGain(),f=440*2**((midi-69)/12),osc=this.ctx.createOscillator();osc.frequency.value=f;osc.type=['sine','triangle','triangle','sine'][timbre];env.gain.setValueAtTime(0,now);env.gain.linearRampToValueAtTime(velocity/127*.19,now+.012);env.gain.exponentialRampToValueAtTime(.025,now+1.6);osc.connect(env);env.connect(this.master);let mod=null,modGain=null;if(timbre===3){mod=this.ctx.createOscillator();mod.frequency.value=f*2;modGain=this.ctx.createGain();modGain.gain.setValueAtTime(f*.65,now);modGain.gain.exponentialRampToValueAtTime(f*.02,now+.7);mod.connect(modGain);modGain.connect(osc.frequency);mod.start();}osc.start();this.notes.set(id,{osc,env,mod});}
  noteOff(id){const n=this.notes.get(id);if(!n)return;this.notes.delete(id);const now=this.ctx.currentTime;n.env.gain.cancelScheduledValues(now);n.env.gain.setTargetAtTime(0,now,.045);n.osc.stop(now+.3);n.mod?.stop(now+.3);setTimeout(()=>{n.env.disconnect();n.osc.disconnect();n.mod?.disconnect();},400);}
  allOff(){for(const id of this.notes.keys())this.noteOff(id);}
 }
 bind('previewToggle',()=>{previewEnabled=!previewEnabled;$('previewToggle').classList.toggle('on',previewEnabled);$('previewToggle').setAttribute('aria-pressed',String(previewEnabled));$('previewToggle').querySelector('span').textContent=previewEnabled?'ON':'OFF';if(previewEnabled){audio();message('电脑试听已开启：由电脑合成，与 FPGA 的实际音色可能不同。');}else localAudio?.allOff();});
 function setRange(el){el.style.setProperty('--range',100*(Number(el.value)-Number(el.min))/(Number(el.max)-Number(el.min))+'%');}
 for(const el of document.querySelectorAll('input[type=range]')){setRange(el);el.addEventListener('input',()=>setRange(el));}
 for(const [id,key,format]of [['gain','gain',v=>Math.round(v/2048*100)+'%'],['bend','bend',v=>v+' ct'],['vibrato','vibrato',v=>v+' ct']]){
  $(id).addEventListener('input',()=>{const v=Number($(id).value);$(id+'Value').textContent=format(v);if(key==='gain'&&localAudio)localAudio.master.gain.setTargetAtTime(.2*v/2048,localAudio.ctx.currentTime,.02);if(controller.ready)controller.setExpression({[key]:v}).catch(e=>log(e.message));else controller[key]=v;});
 }
 $('velocity').addEventListener('input',()=>$('velocityValue').textContent=$('velocity').value);
 bind('resetExpression',async()=>{for(const key of ['bend','vibrato']){$(key).value=0;$(key+'Value').textContent='0 ct';setRange($(key));}if(controller.ready)await controller.setExpression({bend:0,vibrato:0});else controller.bend=controller.vibrato=0;});
 for(const button of $('soundPresets').children)button.addEventListener('click',()=>run(async()=>{const value=Number(button.dataset.timbre);if(controller.ready)await controller.configure(0,value);else controller.timbre=value;updatePreset(value);}));
 function updatePreset(value){for(const b of $('soundPresets').children)b.classList.toggle('selected',Number(b.dataset.timbre)===value);$('presetName').textContent=presetNames[value];$('presetIndex').textContent=String(value+1).padStart(2,'0')+' / 04';$('presetDescription').textContent=presetDescriptions[value];}
 $('effect').addEventListener('change',()=>run(async()=>{if(controller.ready)await controller.configure(1,Number($('effect').value));else controller.effect=Number($('effect').value);}));
 const pageTexts={studio:['YOUR SOUND. YOUR SPACE.','让灵感，发出光','从一次触键开始，进入你的声音宇宙。'],scores:['A LIBRARY OF POSSIBILITIES.','让旋律，有迹可循','曲谱导入、设备播放，让创作流畅发生。'],recordings:['CAPTURE THE MOMENT.','记录此刻的你','音符与时间，留下每一次值得回放的灵感。'],settings:['MAKE IT YOUR OWN.','为你的演奏，重新定义','从连接到琴键映射，让声音属于自己。']};
 for(const b of document.querySelectorAll('[data-page]'))b.addEventListener('click',()=>{const page=b.dataset.page;releaseAll();for(const p of document.querySelectorAll('.page'))p.classList.toggle('active',p.id==='page-'+page);for(const n of document.querySelectorAll('[data-page]'))n.classList.toggle('active',n===b);$('pageEyebrow').textContent=pageTexts[page][0];$('pageTitle').innerHTML=pageTexts[page][1]+'<span>。</span>';$('pageSubtitle').textContent=pageTexts[page][2];});
 bind('connectButton',()=>$('connectDialog').showModal());bind('closeDialog',()=>$('connectDialog').close());
 for(const b of document.querySelectorAll('[data-transport]'))b.addEventListener('click',()=>{selectedTransport=b.dataset.transport;for(const t of document.querySelectorAll('[data-transport]'))t.classList.toggle('active',t===b);for(const k of ['ble','serial','demo'])$(k+'Connection').hidden=k!==selectedTransport;});
 function nativeAPI(){return window.pywebview?.api||null;}
 function nativeResult(r){if(!r?.ok)throw new Error(r?.error||'设备操作失败');return r;}
 window.nativeReceive=(hex,generation)=>{if(nativeTransport?.generation===generation)nativeTransport.receive(hex);};
 window.nativeTransportState=(state,text,generation)=>{if(nativeTransport?.generation!==generation)return;if(state==='disconnected'||state==='error')nativeTransport.lost(new Error(text||'连接已断开'));else $('modalStatus').textContent=text;};
 function bridgeDiagnosticText(report){
  const after=report.after||{},delta=report.delta;
  if(!after.available){const reasons={missing_characteristic:'固件未提供诊断特征',read_timeout:'诊断读取超时',read_failed:'诊断读取失败',link_closed:'蓝牙通道已关闭',stale_generation:'连接已变化',unsupported_format:'诊断格式未知'};return '未取得可用的C3诊断（'+(reasons[after.reason]||'诊断不可用')+'）；FPGA握手仍未验证。';}
  const counts=delta||after.counters||{},traffic=['bleReceivedFrames','uartSentFrames','uartReceivedBytes','uartValidFrames','notifyAcceptedFrames'];
  if(after.format==='legacy16')return 'C3仅提供旧版错误计数，无法判断UART流量；FPGA握手仍未验证。';
  if(after.format!=='TBv1'||traffic.some(k=>!Number.isInteger(counts[k])||counts[k]<0||counts[k]>0xffffffff))return '诊断格式未知；FPGA握手仍未验证。';
  const values=traffic.map(k=>(delta?'+':'')+counts[k]).join(' / '),numbers='BLE收帧 / UART提交 / UART返回字节 / 有效帧 / 通知接受：'+values+'。';
  if(!delta)return '缺少有效的连接基线，仅有累计计数，不能判断本次流量。'+numbers+'FPGA握手仍未验证。';
  let layer='C3诊断未能确定故障层级';
  if(after.uartInitialized===false)layer='C3报告UART未初始化';
  else if(counts.uartSentFrames>0&&counts.uartReceivedBytes===0)layer='C3报告已提交UART，未收到FPGA返回字节';
  else if(counts.bleReceivedFrames===0)layer='C3未记录本次蓝牙数据帧';
  else if(counts.uartSentFrames===0)layer='C3收到蓝牙数据，但未报告提交UART';
  else if(counts.uartValidFrames===0)layer='C3收到UART字节，但未解析到有效响应帧';
  else if(counts.notifyAcceptedFrames===0)layer='C3解析到有效响应帧，但未报告蓝牙主机接受通知';
  else layer='C3报告蓝牙主机已接受通知，电脑尚未确认对应的FPGA响应';
  return layer+'。'+numbers+'FPGA握手仍未验证。';
 }
 function buildNativeTransport(generation,attempt){
  let bytes=()=>{},lost=()=>{};
  const transport={generation,diagnosticText:null,closePromise:null,
   write:async data=>{const result=nativeResult(await nativeAPI().write_frame(Array.from(data,b=>b.toString(16).padStart(2,'0')).join(''),generation));transport.lastWriteMetrics=result;if(!transport.linkLogged&&result.connectionPreference){log('Windows BLE连接参数：'+JSON.stringify(result.connectionPreference));transport.linkLogged=true;}return result;},
   close:()=>{
    if(transport.closePromise)return transport.closePromise;
    transport.closePromise=(async()=>{try{
     const result=await nativeAPI()?.disconnect(generation);
     if(nativeTransport!==transport||(currentConnectionGeneration!==attempt&&currentConnectionGeneration!==transport.userDisconnectAttempt)||controller.ready||result?.diagnostics?.generation!==generation)return;
     lastBridgeDiagnostics=result.diagnostics;
     log('C3断开只读诊断：'+JSON.stringify(result.diagnostics));
     const original=lastControllerState?.error;
     if(original&&/ACK 超时|数据响应超时|写入超时|设备写入失败|蓝牙连接已断开|连接已关闭/.test(original)){
      transport.diagnosticText=bridgeDiagnosticText(result.diagnostics);log(transport.diagnosticText);
      const text=original+'；'+transport.diagnosticText;$('modalStatus').textContent=text;message(text,true);
     }
    }finally{if(nativeTransport===transport)nativeTransport=null;}})();
    return transport.closePromise;
   },
   onBytes:fn=>{bytes=fn;return()=>{bytes=()=>{};};},onDisconnect:fn=>{lost=fn;return()=>{lost=()=>{};};},
   receive:hex=>bytes(Uint8Array.from(hex.match(/../g)||[],h=>parseInt(h,16))),lost:e=>lost(e)};
  return transport;
 }
 function connectionBusy(value){connecting=value;for(const id of ['scanBle','scanSerial','startDemo'])$(id).disabled=value;for(const d of document.querySelectorAll('.device'))d.disabled=value;}
 async function connectDevice(kind,id){if(connecting)return;connectionBusy(true);const attempt=++currentConnectionGeneration;playGeneration++;lastBridgeDiagnostics=null;clearRecordCache();$('modalStatus').textContent='正在连接通道…';let transport=null;try{await controller.disconnect();if(attempt!==currentConnectionGeneration)return;const result=nativeResult(await nativeAPI().connect(kind,id));if(attempt!==currentConnectionGeneration){await nativeAPI().disconnect(result.generation);return;}transport=buildNativeTransport(result.generation,attempt);nativeTransport=transport;await controller.connect(transport,kind);if(attempt!==currentConnectionGeneration)return;uploadedScore=null;$('connectDialog').close();message('FPGA 握手通过，开始你的演奏。');}catch(e){if(attempt!==currentConnectionGeneration)return;const error=transport?.diagnosticText?new Error(e.message+'；'+transport.diagnosticText):e;$('modalStatus').textContent=error.message;throw error;}finally{connectionBusy(false);}}
 async function connectDemo(){if(connecting)return;connectionBusy(true);const attempt=++currentConnectionGeneration;playGeneration++;lastBridgeDiagnostics=null;clearRecordCache();try{await controller.connect(createDemoTransport(),'demo');if(attempt!==currentConnectionGeneration)return;uploadedScore=null;$('connectDialog').close();message('已进入离线演示。可开启“电脑试听”，体验本机演奏。');}finally{connectionBusy(false);}}
 bind('startDemo',connectDemo);
 bind('scanBle',async()=>{if(!nativeAPI()){if(navigator.bluetooth){await connectWebBluetooth();return;}throw new Error('请使用打包的 Windows 桌面版连接蓝牙。当前浏览器可体验离线演示。');}$('bleDevices').innerHTML='<span class="muted">正在扫描，请等待约 6 秒…</span>';connectionBusy(true);try{const r=nativeResult(await nativeAPI().scan_ble());showDevices('bleDevices',r.devices,'ble');}finally{connectionBusy(false);}});
 bind('scanSerial',async()=>{if(!nativeAPI())throw new Error('USB-UART 连接请使用 Windows 桌面版。');connectionBusy(true);try{const r=nativeResult(await nativeAPI().list_serial());showDevices('serialDevices',r.ports,'serial');}finally{connectionBusy(false);}});
 function showDevices(container,devices,kind){$(container).replaceChildren();if(!devices?.length){$(container).innerHTML='<span class="muted">未发现设备，请检查供电与连接后重试。</span>';return;}for(const device of devices){const b=document.createElement('button');b.className='device';b.disabled=connecting;b.innerHTML='<span><strong>'+esc(device.name||device.id)+'</strong><small>'+esc(device.id)+'</small></span><svg><use href="#i-arrow"/></svg>';b.onclick=()=>run(()=>connectDevice(kind,device.id));$(container).append(b);}}
 async function connectWebBluetooth(){if(connecting)return;connectionBusy(true);const attempt=++currentConnectionGeneration;playGeneration++;clearRecordCache();let device=null,transport=null;const check=()=>{if(attempt!==currentConnectionGeneration)throw new Error('蓝牙连接已取消');};try{await controller.disconnect();check();device=await navigator.bluetooth.requestDevice({filters:[{services:[P.UUID.service]}]});check();const gatt=await device.gatt.connect();check();const service=await gatt.getPrimaryService(P.UUID.service);check();const rx=await service.getCharacteristic(P.UUID.rx);check();const tx=await service.getCharacteristic(P.UUID.tx);check();await tx.startNotifications();check();let onBytes=()=>{},onLost=()=>{};const recv=e=>{const v=e.target.value;onBytes(new Uint8Array(v.buffer,v.byteOffset,v.byteLength));},lost=()=>onLost(new Error('蓝牙连接已断开'));tx.addEventListener('characteristicvaluechanged',recv);device.addEventListener('gattserverdisconnected',lost);transport={write:b=>rx.writeValueWithResponse(b),close:()=>{tx.removeEventListener('characteristicvaluechanged',recv);device.removeEventListener('gattserverdisconnected',lost);device.gatt.disconnect();},onBytes:f=>{onBytes=f;return()=>onBytes=()=>{};},onDisconnect:f=>{onLost=f;return()=>onLost=()=>{};}};await controller.connect(transport,'ble');check();uploadedScore=null;$('connectDialog').close();message('FPGA 握手通过。');}catch(e){if(transport)transport.close();else if(device?.gatt.connected)device.gatt.disconnect();if(attempt===currentConnectionGeneration)throw e;}finally{connectionBusy(false);}}
 bind('disconnectButton',async()=>{currentConnectionGeneration++;if(nativeTransport)nativeTransport.userDisconnectAttempt=currentConnectionGeneration;playGeneration++;await controller.disconnect();clearVisualKeys();message('已断开设备连接。');});
 async function panic(){learningControl?.cancel();guidePanel?.clear();await realtimePlayback.stop();playGeneration++;stopPreviewScore();clearVisualKeys();if(controller.ready){await controller.panic();await controller.readStatus();}message('全部停止。');}
 bind('panicButton',panic);
 async function stop(){learningControl?.cancel();guidePanel?.clear();await realtimePlayback.stop();playGeneration++;stopPreviewScore();if(controller.ready){await controller.transportAction(0);await controller.readStatus();}}
 bind('stopButton',stop);
 function makeScore(title,notes,beat=380){const rows=[];for(const [i,n]of notes.entries()){rows.push({deltaMs:i?80:0,key:n-60,velocity:96,on:1},{deltaMs:beat,key:n-60,velocity:0,on:0});}return {version:1,title,rows};}
 const scores={builtin:{version:1,title:'欢乐颂',builtin:true,rows:[]},twinkle:makeScore('小星星',[60,60,67,67,69,69,67,65,65,64,64,62,62,60],380),night:makeScore('霓虹漫游',[60,64,67,72,71,67,64,62,65,69,72,76,74,69,65,60],280)};
 function renderScores(){const cards=[['builtin','01','FPGA 内置 · 即选即播'],['twinkle','02','28 个事件 · 经典练习'],['night','03','32 个事件 · NEON ORIGINAL']];if(scores.imported)cards.push(['imported','04',scores.imported.rows.length+' 个事件 · 本地导入']);$('scoreGrid').replaceChildren();for(const [id,no,caption]of cards){const b=document.createElement('button');b.className='score-card'+(id===selectedScore?' selected':'');b.dataset.score=id;b.innerHTML='<span class="card-number">SCORE / '+no+'</span><svg><use href="#i-music"/></svg><h3>'+esc(scores[id].title)+'</h3><p>'+esc(caption)+'</p>';b.onclick=()=>selectScore(id);$('scoreGrid').append(b);}}
 function selectScore(id){if(realtimePlayback.busy){message('请先停止蓝牙实时播放');return;}if(dataBusy){message('等待当前数据操作完成，或点击停止。');return;}playGeneration++;selectedScore=id;const s=scores[id];$('scoreTitle').textContent=s.title;$('currentTrack').textContent=s.title;$('scoreMeta').textContent=s.builtin?'在开发板内定时播放的内置曲谱。':s.rows.length+' 条音符事件 · '+(s.playback==='direct'?'直接音高 / FPGA当前音色 / 不改键位':'25键映射')+(s.transport==='realtime'?' · 上位机实时曲谱':' · 待上传');$('scoreState').textContent=s.builtin?'FPGA 内置':uploadedScore===s?'已上传':'尚未上传';$('trackDetail').textContent=s.builtin?'FPGA 内置曲谱 · 首次播放自动选择':s.rows.length+' 条事件 · '+(s.transport==='realtime'?'点击蓝牙实时播放':uploadedScore===s?'已上传 FPGA':'待上传 FPGA');$('scorePreview').textContent=s.builtin?'内置曲谱保存在 FPGA 工程中。\n点击播放后将选择开发板内置曲谱。':s.rows.slice(0,16).map((r,i)=>String(i+1).padStart(3,'0')+'   +'+String(r.deltaMs).padStart(4,' ')+' ms   '+noteName(s.playback==='direct'?r.midi:(s.mapping||controller.mapping)[r.key]).padEnd(4,' ')+'  '+(r.on?'NOTE ON ':'NOTE OFF')+'   VEL '+r.velocity).join('\n')+(s.rows.length>16?'\n… 共 '+s.rows.length+' 条事件':'');renderScores();}
 async function uploadSelected(score = scores[selectedScore]) {
    if(score.transport==='realtime')throw Error('这份曲谱选择了实时发送，请点击蓝牙实时播放；上传需重新按板上容量分析。');
    if (score.builtin) {
        await controller.selectBuiltin();
        uploadedScore = score;
        message('已选择 FPGA 内置曲谱。');
        return;
    }
    const connection = currentConnectionGeneration;
    const operation = playGeneration;
    uploadedScore = null;
    try {
        await MappedScoreUpload.uploadMappedScore({
            controller,
            score,
            isCancelled: () => operation !== playGeneration || connection !== currentConnectionGeneration,
            sameConnection: () => connection === currentConnectionGeneration,
            onRestoreError: error => log('键位恢复未完成：' + error.message),
            onProgress: ({completed, total}) => {
                $('uploadProgress').firstElementChild.style.width = (completed / total * 100) + '%';
                $('scoreState').textContent = '上传 ' + completed + '/' + total;
            }
        });
        uploadedScore = score;
        if (scores[selectedScore] === score) {
            $('scoreState').textContent = '已上传';
            $('trackDetail').textContent = score.rows.length + ' 条事件 · 已上传 FPGA';
        }
        message('曲谱已完整上传并提交。请把滑条音区设为标准后播放。');
    } catch (error) {
        $('scoreState').textContent = '上传未完成，请重新上传';
        throw error;
    } finally {
        for (let index = 0; index < 25; index++) {
            $('map-' + index).value = controller.mapping[index];
            keyboard.children[index].querySelector('.key-note').textContent = noteName(controller.mapping[index]);
        }
    }
 }
 // 指引复用板上曲谱时序，只显示目标琴键，不自动替用户弹奏。
 learningControl = new LearningControl({
  controller,
  getScore: () => scores[selectedScore],
  getGeneration: () => currentConnectionGeneration,
  prepareScore: async score => { if (score.builtin || uploadedScore !== score) await uploadSelected(score); },
  runExclusive: dataOperation,
  onStatus: (status, title) => guidePanel.learning(status, title, controller.mode === 'demo'),
  onError: error => { guidePanel.clear(); message(error.message, true); },
 });
 bind('learningButton', async () => {
  const started = await learningControl.toggle();
  message(started ? '学习已开始：先松键，再按绿色提示。按对才进入下一步。' : '学习已停止。');
 });
 bind('guideButton', async () => {
  learningControl.cancel();
  try {
   const started = await DesktopGuideControl.toggle({
    controller,
    getScore: () => scores[selectedScore],
    getGeneration: () => currentConnectionGeneration + ':' + playGeneration,
    prepareScore: async score => {
     if (score.builtin || uploadedScore !== score) await uploadSelected(score);
    },
    onStartPending: score => guidePanel.arm(score, controller.mode === 'demo'),
    runExclusive: dataOperation,
   });
   message(started
    ? '已启动逐键灯光指引：灯图与同号琴键一起高亮，不会等待弹对。'
    : '已停止灯光指引。');
   if (!started) guidePanel.clear();
  } catch (error) {
   guidePanel.clear();
   throw error;
  }
 });
 bind('uploadScore',()=>dataOperation(()=>uploadSelected()));
 async function play(){
  if(!controller.ready)throw new Error('请先连接设备，或进入离线演示。');
  if(controller.telemetry?.playing){await stop();return;}
  const token=++playGeneration,connection=currentConnectionGeneration,s=scores[selectedScore];
  const check=()=>{if(token!==playGeneration||connection!==currentConnectionGeneration||!controller.ready)throw new Error('播放已取消');};
  return dataOperation(async()=>{
   if(s.builtin){await controller.selectBuiltin();uploadedScore=s;}else if(uploadedScore!==s)await uploadSelected(s);
   check();await controller.transportAction(1);check();await controller.readStatus();check();
   if(controller.mode==='demo'){const preview=s.builtin?makeScore('欢乐颂',[64,64,65,67,67,65,64,62,60,60,62,64,64,62,62],350):s;startPreviewScore(preview);}
   message(controller.mode==='demo'?'演示曲谱正在运行；开启电脑试听可听到本机音源。':'曲谱已交由 FPGA 播放。');
  });
 }
 bind('playButton',play);bind('scorePlay',play);
 function startPreviewScore(score){stopPreviewScore();const token=++playbackToken;previewPlaying=true;let index=0;function step(){if(token!==playbackToken||!controller.ready||controller.mode!=='demo')return;if(index>=score.rows.length){previewPlaying=false;run(async()=>{await controller.transportAction(0);await controller.readStatus();});return;}const r=score.rows[index++];playbackTimer=setTimeout(()=>{if(token!==playbackToken)return;const direct=score.playback==='direct',key=direct?null:keyboard.children[r.key],midi=direct?r.midi:controller.mapping[r.key];key?.classList.toggle('guided',!!r.on);if(r.on){lastNote={midi,time:performance.now()};$('activeNote').textContent=noteName(midi);$('activeMidi').textContent='DEMO SCORE / MIDI '+midi;noteTrails.push({index:direct?r.midi/127*24:r.key,midi,start:performance.now(),end:performance.now()+250,id:'score:'+index});if(previewEnabled)audio().noteOn('score:'+(direct?r.midi:r.key),midi,r.velocity,controller.timbre);}else localAudio?.noteOff('score:'+(direct?r.midi:r.key));step();},r.deltaMs);}step();}
 function stopPreviewScore(){playbackToken++;clearTimeout(playbackTimer);previewPlaying=false;for(const el of keyboard.children)el.classList.remove('guided');if(localAudio)for(let i=0;i<128;i++)localAudio.noteOff('score:'+i);}
 async function saveJSON(doc,name){const text=JSON.stringify(doc,null,2);if(nativeAPI()){const r=await nativeAPI().save_json(text,name);if(r.cancelled)return;nativeResult(r);message('文件已保存。');}else{const link=document.createElement('a');link.href=URL.createObjectURL(new Blob([text],{type:'application/json'}));link.download=name;link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1500);}}
 bind('saveScore',()=>{const s=scores[selectedScore];if(s.builtin)throw new Error('内置曲谱无本地事件文件，可先选择“小星星”或“霓虹漫游”导出。');return saveJSON(s,'TangNeon-Score.json');});
 function acceptScore(text){if(realtimePlayback.busy)throw Error('请先停止蓝牙实时播放');if(dataBusy)throw new Error('请等待当前数据操作完成再导入曲谱');if(text.length>16*1024*1024)throw new Error('曲谱文件过大');const doc=JSON.parse(text),score=doc.transport==='realtime'?RealtimeScore.validate(doc,controller.mapping):P.validateScore(doc,controller.scoreCapacity);scores.imported=score;selectScore('imported');message('已导入 '+score.title+(score.transport==='realtime'?'，点击蓝牙实时播放。':'，可上传或蓝牙实时播放。'));}
 bind('importScore',async()=>{const generation=++fileLoadGeneration;if(nativeAPI()){const r=await nativeAPI().load_json();if(r.cancelled)return;nativeResult(r);if(generation===fileLoadGeneration)acceptScore(r.text);}else{$('fileInput').value='';$('fileInput').click();}});
 $('fileInput').addEventListener('change',()=>run(async()=>{const file=$('fileInput').files[0];if(!file)return;const generation=++fileLoadGeneration;if(file.size>16*1024*1024)throw new Error('曲谱文件大于 16 MiB');const text=await file.text();if(generation===fileLoadGeneration)acceptScore(text);}));
 bind('recordStart',()=>dataOperation(async()=>{await controller.transportAction(2);clearRecordCache();await controller.readStatus();$('recordInfo').textContent='正在记录 FPGA 接收的音符事件';message('开始事件录音。');}));
 bind('recordStop',()=>dataOperation(async()=>{await controller.transportAction(3);await controller.readStatus();$('recordInfo').textContent='录制已停止，点击回读读取完整事件。';}));
 bind('readRecording',()=>dataOperation(async()=>{const rows=await controller.readRecording(({completed,total})=>$('recordInfo').textContent='正在回读 '+completed+' / '+total);recordCache=rows;renderRecording(rows);$('recordInfo').textContent='已回读 '+rows.length+' 条事件，可导出 JSON。';message('演奏事件回读完成。');}));
 function renderRecording(rows){$('recordRows').innerHTML=rows.length?rows.map(r=>'<tr><td>'+String(r.index+1).padStart(3,'0')+'</td><td>'+r.deltaMs+' ms</td><td>'+esc(noteName(r.midi))+'</td><td>'+r.velocity+'</td><td>'+(r.source===63?'电脑 / 63':r.source>=25&&r.source<=49?'琴键 '+(r.source-24):'来源 '+r.source)+'</td><td>'+(r.on?'● 按下':'○ 松开')+'</td></tr>').join(''):'<tr><td colspan="6" class="empty-table">尚无音符事件。</td></tr>';}
 bind('exportRecording',()=>{if(!recordCache.length)throw new Error('先回读 FPGA 事件，再导出文件。');return saveJSON({version:1,type:'tang-synth-event-recording',title:'NEON STUDIO 演奏记录',rows:recordCache},'TangNeon-Recording.json');});
 bind('replayRecording',async()=>{if(recordCache.some(r=>r.source<25||r.source>49))throw new Error('当前 FPGA 仅回放实体琴键来源的录音；电脑演奏可导出 JSON 保存。');await controller.transportAction(8);await controller.readStatus();});
 bind('clearRecording',()=>dataOperation(async()=>{await controller.transportAction(4);recordCache=[];controller.recorded=[];renderRecording([]);await controller.readStatus();$('recordInfo').textContent='FPGA 事件记录已清空。';}));
 for(let i=0;i<25;i++){const box=document.createElement('div');box.className='map-item';box.innerHTML='<label for="map-'+i+'">KEY '+String(i+1).padStart(2,'0')+' / '+noteName(60+i)+'</label><input id="map-'+i+'" type="number" min="0" max="127" value="'+(60+i)+'" aria-label="第 '+(i+1)+' 键 MIDI 音高">';const input=box.querySelector('input');input.addEventListener('change',()=>run(async()=>{const midi=Number(input.value),old=controller.mapping[i];try{if(!Number.isInteger(midi)||midi<0||midi>127)throw new Error('MIDI 音高范围为 0–127');releaseAll();if(controller.ready)await controller.setMapping(i,midi);else controller.mapping[i]=midi;keyboard.children[i].querySelector('.key-note').textContent=noteName(midi);message('第 '+(i+1)+' 键 → '+noteName(midi));}catch(e){input.value=old;throw e;}}));$('mappingGrid').append(box);}
 bind('resetMapping',async()=>{releaseAll();for(let i=0;i<25;i++){if(controller.ready)await controller.setMapping(i,60+i);else controller.mapping[i]=60+i;$('map-'+i).value=60+i;keyboard.children[i].querySelector('.key-note').textContent=noteName(60+i);}message('已恢复 25 键 C4–C6。');});
 bind('exportLog',()=>saveJSON({app:'TANG NEON STUDIO',version:APP_VERSION,mode:controller.mode,hardwareHandshake:controller.ready&&controller.mode!=='demo',telemetry:controller.telemetry,boardMode:controller.boardMode,requestTimings:controller.timings,bridgeDiagnostics:lastBridgeDiagnostics,sessionLog:logs},'TangNeon-Session.json'));
 bind('micButton',async()=>{if(visualMic){for(const track of visualMic.stream.getTracks())track.stop();visualMic.source.disconnect();visualMic=null;$('visualSource').textContent='事件动画';$('stageCaption').textContent='演奏响应动画 · 非 FPGA 音频采样';$('micButton').innerHTML='<svg><use href="#i-mic"/></svg>音频输入';return;}if(!navigator.mediaDevices?.getUserMedia)throw new Error('当前环境不支持电脑音频输入。');const stream=await navigator.mediaDevices.getUserMedia({audio:{echoCancellation:false,noiseSuppression:false,autoGainControl:false}});const ctx=audio().ctx,source=ctx.createMediaStreamSource(stream),analyser=ctx.createAnalyser();analyser.fftSize=2048;source.connect(analyser);visualMic={stream,source,analyser,buffer:new Uint8Array(analyser.frequencyBinCount)};$('visualSource').textContent='电脑麦克风';$('stageCaption').textContent='电脑音频输入频谱 · 非数字 PCM 回传';$('micButton').innerHTML='<svg><use href="#i-mic"/></svg>关闭输入';message('正在显示电脑麦克风频谱；音频仅在本机分析。');});
 const canvas=$('visualizer'),ctx=canvas.getContext('2d');let W=0,H=0;const reducedMotion=matchMedia('(prefers-reduced-motion: reduce)').matches;
 function resize(){const rect=canvas.getBoundingClientRect(),dpr=Math.min(devicePixelRatio||1,2);W=rect.width;H=rect.height;if(!W)return;canvas.width=W*dpr;canvas.height=H*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);}new ResizeObserver(resize).observe(canvas);
 function draw(now){requestAnimationFrame(draw);if(!W||document.hidden||!$('page-studio').classList.contains('active'))return;ctx.clearRect(0,0,W,H);const t=reducedMotion?0:now/1000,live=activeKeys.size+(previewPlaying?1:0);
  ctx.strokeStyle='#8670a110';ctx.lineWidth=.6;for(let x=0;x<W;x+=W/24){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,H);ctx.stroke();}for(let y=18;y<H;y+=35){ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(W,y);ctx.stroke();}
  const glow=ctx.createRadialGradient(W*.47,H*.75,0,W*.47,H*.75,W*.48);glow.addColorStop(0,live?'#8e43c52a':'#63348814');glow.addColorStop(1,'#42225900');ctx.fillStyle=glow;ctx.fillRect(0,0,W,H);
  if(visualMic){visualMic.analyser.getByteFrequencyData(visualMic.buffer);const count=84,gap=3,bw=(W-60)/count;for(let i=0;i<count;i++){const v=visualMic.buffer[Math.floor(i**1.5*1.15)]||0;const bar=v/255*(H-70),g=ctx.createLinearGradient(0,H-30-bar,0,H-30);g.addColorStop(0,'#a9ead6');g.addColorStop(.4,'#bf8de3');g.addColorStop(1,'#6b3a9555');ctx.fillStyle=g;ctx.fillRect(30+i*bw,H-30-bar,bw-gap,Math.max(1,bar));}}
  else{
   for(let line=0;line<9;line++){ctx.beginPath();for(let x=0;x<=W;x+=3){const rel=x/W,envelope=Math.sin(rel*Math.PI)**2,amp=(7+live*2.7)*envelope;const y=H*.62+Math.sin(rel*10-t*.65+line*.23)*amp+Math.cos(rel*18+t*.3+line*.5)*amp*.22+line*3.2;(x?ctx.lineTo:ctx.moveTo).call(ctx,x,y);}ctx.strokeStyle='rgba('+(line%2?'125,214,196':'190,138,231')+','+(line===4?.55:.12)+')';ctx.lineWidth=line===4?1.4:.7;ctx.stroke();}
   for(let i=0;i<42;i++){const x=(i*139.7%W),y=(i*51.3%H);ctx.fillStyle='rgba(178,142,215,'+(.09+.11*Math.sin(t*.6+i)**2)+')';ctx.fillRect(x,y,1,1);}
   noteTrails=noteTrails.filter(n=>n.end===null||now-n.end<1800);for(const n of noteTrails){const x=(n.index+.5)/25*W,age=now-n.start,tail=n.end===null?0:now-n.end;const y=H-24-Math.min(H-35,age*.065),height=Math.max(6,Math.min(65,((n.end||now)-n.start)*.065)),alpha=Math.max(0,1-tail/1800);ctx.shadowBlur=13;ctx.shadowColor='#a97bea';const g=ctx.createLinearGradient(x,y, x,y+height);g.addColorStop(0,'rgba(202,168,249,'+alpha*.7+')');g.addColorStop(1,'rgba(139,93,198,'+alpha*.15+')');ctx.fillStyle=g;ctx.beginPath();ctx.roundRect(x-5,y,10,height,3);ctx.fill();ctx.shadowBlur=0;}
  }
  if(lastNote&&now-lastNote.time>2500&&!activeKeys.size&&!previewPlaying){$('activeNote').textContent='—';$('activeMidi').textContent='READY TO CREATE';lastNote=null;}
 }
 new ScoreLibraryPanel({root:$('page-scores'),getAPI:nativeAPI,getMapping:()=>controller.mapping,getCapacity:()=>controller.scoreCapacity,
  setCapacity:value=>{if(dataBusy)throw new Error('请等待当前数据操作结束再切换程序容量');if(![256,1024].includes(value))throw new Error('无效容量');controller.scoreCapacity=value;message('已选择'+value+'条事件容量，请与板上程序匹配');},
  message,accept:doc=>acceptScore(JSON.stringify(doc))});
 requestAnimationFrame(draw);renderScores();selectScore('builtin');log('NEON STUDIO '+APP_VERSION+' · 直接音高曲谱版 · 完整主工程 V1 协议');
 window.addEventListener('pywebviewready',()=>{log('Windows 原生蓝牙 / 串口通道已就绪');});
 window.addEventListener('beforeunload',()=>{releaseAll();for(const track of visualMic?.stream.getTracks()||[])track.stop();});
})();
