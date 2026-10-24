"""Optional diagnostic reads on actual NativeHost with controlled transports."""
import asyncio
import faulthandler
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys
import time
import types
import unittest
from unittest.mock import patch

OUT = Path(__file__).resolve().parent
ROOT = OUT.parents[2]
spec = importlib.util.spec_from_file_location("old_native_fixtures", ROOT / "verification/desktop-app-20261021/test_native_host.py")
old = importlib.util.module_from_spec(spec)
spec.loader.exec_module(old)
native = old.native


def diagnostic(traffic=(0, 0, 0, 0, 0), errors=(0, 0, 0, 0), flags=1):
    return struct.pack("<4I", *errors) + b"TB\x01" + bytes([flags]) + struct.pack("<5I", *traffic)


class Client(old.FakeClient):
    support = True
    effects = []

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.reads = []
        self.effects = list(type(self).effects)
        self.diag = types.SimpleNamespace(uuid=native.DIAG_UUID, properties=["read"])
        previous = self.services.get_service(native.SERVICE_UUID)
        self.services = types.SimpleNamespace(get_service=lambda uuid: types.SimpleNamespace(get_characteristic=lambda characteristic:
            self.diag if characteristic == native.DIAG_UUID and self.support else None if characteristic == native.DIAG_UUID else previous.get_characteristic(characteristic)) if uuid == native.SERVICE_UUID else None)

    async def read_gatt_char(self, characteristic):
        assert self.subscribed and characteristic is self.diag
        self.reads.append(characteristic.uuid)
        effect = self.effects.pop(0) if self.effects else diagnostic()
        if isinstance(effect, Exception):
            raise effect
        if effect == "hang":
            await asyncio.sleep(10)
        return effect


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        old.FakeClient.instances = []
        old.FakeClient.service_mode = "ok"
        old.FakeClient.connect_delay = 0
        Client.support = True
        Client.effects = [diagnostic(), diagnostic((1, 1, 0, 0, 0))]
        bleak = types.ModuleType("bleak")
        bleak.BleakClient = Client
        serial = types.ModuleType("serial")
        serial.Serial = old.FakeSerial
        self.modules = patch.dict(sys.modules, {"bleak": bleak, "serial": serial})
        self.modules.start()
        self.host = native.NativeHost()
        self.host._window = old.FakeWindow()
        self.host._window_ready.set()

    def tearDown(self):
        self.host._close()
        self.modules.stop()

    def connect(self):
        result = self.host.connect("ble", "controlled-diagnostic-device")
        self.assertTrue(result["ok"], result)
        return result["generation"], old.FakeClient.instances[-1]

    def test_baseline_precedes_first_write_and_disconnect_returns_delta(self):
        generation, client = self.connect()
        self.assertEqual(client.reads, [native.DIAG_UUID])
        self.assertEqual(client.writes, [])
        self.assertTrue(self.host.write_frame(old.FRAME, generation)["ok"])
        result = self.host.disconnect(generation)
        self.assertTrue(result["ok"])
        report = result["diagnostics"]
        self.assertEqual(report["generation"], generation)
        self.assertEqual(report["delta"]["bleReceivedFrames"], 1)
        self.assertEqual(report["delta"]["uartSentFrames"], 1)
        self.assertEqual(report["delta"]["uartReceivedBytes"], 0)
        self.assertFalse(client.is_connected)
        self.assertEqual(client.reads, [native.DIAG_UUID] * 2)

    def test_counter_wrap_is_uint32(self):
        Client.effects = [diagnostic((0xFFFFFFFE, 0xFFFFFFFF, 0, 0, 0)), diagnostic((1, 2, 0, 0, 0))]
        generation, _ = self.connect()
        report = self.host.disconnect(generation)["diagnostics"]
        self.assertEqual(report["delta"]["bleReceivedFrames"], 3)
        self.assertEqual(report["delta"]["uartSentFrames"], 3)

    def test_missing_baseline_exposes_only_cumulative_values(self):
        Client.effects = [IOError("baseline unavailable"), diagnostic((99, 88, 0, 0, 0))]
        generation, _ = self.connect()
        report = self.host.disconnect(generation)["diagnostics"]
        self.assertIsNone(report["delta"])
        self.assertEqual(report["deltaReason"], "baseline_unavailable")
        self.assertEqual(report["after"]["counters"]["uartSentFrames"], 88)

    def test_after_read_failure_does_not_prevent_cleanup(self):
        Client.effects = [diagnostic(), IOError("after unavailable")]
        generation, client = self.connect()
        result = self.host.disconnect(generation)
        self.assertTrue(result["ok"])
        self.assertEqual(result["diagnostics"]["after"]["reason"], "read_failed")
        self.assertFalse(client.is_connected)
        self.assertIsNone(self.host._context)

    def test_diagnostic_timeouts_are_bounded_and_optional(self):
        Client.effects = ["hang", "hang"]
        with patch.object(native, "DIAG_READ_TIMEOUT", .015):
            started = time.monotonic()
            generation, client = self.connect()
            result = self.host.disconnect(generation)
        self.assertLess(time.monotonic() - started, .5)
        self.assertTrue(result["ok"])
        self.assertEqual(result["diagnostics"]["baseline"]["reason"], "read_timeout")
        self.assertEqual(result["diagnostics"]["after"]["reason"], "read_timeout")
        self.assertFalse(client.is_connected)

    def test_missing_characteristic_preserves_legacy_connection(self):
        Client.support = False
        generation, client = self.connect()
        self.assertTrue(self.host.write_frame(old.FRAME, generation)["ok"])
        report = self.host.disconnect(generation)["diagnostics"]
        self.assertEqual(client.reads, [])
        self.assertEqual(report["after"]["reason"], "missing_characteristic")

    def test_strict_legacy_and_unknown_formats(self):
        legacy = native._decode_bridge_diagnostics(struct.pack("<4I", 1, 2, 3, 4))
        self.assertEqual(legacy["format"], "legacy16")
        self.assertEqual(legacy["counters"]["resyncCount"], 4)
        for raw in (b"bad", bytes(20), diagnostic()[:16] + b"TB\x02\x01" + bytes(20)):
            result = native._decode_bridge_diagnostics(raw)
            self.assertFalse(result["available"])
            self.assertNotIn("counters", result)
        Client.effects = [struct.pack("<4I", 1, 2, 3, 4), struct.pack("<4I", 2, 4, 6, 8)]
        generation, _ = self.connect()
        report = self.host.disconnect(generation)["diagnostics"]
        self.assertEqual(report["delta"], dict(zip(native.DIAG_ERROR_COUNTERS, (1, 2, 3, 4))))

    def test_format_change_never_constructs_traffic_delta(self):
        Client.effects = [struct.pack("<4I", 1, 2, 3, 4), diagnostic((9, 9, 0, 0, 0))]
        generation, _ = self.connect()
        report = self.host.disconnect(generation)["diagnostics"]
        self.assertIsNone(report["delta"])
        self.assertEqual(report["deltaReason"], "format_changed")

    def test_serial_never_reads_ble_diagnostics(self):
        result = self.host.connect("serial", "COM17")
        self.assertTrue(result["ok"])
        self.assertNotIn("diagnostics", self.host.disconnect(result["generation"]))
        self.assertEqual(old.FakeClient.instances, [])

    def test_old_generation_disconnect_does_not_read_current_device(self):
        old_generation, old_client = self.connect()
        generation, client = self.connect()
        self.assertFalse(self.host.disconnect(old_generation)["ok"])
        self.assertEqual(client.reads, [native.DIAG_UUID])
        self.assertTrue(client.is_connected)
        self.assertEqual(len(old_client.reads), 1)
        self.host.disconnect(generation)

    def test_already_failed_link_returns_same_generation_cached_baseline(self):
        generation, client = self.connect()
        client.is_connected = False
        client.disconnected_callback(client)
        deadline = time.monotonic() + .5
        while self.host._context is not None and time.monotonic() < deadline:
            time.sleep(.002)
        report = self.host.disconnect(generation)["diagnostics"]
        self.assertEqual(report["generation"], generation)
        self.assertTrue(report["baseline"]["available"])
        self.assertEqual(report["after"]["reason"], "link_closed")
        self.assertEqual(len(client.reads), 1)


if __name__ == "__main__":
    faulthandler.enable()
    faulthandler.dump_traceback_later(15, exit=True)
    before = hashlib.sha256((ROOT / "desktop/native_host.py").read_bytes()).hexdigest()
    try:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(DiagnosticTests))
        report = {"passed": result.testsRun - len(result.failures) - len(result.errors), "failed": len(result.failures) + len(result.errors), "hardwareAccessed": False, "nativeSourceSha256": before, "sourceUnchanged": before == hashlib.sha256((ROOT / "desktop/native_host.py").read_bytes()).hexdigest(), "diagnosticReadTimeoutSeconds": native.DIAG_READ_TIMEOUT}
        (OUT / "diagnostics-result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, indent=2))
        raise SystemExit(0 if result.wasSuccessful() and report["sourceUnchanged"] else 1)
    finally:
        faulthandler.cancel_dump_traceback_later()
