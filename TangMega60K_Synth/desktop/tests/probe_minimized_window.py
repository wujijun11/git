"""真实WebView2窗口最小化专项。只连接内存假GATT，不访问任何真实设备。

--javascript-baseline禁用原生租用，复现1.5.0的界面计时链。
测试只最小化/还原自己创建的专用窗口，不操作用户其他窗口。
"""
import argparse
import asyncio
import json
from pathlib import Path
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_host import NativeHost, LocalAssets, _Context, install_webview_guards, _asset_root, _icon_path
from realtime_native.protocol import encode


class ProbeHost(NativeHost):
    def __init__(self):
        super().__init__()
        self.frames = []
        self.report = None
        self.completed = threading.Event()
        self.ui_callbacks = 0

    def record_result(self, result):
        self.report = result
        self.completed.set()
        return {"ok": True}

    def _queue_callback(self, name, args, generation):
        if name == "nativeReceive":
            self.ui_callbacks += 1
        super()._queue_callback(name, args, generation)

    async def install_fake(self):
        owner = self
        class FakeGatt:
            is_connected = True
            async def write_gatt_char(self, characteristic, frame, **options):
                owner.frames.append((time.monotonic(), list(frame)))
                await asyncio.sleep(.002)
                unsupported = frame[4] == 8 and frame[5] == 2
                owner._receive(encode(frame[3], 128, [frame[4], 1 if unsupported else 0]), context)
                if frame[4] == 8 and not unsupported:
                    owner._receive(encode(frame[3], 129), context)
            async def disconnect(self):
                self.is_connected = False
        context = _Context("ble", 1)
        context.connected = True
        context.client, context.rx = FakeGatt(), "memory-only"
        self._generation, self._context = 1, context


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--duration", type=int, default=70)
    parser.add_argument("--javascript-baseline", action="store_true")
    args = parser.parse_args()
    import webview
    host = ProbeHost()
    host._call(host.install_fake(), 3)
    assets = LocalAssets(_asset_root())
    window = webview.create_window("Tang 1.5.1 最小化回归（内存模拟，无蓝牙）", assets.url,
                                  js_api=host, width=1100, height=750)
    host._window = window
    minimized = threading.Event()
    window.events.minimized += minimized.set
    window.events.loaded += host._window_ready.set
    window.events.closed += host._close
    window.events.initialized += lambda renderer: install_webview_guards(assets)
    outcome = {}

    def exercise():
        try:
            if not host._window_ready.wait(15):
                raise RuntimeError("测试窗口未加载")
            # 真实UI协调层、Controller和原生API；仅传输的另一端替换为内存FPGA。
            native_methods = "" if args.javascript_baseline else """
                playRealtime: (rows,timbre,seq,token) => api.play_realtime(rows,timbre,seq,token,1),
                stopRealtime: token => api.stop_realtime(token,1),
                realtimeStatus: token => api.realtime_status(token,1),
            """
            script = """(async()=>{
              try {
                const api=pywebview.api; let receive=()=>{};
                window.nativeReceive=(hex,g)=>{if(g===1)receive(Uint8Array.from(hex.match(/../g),x=>parseInt(x,16)));};
                const transport={
                  NATIVE_METHODS
                  write: async data=>{const r=await api.write_frame(Array.from(data,x=>x.toString(16).padStart(2,'0')).join(''),1);if(!r.ok)throw Error(r.error);},
                  close:()=>api.disconnect(1),onBytes:fn=>{receive=fn;return()=>{};},onDisconnect:()=>()=>{}
                };
                const c=neonApp.controller;
                await c.connect(transport,'ble');
                const rows=[];
                for(let i=0;i<EVENT_PAIRS;i++)rows.push({midi:60+i%25,on:1,velocity:90,deltaMs:i?25:0},{midi:60+i%25,on:0,velocity:0,deltaMs:25});
                const playback=new DesktopRealtimePlayback({controller:c,getConnection:()=>1,
                  getScore:()=>({version:2,playback:'direct',rows}),assertIdle:()=>{},
                  statusNode:document.getElementById('realtimeStatus'),message:()=>{}});
                window.probePlayback=playback;
                const result=await playback.start();
                await c.readStatus();
                await api.record_result({ok:true,result,ready:c.ready,status:document.getElementById('realtimeStatus').textContent});
              }catch(e){await pywebview.api.record_result({ok:false,error:String(e),status:document.getElementById('realtimeStatus').textContent});}
            })();""".replace("NATIVE_METHODS", native_methods).replace("EVENT_PAIRS", str(args.duration * 20))
            window.run_js(script)
            # 准备阶段握手尚未完成时不开始最小化计时。
            started = time.monotonic()
            while not any(frame[4] == 1 for _, frame in host.frames):
                if host.completed.is_set() or time.monotonic() - started > 12:
                    raise RuntimeError("播放未开始：" + str(host.report))
                time.sleep(.05)
            time.sleep(1)
            window.minimize()
            if not minimized.wait(5):
                raise RuntimeError("未收到真实窗口最小化事件")
            min_start, callbacks_before = time.monotonic(), host.ui_callbacks
            time.sleep(args.duration + 1)
            min_end, callbacks_after = time.monotonic(), host.ui_callbacks
            window.restore()
            if not host.completed.wait(15):
                raise RuntimeError("恢复后未收到播放完成结果")
            # report_result通知早于WebView完成RPC返回；让返回脚本收尾再销毁本测试窗口。
            time.sleep(.25)
            notes = [(at, f) for at, f in host.frames if f[4] == 1]
            expected = []
            for i in range(args.duration * 20):
                expected.extend([[63, 60 + i % 25, 90, 2, 1], [63, 60 + i % 25, 0, 2, 0]])
            actual = [f[5:10] for _, f in notes]
            outcome.update(ok=bool(host.report.get("ok")) and actual == expected,
                javascriptBaseline=args.javascript_baseline, actualWindowMinimized=True,
                minimizedSeconds=min_end-min_start, expectedNoteEvents=len(expected), actualNoteEvents=len(notes),
                exactNoteOrder=actual == expected, noteEventsWhileMinimized=sum(min_start <= at <= min_end for at, _ in notes),
                uiReceiveCallbacksWhileMinimized=callbacks_after-callbacks_before,
                maxNoteGapMs=max(((notes[i][0]-notes[i-1][0])*1000 for i in range(1,len(notes))), default=0),
                frontendResult=host.report, actualBluetoothTested=False, dacTested=False)
        except Exception as error:
            outcome.update(ok=False,error=str(error), actualBluetoothTested=False)
        finally:
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(outcome, ensure_ascii=False, indent=2), encoding="utf-8")
            window.destroy()
    try:
        webview.start(exercise, gui="edgechromium", private_mode=True, icon=str(_icon_path()))
    finally:
        host._close()
        assets._close()
    print(json.dumps(outcome, ensure_ascii=False, indent=2))
    return 0 if outcome.get("ok") or (args.javascript_baseline and outcome.get("actualWindowMinimized")) else 1


if __name__ == "__main__":
    raise SystemExit(main())
