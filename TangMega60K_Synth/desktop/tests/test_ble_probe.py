"""验证测时脚本只发送只读状态帧，所有蓝牙对象均为替身。"""
import asyncio
import importlib.util
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ble_probe', ROOT / 'scripts/probe-ble-latency.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class ProbeTests(unittest.IsolatedAsyncioTestCase):
    async def test_probe_sends_no_note_config_or_panic(self):
        for no_response in (False, True):
            writes = []
            characteristics = {probe.RX_UUID: types.SimpleNamespace(properties=['write-without-response'] if no_response else ['write']),
                               probe.TX_UUID: object(), probe.DIAG_UUID: object()}

            class Scanner:
                @staticmethod
                async def discover(**kwargs):
                    return {'one': (types.SimpleNamespace(address='test-only', name='Tang-Synth-C3'),
                                    types.SimpleNamespace(local_name='Tang-Synth-C3'))}

            class Client:
                def __init__(self, *args, **kwargs):
                    self.services = types.SimpleNamespace(get_service=lambda _: types.SimpleNamespace(
                        get_characteristic=characteristics.get))

                async def __aenter__(self):
                    return self

                async def __aexit__(self, *args):
                    pass

                async def read_gatt_char(self, characteristic):
                    return bytes(16) + b'TB\x01\x01' + bytes(20)

                async def start_notify(self, characteristic, callback):
                    self.callback = callback

                async def stop_notify(self, characteristic):
                    pass

                async def write_gatt_char(self, characteristic, frame, response):
                    writes.append(frame)
                    self_test.assertEqual(frame[4], 8)
                    self_test.assertEqual(frame[5:15], bytes(10))
                    self_test.assertEqual(response, not no_response)
                    # 复用独立的协议CRC算法生成ACK和遥测，模拟分段到达。
                    def packet(op, payload):
                        data = bytearray(frame)
                        data[4] = op
                        data[5:15] = (payload + bytes(10))[:10]
                        crc = 0
                        for b in data[2:15]:
                            crc ^= b
                            for _ in range(8):
                                crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
                        data[15] = crc
                        return data
                    ack = packet(128, bytes([8, 0]))
                    self.callback(None, ack[:5])
                    self.callback(None, ack[5:] + packet(129, bytes(10)))

            self_test = self
            report = {}
            with patch.dict(sys.modules, {'bleak': types.SimpleNamespace(BleakScanner=Scanner, BleakClient=Client)}):
                await probe.measure(types.SimpleNamespace(count=3,windows_fast=False), report)
            self.assertTrue(report['measured'])
            self.assertEqual(len(writes), 3)
            self.assertEqual(len(report['samples']), 3)

    def test_crc_encoder_uses_only_readback(self):
        for sequence in range(256):
            frame = probe.encode(sequence)
            self.assertEqual(frame[:5], bytes([165, 90, 1, sequence, 8]))
            self.assertEqual(frame[5:15], bytes(10))


if __name__ == '__main__':
    unittest.main(verbosity=2)
