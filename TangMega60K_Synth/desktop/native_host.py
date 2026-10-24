"""Local Windows shell and byte transport for Tang Neon Studio.

The frontend owns the existing FPGA protocol/session. This module never creates
NOTE, configuration, handshake, retry, or panic commands of its own.
"""
from __future__ import annotations

import argparse
import asyncio
import concurrent.futures
import contextlib
import ctypes
import importlib.metadata
import json
import logging
import mimetypes
import os
from pathlib import Path
import queue
import re
import secrets
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

SERVICE_UUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
RX_UUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
TX_UUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
DIAG_UUID = "6e400004-b5a3-f393-e0a9-e50e24dcca9e"
MAX_JSON_BYTES = 4 * 1024 * 1024
BLE_WRITE_TIMEOUT = 3.0
DIAG_READ_TIMEOUT = 0.75
DIAG_ERROR_COUNTERS = ("bleWriteErrors", "uartErrors", "notifyErrors", "resyncCount")
DIAG_TRAFFIC_COUNTERS = ("bleReceivedFrames", "uartSentFrames", "uartReceivedBytes", "uartValidFrames", "notifyAcceptedFrames")
LOG = logging.getLogger("tang.native")


def _error_text(exc: BaseException) -> str:
    if isinstance(exc, (TimeoutError, asyncio.TimeoutError)):
        return "设备操作超时，请重新连接"
    if isinstance(exc, (asyncio.CancelledError, concurrent.futures.CancelledError)):
        return "操作已取消或应用正在关闭"
    return str(exc) or type(exc).__name__


def crc8(data: bytes) -> int:
    result = 0
    for value in data:
        result ^= value
        for _ in range(8):
            result = ((result << 1) ^ (7 if result & 128 else 0)) & 255
    return result


def validate_frame(value: str) -> bytes:
    if not isinstance(value, str) or re.fullmatch(r"[0-9a-fA-F]{32}", value) is None:
        raise ValueError("帧必须是32个十六进制字符（16字节）")
    frame = bytes.fromhex(value)
    if frame[:3] != b"\xa5\x5a\x01" or frame[15] != crc8(frame[2:15]):
        raise ValueError("帧头、版本或CRC8校验失败")
    return frame


def _generation(value) -> int:
    if type(value) is not int or value < 1:
        raise ValueError("无效的连接代际")
    return value


def _json_text(text) -> str:
    if not isinstance(text, str) or len(text.encode("utf-8")) > MAX_JSON_BYTES:
        raise ValueError("JSON文件必须小于4MiB")
    json.loads(text)
    return text


def _suggested_name(value) -> str:
    name = str(value or "tang-score.json").replace("\\", "/").split("/")[-1]
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .")[:100]
    if not name:
        name = "tang-score.json"
    if not name.lower().endswith(".json"):
        name += ".json"
    if name.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *[f"COM{x}" for x in range(1, 10)], *[f"LPT{x}" for x in range(1, 10)]}:
        name = "tang-" + name
    return name


def _decode_bridge_diagnostics(raw: bytes) -> dict:
    raw = bytes(raw)
    result = {"available": False, "format": "unknown", "length": len(raw), "rawHex": raw.hex()}
    if len(raw) == 16:
        result.update(available=True, format="legacy16")
    elif len(raw) == 40 and raw[16:19] == b"TB\x01":
        result.update(available=True, format="TBv1", flags=raw[19], uartInitialized=bool(raw[19] & 1))
    else:
        result["reason"] = "unsupported_format"
        return result
    counters = {name: int.from_bytes(raw[index * 4:index * 4 + 4], "little") for index, name in enumerate(DIAG_ERROR_COUNTERS)}
    if result["format"] == "TBv1":
        counters.update({name: int.from_bytes(raw[20 + index * 4:24 + index * 4], "little") for index, name in enumerate(DIAG_TRAFFIC_COUNTERS)})
    result["counters"] = counters
    return result


def _bridge_diagnostic_report(context, after: dict) -> dict:
    before = context.diagnostic_baseline
    result = {"generation": context.generation, "baseline": before, "after": after, "delta": None}
    if not after.get("available"):
        result["deltaReason"] = "after_unavailable"
    elif not before.get("available"):
        result["deltaReason"] = "baseline_unavailable"
    elif before["format"] != after["format"]:
        result["deltaReason"] = "format_changed"
    else:
        result["delta"] = {name: (value - before["counters"][name]) & 0xFFFFFFFF for name, value in after["counters"].items()}
        result["deltaReason"] = "connection_baseline"
    return result


class _Context:
    def __init__(self, kind: str, generation: int):
        self.kind, self.generation = kind, generation
        self.client = self.serial = self.reader = None
        self.rx = None
        self.connected = False
        self.diagnostic_characteristic = None
        self.diagnostic_baseline = {"available": False, "reason": "not_sampled"}
        self.diagnostic_report = None


class NativeHost:
    """Only the seven public methods below are exposed to the local page."""

    def __init__(self):
        self._window = None
        self._api_lock = threading.RLock()
        self._scan_lock = threading.Lock()
        self._file_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._generation = 0
        self._closed = False
        self._context = None
        self._devices = {}
        self._last_diagnostics = None
        self._futures = set()
        self._callbacks = queue.Queue(maxsize=512)
        self._window_ready = threading.Event()
        self._started = threading.Event()
        self._loop = asyncio.new_event_loop()
        self._worker = threading.Thread(target=self._loop_worker, name="Tang BLE / serial", daemon=True)
        self._worker.start()
        if not self._started.wait(5):
            raise RuntimeError("后台传输线程未启动")
        self._callback_worker = threading.Thread(target=self._callback_loop, name="Tang UI callbacks", daemon=True)
        self._callback_worker.start()

    def _loop_worker(self):
        initialized = False
        if sys.platform == "win32":
            # Bleak/WinRT run in this MTA thread, separate from WebView's STA UI.
            initialized = ctypes.windll.ole32.CoInitializeEx(None, 0) in (0, 1)
        asyncio.set_event_loop(self._loop)
        self._transport_lock = asyncio.Lock()
        self._started.set()
        try:
            self._loop.run_forever()
        finally:
            pending = asyncio.all_tasks(self._loop)
            for task in pending:
                task.cancel()
            if pending:
                self._loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            self._loop.run_until_complete(self._loop.shutdown_asyncgens())
            self._loop.close()
            if initialized:
                ctypes.windll.ole32.CoUninitialize()

    def _live(self, generation: int) -> bool:
        with self._state_lock:
            return not self._closed and self._generation == generation

    def _call(self, coroutine, timeout: float):
        with self._state_lock:
            if self._closed:
                coroutine.close()
                raise RuntimeError("应用已关闭")
            future = asyncio.run_coroutine_threadsafe(coroutine, self._loop)
            self._futures.add(future)
        try:
            return future.result(timeout)
        except concurrent.futures.TimeoutError:
            future.cancel()
            raise TimeoutError("传输操作超时，请重新连接") from None
        finally:
            with self._state_lock:
                self._futures.discard(future)

    def _queue_callback(self, name: str, args: list, generation: int):
        if not self._live(generation):
            return
        try:
            self._callbacks.put_nowait((name, args, generation))
        except queue.Full:
            LOG.error("UI callback queue exhausted")
            with contextlib.suppress(RuntimeError):
                asyncio.run_coroutine_threadsafe(self._fail_current(generation, "界面接收队列已满，连接已关闭"), self._loop)

    def _state(self, state: str, message: str, generation: int):
        self._queue_callback("nativeTransportState", [state, message, generation], generation)

    def _receive(self, data: bytes, context: _Context):
        if context is self._context and context.connected and data and self._live(context.generation):
            self._queue_callback("nativeReceive", [bytes(data).hex(), context.generation], context.generation)

    def _callback_loop(self):
        while True:
            item = self._callbacks.get()
            if item is None:
                return
            name, args, generation = item
            if not self._window_ready.wait(2) or not self._live(generation):
                continue
            window = self._window
            if window is None:
                continue
            script = f"void(window.{name} && window.{name}(...{json.dumps(args, ensure_ascii=True)}));"
            try:
                # Run outside both API and asyncio locks. JS receives the same
                # generation so it can reject a callback queued before reconnect.
                window.run_js(script)
            except Exception:
                LOG.debug("UI callback unavailable", exc_info=True)

    def scan_ble(self):
        try:
            with self._scan_lock:
                return self._call(self._scan_ble(), 10)
        except Exception as exc:
            return {"ok": False, "devices": [], "error": _error_text(exc)}

    async def _scan_ble(self):
        from bleak import BleakScanner
        discovered = await asyncio.wait_for(BleakScanner.discover(timeout=6.0, return_adv=True, service_uuids=[SERVICE_UUID]), 8.0)
        self._devices = {device.address: device for device, _ in discovered.values()}
        devices = [{"id": device.address, "name": adv.local_name or device.name or "Tang Synth", "rssi": adv.rssi}
                   for device, adv in discovered.values()]
        devices.sort(key=lambda item: item["rssi"], reverse=True)
        return {"ok": True, "devices": devices}

    def list_serial(self):
        try:
            from serial.tools import list_ports
            ports = [{"id": port.device, "name": port.description or port.device} for port in list_ports.comports()]
            return {"ok": True, "ports": ports}
        except Exception as exc:
            return {"ok": False, "ports": [], "error": _error_text(exc)}

    def connect(self, kind, id):
        if kind not in ("ble", "serial") or not isinstance(id, str) or not 1 <= len(id) <= 200:
            return {"ok": False, "error": "无效的连接类型或设备标识"}
        try:
            with self._api_lock:
                with self._state_lock:
                    if self._closed:
                        raise RuntimeError("应用已关闭")
                    self._generation += 1
                    generation = self._generation
                self._state("connecting", "正在建立本地设备连接", generation)
                try:
                    self._call(self._connect(kind, id, generation), 23)
                except Exception as exc:
                    self._state("error", _error_text(exc), generation)
                    return {"ok": False, "generation": generation, "error": _error_text(exc)}
                return {"ok": True, "generation": generation}
        except Exception as exc:
            return {"ok": False, "error": _error_text(exc)}

    async def _connect(self, kind: str, identifier: str, generation: int):
        async with self._transport_lock:
            await self._teardown(self._context)
            if not self._live(generation):
                raise RuntimeError("连接请求已过期")
            context = _Context(kind, generation)
            self._context = context
            try:
                if kind == "ble":
                    from bleak import BleakClient
                    def disconnected(_):
                        if self._live(generation):
                            with contextlib.suppress(RuntimeError):
                                asyncio.run_coroutine_threadsafe(self._fail_current(generation, "蓝牙连接已断开", "disconnected"), self._loop)
                    # WinRT filtered service discovery fails with 0x80070016 on
                    # some adapters. Discover normally, then validate and use
                    # only the required NUS service and its characteristics.
                    context.client = BleakClient(self._devices.get(identifier, identifier), disconnected_callback=disconnected,
                                                 timeout=12.0)
                    await asyncio.wait_for(context.client.connect(), 15.0)
                    service = context.client.services.get_service(SERVICE_UUID)
                    context.rx = service.get_characteristic(RX_UUID) if service else None
                    tx = service.get_characteristic(TX_UUID) if service else None
                    if service is None or context.rx is None or tx is None:
                        raise RuntimeError("蓝牙设备缺少 Tang Synth NUS 服务或特征")
                    if "write" not in context.rx.properties or "notify" not in tx.properties:
                        raise RuntimeError("蓝牙特征不支持带响应写入或通知")
                    def notify(_, data):
                        self._receive(bytes(data), context)
                    await asyncio.wait_for(context.client.start_notify(tx, notify), 5.0)
                    # Optional diagnostics never gate compatibility with old
                    # bridges and are sampled before the first protocol write.
                    try:
                        diagnostic = service.get_characteristic(DIAG_UUID)
                        if diagnostic is not None and "read" in diagnostic.properties:
                            context.diagnostic_characteristic = diagnostic
                    except Exception:
                        pass
                    context.diagnostic_baseline = await self._read_bridge_diagnostics(context)
                else:
                    if re.fullmatch(r"COM[1-9][0-9]{0,3}", identifier.upper()) is None:
                        raise ValueError("请选择有效的Windows COM端口")
                    import serial
                    port = serial.Serial(port=None, baudrate=115200, bytesize=8, parity="N", stopbits=1,
                                         timeout=0.1, write_timeout=1.0, xonxoff=False, rtscts=False, dsrdtr=False)
                    context.serial = port
                    port.dtr = False
                    port.rts = False
                    port.port = identifier.upper()
                    def open_port():
                        port.open()
                        # to_thread cannot cancel an OS open in progress. If a
                        # timed-out open finishes late, close its own handle.
                        if context is not self._context or not self._live(generation):
                            port.close()
                            raise RuntimeError("串口连接请求已过期")
                    await asyncio.wait_for(asyncio.to_thread(open_port), 3.0)
                    await asyncio.to_thread(port.reset_input_buffer)
                if not self._live(generation):
                    raise RuntimeError("连接请求已过期")
                context.connected = True
                if context.serial is not None:
                    context.reader = asyncio.create_task(self._serial_reader(context))
                self._state("connected", "设备传输已连接", generation)
            except BaseException:
                await self._teardown(context)
                raise

    async def _serial_reader(self, context: _Context):
        try:
            while context is self._context and context.connected and self._live(context.generation):
                data = await asyncio.to_thread(context.serial.read, max(1, min(context.serial.in_waiting, 256)))
                if data:
                    self._receive(data, context)
        except asyncio.CancelledError:
            return
        except Exception as exc:
            await self._fail_current(context.generation, f"串口连接已断开：{exc}", "disconnected")

    def write_frame(self, hex, generation):
        try:
            frame, generation = validate_frame(hex), _generation(generation)
            with self._api_lock:
                self._call(self._write(frame, generation), BLE_WRITE_TIMEOUT + 3.0)
            return {"ok": True}
        except Exception as exc:
            return {"ok": False, "error": _error_text(exc)}

    async def _write(self, frame: bytes, generation: int):
        async with self._transport_lock:
            context = self._context
            if not self._live(generation) or context is None or context.generation != generation or not context.connected:
                raise RuntimeError("连接已关闭或连接代际已过期")
            try:
                if context.client is not None:
                    await asyncio.wait_for(context.client.write_gatt_char(context.rx, frame, response=True), BLE_WRITE_TIMEOUT)
                else:
                    count = await asyncio.wait_for(asyncio.to_thread(context.serial.write, frame), 2.0)
                    if count != len(frame):
                        raise IOError("串口未完整写入16字节")
            except BaseException as exc:
                await self._teardown(context)
                self._state("error", f"设备写入失败，连接已关闭：{str(exc) or type(exc).__name__}", generation)
                raise

    async def _read_bridge_diagnostics(self, context):
        if context.kind != "ble" or context.diagnostic_characteristic is None:
            return {"available": False, "reason": "missing_characteristic"}
        if context is not self._context or not self._live(context.generation):
            return {"available": False, "reason": "stale_generation"}
        if context.client is None or not context.client.is_connected:
            return {"available": False, "reason": "link_closed"}
        task = None
        try:
            task = asyncio.ensure_future(context.client.read_gatt_char(context.diagnostic_characteristic))
            done, _ = await asyncio.wait({task}, timeout=DIAG_READ_TIMEOUT)
            if task not in done:
                return {"available": False, "reason": "read_timeout"}
            raw = bytes(task.result())
            if context is not self._context or not self._live(context.generation):
                return {"available": False, "reason": "stale_generation"}
            return _decode_bridge_diagnostics(raw)
        except Exception as exc:
            return {"available": False, "reason": "read_failed", "error": _error_text(exc)}
        finally:
            if task is not None and not task.done():
                task.cancel()
                task.add_done_callback(lambda completed: None if completed.cancelled() else completed.exception())

    def disconnect(self, generation):
        try:
            generation = _generation(generation)
            with self._api_lock:
                diagnostics = self._call(self._disconnect(generation), 6.0)
            result = {"ok": True}
            if diagnostics is not None:
                result["diagnostics"] = diagnostics
            return result
        except Exception as exc:
            return {"ok": False, "error": _error_text(exc)}

    async def _disconnect(self, generation: int):
        async with self._transport_lock:
            if not self._live(generation):
                raise RuntimeError("连接代际已过期")
            context = self._context
            diagnostics = self._last_diagnostics if self._last_diagnostics and self._last_diagnostics["generation"] == generation else None
            try:
                if context is not None and context.kind == "ble":
                    after = await self._read_bridge_diagnostics(context)
                    if self._live(generation) and context is self._context:
                        diagnostics = context.diagnostic_report = _bridge_diagnostic_report(context, after)
            finally:
                await self._teardown(context)
                self._state("disconnected", "已断开连接", generation)
            return diagnostics

    async def _fail_current(self, generation: int, message: str, state="error"):
        async with self._transport_lock:
            if not self._live(generation) or self._context is None or self._context.generation != generation:
                return
            await self._teardown(self._context)
            self._state(state, message, generation)

    async def _teardown(self, context):
        if context is None:
            return
        if context.kind == "ble" and self._live(context.generation):
            self._last_diagnostics = context.diagnostic_report or _bridge_diagnostic_report(context, {"available": False, "reason": "link_closed"})
        if self._context is context:
            self._context = None
        context.connected = False
        if context.reader is not None and context.reader is not asyncio.current_task():
            context.reader.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await context.reader
        if context.client is not None:
            with contextlib.suppress(Exception):
                if context.client.is_connected:
                    await asyncio.wait_for(context.client.disconnect(), 3.0)
        if context.serial is not None:
            with contextlib.suppress(Exception):
                await asyncio.wait_for(asyncio.to_thread(context.serial.close), 1.0)

    def load_json(self):
        try:
            import webview
            with self._file_lock:
                selected = self._window.create_file_dialog(webview.FileDialog.OPEN, allow_multiple=False,
                                                          file_types=("JSON 曲谱 (*.json)",))
                if not selected:
                    return {"ok": True, "cancelled": True}
                path = Path(selected[0])
                with path.open("rb") as stream:
                    data = stream.read(MAX_JSON_BYTES + 1)
                if len(data) > MAX_JSON_BYTES:
                    raise ValueError("JSON文件必须小于4MiB")
                text = _json_text(data.decode("utf-8-sig"))
                return {"ok": True, "text": text, "name": path.name}
        except Exception as exc:
            return {"ok": False, "error": _error_text(exc)}

    def save_json(self, text, suggestedName):
        temporary = None
        try:
            text = _json_text(text)
            name = _suggested_name(suggestedName)
            import webview
            with self._file_lock:
                selected = self._window.create_file_dialog(webview.FileDialog.SAVE, save_filename=name,
                                                          file_types=("JSON 曲谱 (*.json)",))
                if not selected:
                    return {"ok": True, "cancelled": True}
                path = Path(selected[0] if isinstance(selected, (list, tuple)) else selected)
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n", dir=path.parent,
                                                 prefix=".tang-", suffix=".tmp", delete=False) as stream:
                    temporary = Path(stream.name)
                    stream.write(text)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
                return {"ok": True}
        except Exception as exc:
            return {"ok": False, "error": _error_text(exc)}
        finally:
            if temporary is not None and temporary.exists():
                with contextlib.suppress(OSError):
                    temporary.unlink()

    def _close(self):
        with self._state_lock:
            if self._closed:
                return
            self._closed = True
            self._generation += 1
            futures = list(self._futures)
        for future in futures:
            future.cancel()
        async def release():
            async with self._transport_lock:
                await self._teardown(self._context)
        future = asyncio.run_coroutine_threadsafe(release(), self._loop)
        with contextlib.suppress(Exception):
            future.result(6.0)
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._worker.join(3)
        with contextlib.suppress(queue.Full):
            self._callbacks.put_nowait(None)


class LocalAssets:
    """Serve a single bundled directory; no remote requests or directory lists."""

    def __init__(self, root: Path):
        self.root = root.resolve()
        self.token = secrets.token_urlsafe(24)
        owner = self
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urlsplit(self.path)
                prefix = "/" + owner.token + "/"
                if not parsed.path.startswith(prefix):
                    self.send_error(404)
                    return
                path = (owner.root / unquote(parsed.path[len(prefix):])).resolve()
                if not path.is_relative_to(owner.root) or not path.is_file():
                    self.send_error(404)
                    return
                data = path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("Content-Security-Policy", "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'")
                self.end_headers()
                self.wfile.write(data)
            def log_message(self, *_):
                return
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}/{self.token}/index.html"
        self.thread = threading.Thread(target=self.server.serve_forever, name="Tang local assets", daemon=True)
        self.thread.start()

    def _allowed(self, uri: str, navigation=False) -> bool:
        if navigation and uri == "about:blank":
            return True
        parsed = urlsplit(uri)
        if parsed.scheme != "http" or parsed.netloc != f"127.0.0.1:{self.port}":
            return False
        prefix = "/" + self.token + "/"
        path = (self.root / unquote(parsed.path[len(prefix):])).resolve() if parsed.path.startswith(prefix) else None
        return path is not None and path.is_relative_to(self.root) and (not navigation or path == self.root / "index.html")

    def _close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)


def install_webview_guards(assets: LocalAssets):
    # This host pins pywebview6.2.1. Its public events do not provide cancellable
    # navigation, so install guards before its EdgeChrome control is created.
    from webview.platforms.edgechromium import EdgeChrome
    original_ready = EdgeChrome.on_webview_ready
    original_navigation = EdgeChrome.on_navigation_start
    original_resource = EdgeChrome.on_web_resource_request
    def navigation(self, sender, args):
        if not assets._allowed(str(args.Uri), navigation=True):
            args.Cancel = True
            return
        original_navigation(self, sender, args)
    def resource(self, sender, args):
        if not assets._allowed(str(args.Request.Uri)):
            args.Response = sender.Environment.CreateWebResourceResponse(None, 403, "Blocked", "Content-Type: text/plain")
            return
        original_resource(self, sender, args)
    def new_window(self, sender, args):
        args.Handled = True
    def ready(self, sender, args):
        if args.IsSuccess:
            def frame_navigation(_, event):
                event.Cancel = True
            sender.CoreWebView2.FrameNavigationStarting += frame_navigation
            self._tang_frame_guard = frame_navigation
        original_ready(self, sender, args)
    EdgeChrome.on_navigation_start = navigation
    EdgeChrome.on_web_resource_request = resource
    EdgeChrome.on_new_window_request = new_window
    EdgeChrome.on_webview_ready = ready


def _asset_root() -> Path:
    return Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent)) / "web"


def _icon_path() -> Path:
    return Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent)) / "assets" / "neon.ico"


def smoke_test() -> dict:
    checks = {}
    for name in ("webview", "webview.platforms.edgechromium", "bleak", "serial", "winrt.windows.devices.bluetooth", "winrt.windows.devices.bluetooth.genericattributeprofile", "winrt.windows.storage.streams"):
        try:
            __import__(name)
            checks[name] = "ok"
        except Exception as exc:
            checks[name] = str(exc)
    assets = _asset_root()
    checks["local_index"] = "ok" if (assets / "index.html").is_file() else "missing desktop/web/index.html"
    checks["window_icon"] = "ok" if _icon_path().is_file() else "missing desktop/assets/neon.ico"
    checks["frame_validation"] = "ok" if validate_frame("a55a01000000000000000000000000" + f"{crc8(bytes.fromhex('01000000000000000000000000')):02x}") else "failed"
    checks["webview2_runtime"] = "not checked"
    if sys.platform == "win32":
        import winreg
        found = False
        for hive in (winreg.HKEY_LOCAL_MACHINE, winreg.HKEY_CURRENT_USER):
            for prefix in (r"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients", r"SOFTWARE\Microsoft\EdgeUpdate\Clients"):
                try:
                    with winreg.OpenKey(hive, prefix) as key:
                        for index in range(winreg.QueryInfoKey(key)[0]):
                            with winreg.OpenKey(key, winreg.EnumKey(key, index)) as client:
                                with contextlib.suppress(OSError):
                                    name = winreg.QueryValueEx(client, "name")[0]
                                    version = winreg.QueryValueEx(client, "pv")[0]
                                    if "webview" in name.lower() and version != "0.0.0.0":
                                        found = True
                except OSError:
                    pass
        checks["webview2_runtime"] = "ok" if found else "请安装Microsoft Edge WebView2 Runtime"
    return {"ok": all(value == "ok" for value in checks.values()), "checks": checks,
            "versions": {name: importlib.metadata.version(name) for name in ("pywebview", "bleak", "pyserial")},
            "protocol": {"service": SERVICE_UUID, "rx": RX_UUID, "tx": TX_UUID, "baud": 115200},
            "hardware_connection_tested": False}


def main():
    parser = argparse.ArgumentParser(description="Tang Neon Studio Windows local device shell")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--smoke-test", action="store_true")
    parser.add_argument("--smoke-output")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.WARNING)
    if args.smoke_test:
        try:
            report = smoke_test()
        except Exception as exc:
            report = {"ok": False, "error": _error_text(exc), "error_type": type(exc).__name__, "hardware_connection_tested": False}
        text = json.dumps(report, ensure_ascii=False, indent=2)
        if sys.stdout is not None:
            print(text)
        output = Path(args.smoke_output) if args.smoke_output else Path(sys.executable if getattr(sys, "frozen", False) else __file__).parent / "smoke-test.json"
        output.write_text(text + "\n", encoding="utf-8")
        return 0 if report["ok"] else 1
    import webview
    assets = LocalAssets(_asset_root())
    host = NativeHost()
    webview.settings["ALLOW_DOWNLOADS"] = False
    webview.settings["OPEN_EXTERNAL_LINKS_IN_BROWSER"] = False
    webview.settings["OPEN_DEVTOOLS_IN_DEBUG"] = False
    window = webview.create_window("Tang Neon Studio · FPGA Synth", assets.url, js_api=host,
                                   width=1440, height=940, min_size=(1080, 700), background_color="#080b17")
    host._window = window
    def initialized(renderer):
        if renderer != "edgechromium":
            LOG.error("This application requires the WebView2 renderer")
            return False
        try:
            install_webview_guards(assets)
        except Exception:
            LOG.exception("Failed to install local-only navigation guards")
            return False
    window.events.initialized += initialized
    window.events.loaded += host._window_ready.set
    window.events.closed += host._close
    try:
        webview.start(gui="edgechromium", debug=args.debug, private_mode=True, icon=str(_icon_path()))
    finally:
        host._close()
        assets._close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
