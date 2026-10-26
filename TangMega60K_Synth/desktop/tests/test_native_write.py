"""原生写入策略与计时测试：假GATT对象，不扫描、不连接蓝牙。"""
import asyncio
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_host import NativeHost, _Context


class WriteTests(unittest.IsolatedAsyncioTestCase):
    async def test_both_write_modes_preserve_frame_and_await_write(self):
        for response in (True, False):
            accepted = []

            class Client:
                async def write_gatt_char(self, characteristic, frame, **options):
                    await asyncio.sleep(0.002)
                    accepted.append((characteristic, frame, options['response']))

            context = _Context('ble', 7)
            context.connected = True
            context.client = Client()
            context.rx = 'rx'
            context.write_response = response
            host = NativeHost.__new__(NativeHost)
            host._context = context
            host._transport_lock = asyncio.Lock()
            host._live = lambda generation: generation == 7
            frame = bytes(range(16))
            result = await host._write(frame, 7)
            self.assertEqual(accepted, [('rx', frame, response)])
            self.assertGreaterEqual(result['write_ms'], 1)
            self.assertEqual(result['write_mode'], 'gatt-response' if response else 'gatt-command')

    async def test_stale_connection_cannot_write(self):
        host = NativeHost.__new__(NativeHost)
        host._transport_lock = asyncio.Lock()
        host._context = SimpleNamespace(generation=7, connected=True)
        host._live = lambda generation: generation == 7
        with self.assertRaisesRegex(RuntimeError, '过期'):
            await host._write(bytes(16), 6)


if __name__ == '__main__':
    unittest.main(verbosity=2)
