"""Actual NativeHost with controlled BLE callbacks; no physical devices."""
import asyncio
import faulthandler
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import threading
import time
import types
import unittest
from unittest.mock import patch

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
spec = importlib.util.spec_from_file_location("review_native", ROOT / "desktop/native_host.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def frame(seq, op, payload=b""):
    body = bytes([1, seq, op]) + payload.ljust(10, b"\x00")
    return b"\xa5\x5a" + body + bytes([native.crc8(body)])


class Window:
    def __init__(self):
        self.received = []
        self.scripts = []
        self.arrived_before_write_completed = False

    def run_js(self, script):
        self.scripts.append(script)
        if "window.nativeReceive(..." in script:
            args = json.loads(script.split("window.nativeReceive(...", 1)[1].rsplit("));", 1)[0])
            self.received.append(args)
            if not Client.instances[-1].write_completed:
                self.arrived_before_write_completed = True


class Client:
    instances = []
    mode = "separate"

    def __init__(self, device, disconnected_callback, **kwargs):
        self.device = device
        self.disconnect_callback = disconnected_callback
        self.is_connected = False
        self.subscribed = False
        self.write_completed = False
        self.notify = None
        self.writes = []
        self.rx = types.SimpleNamespace(uuid=native.RX_UUID, properties=["write"])
        self.tx = types.SimpleNamespace(uuid=native.TX_UUID, properties=["notify"])
        service = types.SimpleNamespace(get_characteristic=lambda uuid: self.rx if uuid == native.RX_UUID else self.tx)
        self.services = types.SimpleNamespace(get_service=lambda uuid: service if uuid == native.SERVICE_UUID else None)
        self.instances.append(self)

    async def connect(self):
        self.is_connected = True

    async def start_notify(self, characteristic, callback):
        assert characteristic is self.tx
        self.notify = callback
        # Old unsolicited startup data is intentionally outside the live channel.
        callback(None, bytearray(b"startup-old"))
        await asyncio.sleep(0)
        self.subscribed = True

    async def write_gatt_char(self, characteristic, data, response):
        assert self.subscribed and characteristic is self.rx and response
        self.writes.append(bytes(data))
        seq, op = data[3], data[4]
        ack = frame(seq, 128, bytes([op, 0]))
        telemetry = frame(seq, 129)
        blocks = [ack, telemetry] if self.mode == "separate" else [ack + telemetry]
        if self.mode == "bytewise":
            blocks = [bytes([value]) for value in ack + telemetry]
        for block in blocks:
            mutable = bytearray(block)
            self.notify(None, mutable)
            mutable[:] = b"\xff" * len(mutable)
        await asyncio.sleep(.02)
        self.write_completed = True
        if self.mode == "fail_after_notify":
            raise IOError("controlled write failed after early response")

    async def disconnect(self):
        self.is_connected = False
        self.disconnect_callback(self)


class FirstNotifyTests(unittest.TestCase):
    def setUp(self):
        Client.instances = []
        Client.mode = "separate"
        bleak = types.ModuleType("bleak")
        bleak.BleakClient = Client
        self.fake_modules = patch.dict(sys.modules, {"bleak": bleak})
        self.fake_modules.start()
        self.host = native.NativeHost()
        self.window = Window()
        self.host._window = self.window
        self.host._window_ready.set()

    def tearDown(self):
        self.host._close()
        self.fake_modules.stop()

    def wait_bytes(self, length):
        deadline = time.monotonic() + .5
        while sum(len(bytes.fromhex(row[0])) for row in self.window.received) < length and time.monotonic() < deadline:
            time.sleep(.002)

    def exercise(self, mode):
        Client.mode = mode
        connection = self.host.connect("ble", "controlled-test-device")
        self.assertTrue(connection["ok"])
        generation = connection["generation"]
        request = frame(37, 8)
        result = self.host.write_frame(request.hex(), generation)
        self.wait_bytes(32)
        expected = frame(37, 128, bytes([8, 0])) + frame(37, 129)
        actual = b"".join(bytes.fromhex(row[0]) for row in self.window.received)
        self.assertEqual(actual, expected)
        self.assertTrue(all(row[1] == generation for row in self.window.received))
        self.assertTrue(self.window.arrived_before_write_completed)
        self.assertEqual(Client.instances[-1].writes, [request])
        return result

    def test_first_ack_before_write_completion(self):
        self.assertTrue(self.exercise("separate")["ok"])

    def test_bundled_ack_and_status_bytes_preserved(self):
        self.assertTrue(self.exercise("bundled")["ok"])
        self.assertEqual(len(self.window.received), 1)

    def test_single_byte_notification_fragments_preserved(self):
        self.assertTrue(self.exercise("bytewise")["ok"])
        self.assertEqual(len(self.window.received), 32)

    def test_early_response_cannot_hide_failed_write(self):
        result = self.exercise("fail_after_notify")
        self.assertFalse(result["ok"])
        self.assertFalse(Client.instances[-1].is_connected)

    def test_old_notify_cannot_enter_new_generation(self):
        first = self.host.connect("ble", "old")
        old = Client.instances[-1]
        second = self.host.connect("ble", "new")
        old.notify(None, bytearray(frame(1, 128, bytes([8, 0]))))
        old.disconnect_callback(old)
        time.sleep(.02)
        self.assertEqual(self.window.received, [])
        self.assertTrue(self.host._context.connected)
        self.assertNotEqual(first["generation"], second["generation"])


if __name__ == "__main__":
    faulthandler.enable()
    faulthandler.dump_traceback_later(15, exit=True)
    sources = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in ("desktop/native_host.py", "desktop/web/app.js", "desktop/web/controller.js", "desktop/web/protocol.js")}
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(FirstNotifyTests))
        unchanged = all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest for name, digest in sources.items())
        report = {"passed": result.testsRun - len(result.failures) - len(result.errors), "failed": len(result.failures) + len(result.errors), "newDefectReproduced": False, "sourceHashes": sources, "productionUnchanged": unchanged, "hardwareAccessed": False, "scope": "Actual NativeHost with a controlled BLE client and callback window; COM initialization only, no adapters/devices opened."}
        (OUT / "first-notify-result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        raise SystemExit(0 if result.wasSuccessful() and unchanged else 1)
    finally:
        faulthandler.cancel_dump_traceback_later()
