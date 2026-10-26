"""Windows BLE连接参数租约：公开WinRT API，可降级，不修改设备固件。

租约只在本次连接期间存在；关闭时释放偏好请求和本模块自己的设备引用。
吞吐优化预设不是毫秒延迟保证，实际连接间隔必须从get_connection_parameters读取。
"""
import asyncio
import contextlib
import re


class ConnectionPreference:
    def __init__(self, device, request=None):
        self.device = device
        self.request = request

    def describe(self):
        result = {'requested': self.request is not None, 'preset': 'throughput-optimized' if self.request else None}
        try:
            parameters = self.device.get_connection_parameters()
            result.update(intervalMs=parameters.connection_interval * 1.25,
                          peripheralLatency=parameters.connection_latency,
                          supervisionTimeoutMs=parameters.link_timeout * 10)
            if self.request is not None:
                result['requestStatus'] = int(self.request.status)
        except Exception as error:
            result['parametersUnavailable'] = type(error).__name__
        return result

    def close(self):
        for resource in (self.request, self.device):
            if resource is not None:
                with contextlib.suppress(Exception):
                    resource.close()
        self.request = self.device = None


async def prefer_performance(address, *, request=True, api=None):
    """MAC字符串→临时偏好租约；调用者负责finally关闭，旧Windows可捕获异常回退。"""
    if not isinstance(address, str) or re.fullmatch(r'[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}', address) is None:
        raise ValueError('性能链路需要已扫描的蓝牙MAC地址')
    if api is None:
        from winrt.windows.devices import bluetooth as api
    device = await asyncio.wait_for(api.BluetoothLEDevice.from_bluetooth_address_async(int(address.replace(':', ''), 16)), 3)
    if device is None:
        raise RuntimeError('Windows未返回已连接设备')
    try:
        lease = device.request_preferred_connection_parameters(api.BluetoothLEPreferredConnectionParameters.throughput_optimized) if request else None
        return ConnectionPreference(device, lease)
    except BaseException:
        device.close()
        raise
