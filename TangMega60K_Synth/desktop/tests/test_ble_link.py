"""Windows偏好请求生命周期测试，WinRT设备为替身，确保退回默认设置。"""
import sys
import types
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ble_link import prefer_performance


class LinkTests(unittest.IsolatedAsyncioTestCase):
    async def test_lease_uses_public_api_and_releases_both_objects(self):
        calls = []
        request = types.SimpleNamespace(status=1, close=lambda: calls.append('request-close'))
        device = types.SimpleNamespace(
            get_connection_parameters=lambda: types.SimpleNamespace(connection_interval=12, connection_latency=0, link_timeout=200),
            request_preferred_connection_parameters=lambda preset: calls.append(preset) or request,
            close=lambda: calls.append('device-close'))

        async def factory(address):
            self.assertEqual(address, 0x901122334455)
            return device

        api = types.SimpleNamespace(BluetoothLEDevice=types.SimpleNamespace(from_bluetooth_address_async=factory),
                                    BluetoothLEPreferredConnectionParameters=types.SimpleNamespace(throughput_optimized='throughput'))
        lease = await prefer_performance('90:11:22:33:44:55', api=api)
        self.assertEqual(lease.describe()['intervalMs'], 15)
        self.assertEqual(calls, ['throughput'])
        lease.close()
        lease.close()
        self.assertEqual(calls, ['throughput', 'request-close', 'device-close'])

    async def test_request_failure_closes_device_without_leaking(self):
        closed = []

        def fail(_):
            raise OSError('unsupported')

        async def factory(_):
            return types.SimpleNamespace(request_preferred_connection_parameters=fail,
                                         close=lambda: closed.append(True))

        api = types.SimpleNamespace(BluetoothLEDevice=types.SimpleNamespace(from_bluetooth_address_async=factory),
                                    BluetoothLEPreferredConnectionParameters=types.SimpleNamespace(throughput_optimized='throughput'))
        with self.assertRaisesRegex(OSError, 'unsupported'):
            await prefer_performance('90:11:22:33:44:55', api=api)
        self.assertEqual(closed, [True])

    async def test_invalid_address_never_calls_os(self):
        with self.assertRaises(ValueError):
            await prefer_performance('not-an-address', api=object())


if __name__ == '__main__':
    unittest.main(verbosity=2)
