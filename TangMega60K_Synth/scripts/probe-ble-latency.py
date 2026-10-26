"""经用户授权的BLE只读测时：只发READBACK0，不发NOTE/CONFIG/PANIC。

一次最多一个在途请求，保存ACK及遥测到达时间、GATT写耗时和桥计数。
结果是状态往返时间，不能冒充按键到DAC声学延迟。
"""
import argparse
import asyncio
import ctypes
import contextlib
import json
import secrets
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'desktop'))
from native_host import SERVICE_UUID, RX_UUID, TX_UUID, DIAG_UUID, _decode_bridge_diagnostics


def encode(seq):
    data = bytearray([165, 90, 1, seq, 8] + [0] * 11)
    crc = 0
    for value in data[2:15]:
        crc ^= value
        for _ in range(8):
            crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
    data[15] = crc
    return bytes(data)


def summary(values):
    values = sorted(values)
    return {'count': len(values), 'medianMs': statistics.median(values),
            'p95Ms': values[max(0, (95 * len(values) + 99) // 100 - 1)],
            'minMs': values[0], 'maxMs': values[-1]}


async def measure(args, report):
    from bleak import BleakScanner, BleakClient
    devices = await BleakScanner.discover(timeout=6, return_adv=True, service_uuids=[SERVICE_UUID])
    matches = [(device, adv) for device, adv in devices.values()
               if 'Tang-Synth' in (adv.local_name or device.name or '')]
    report['scanMatches'] = [{'name': adv.local_name or device.name, 'address': device.address}
                             for device, adv in matches]
    if len(matches) != 1:
        raise RuntimeError(f'发现{len(matches)}个Tang-Synth设备；若已被原客户端占用，请先点断开再测')
    async with contextlib.AsyncExitStack() as resources:
        client = await resources.enter_async_context(BleakClient(matches[0][0], timeout=15))
        service = client.services.get_service(SERVICE_UUID)
        rx = service.get_characteristic(RX_UUID)
        tx = service.get_characteristic(TX_UUID)
        diag = service.get_characteristic(DIAG_UUID)
        if not rx or not tx:
            raise RuntimeError('缺少NUS服务特征')
        response = 'write-without-response' not in rx.properties
        preference = None
        try:
            from ble_link import prefer_performance
            preference = await prefer_performance(matches[0][0].address, request=args.windows_fast)
            resources.callback(preference.close)
            report['windowsLinkBefore'] = preference.describe()
            if args.windows_fast:
                await asyncio.sleep(1)
                report['windowsLinkAfter'] = preference.describe()
        except Exception as error:
            report['windowsPreferenceError'] = f'{type(error).__name__}: {error}'
        report['writeMode'] = 'with-response' if response else 'without-response'
        report['rxProperties'] = list(rx.properties)
        if diag:
            report['diagnosticsBefore'] = _decode_bridge_diagnostics(bytes(await client.read_gatt_char(diag)))
        received = asyncio.Queue()
        buffer = bytearray()

        def notify(_, data):
            buffer.extend(data)
            while len(buffer) >= 16:
                if buffer[:2] != b'\xa5\x5a':
                    del buffer[0]
                    continue
                frame = bytes(buffer[:16]); del buffer[:16]
                crc = 0
                for value in frame[2:15]:
                    crc ^= value
                    for _ in range(8):
                        crc = ((crc << 1) ^ (7 if crc & 128 else 0)) & 255
                if crc == frame[15] and frame[2] == 1:
                    received.put_nowait((time.perf_counter(), frame))

        await client.start_notify(tx, notify)
        sequence = secrets.randbelow(256)
        samples = report['samples'] = []
        for index in range(args.count):
            sequence = (sequence + 1) & 255
            started = time.perf_counter()
            # 固定编码器没有生成其他opcode的入口。
            await client.write_gatt_char(rx, encode(sequence), response=response)
            write_ms = (time.perf_counter() - started) * 1000
            report['lastWriteMs'] = write_ms
            ack_ms = data_ms = None
            deadline = started + 3
            rejected = False
            while ack_ms is None or data_ms is None:
                try:
                    when, frame = await asyncio.wait_for(received.get(), max(0.001, deadline - time.perf_counter()))
                except asyncio.TimeoutError:
                    report['partialSample']={'index':index,'seq':sequence,'writeMs':write_ms,
                                             'ackMs':ack_ms,'telemetryMs':data_ms}
                    if diag:
                        report['diagnosticsAfter']=_decode_bridge_diagnostics(bytes(await client.read_gatt_char(diag)))
                    raise RuntimeError('BLE写入完成，但3秒内未收到完整FPGA状态应答，无法统计有效往返')
                if frame[3] != sequence:
                    continue
                if frame[4] == 128 and frame[5] == 8:
                    if frame[6] != 0:
                        if index == 0 and frame[6] == 1:
                            rejected = True; break
                        raise RuntimeError(f'FPGA拒绝只读查询，状态{frame[6]}')
                    ack_ms = (when - started) * 1000
                elif frame[4] == 129:
                    data_ms = (when - started) * 1000
            if rejected:
                report['firstSequenceConflictSkipped'] = True
                continue
            samples.append({'index': index, 'seq': sequence, 'writeMs': write_ms,
                            'ackMs': ack_ms, 'telemetryMs': data_ms})
            await asyncio.sleep(0.02)
        if diag:
            report['diagnosticsAfter'] = _decode_bridge_diagnostics(bytes(await client.read_gatt_char(diag)))
        await client.stop_notify(tx)
        report['summary'] = {name: summary([sample[key] for sample in samples])
                             for name, key in [('gattWrite', 'writeMs'), ('fpgaAck', 'ackMs'),
                                               ('fullStatus', 'telemetryMs')]}
        report['measured'] = True
        if preference:
            report['windowsLinkAtEnd'] = preference.describe()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, default=24)
    parser.add_argument('--windows-fast', action='store_true', help='连接期间申请Windows吞吐优化预设，完成后自动释放')
    parser.add_argument('--output', type=Path, default=ROOT / 'verification/ble-latency/live-before.json')
    args = parser.parse_args()
    if not 1 <= args.count <= 100:
        parser.error('count必须为1..100')
    report = {'measured': False, 'requestOpcode': 8, 'requestSelector': 0,
              'audioEventsSent': 0, 'configurationWritten': False,
              'meaning': '只读状态查询往返，不是DAC发声延迟'}
    initialized = False
    try:
        if sys.platform == 'win32':
            initialized = ctypes.windll.ole32.CoInitializeEx(None, 0) in (0, 1)
        asyncio.run(measure(args, report))
    except Exception as error:
        report['error'] = f'{type(error).__name__}: {error}'
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        if initialized:
            ctypes.windll.ole32.CoUninitialize()
    print(json.dumps(report.get('summary', {'error': report.get('error')}), ensure_ascii=False, indent=2))
    return 0 if report['measured'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
