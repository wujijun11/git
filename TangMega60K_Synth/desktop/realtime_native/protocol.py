"""原16字节V1通信帧；仅供桌面原生播放租用既有会话，公共协议不变。"""
import asyncio


def crc8(data):
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ (7 if value & 128 else 0)) & 255
    return value


def encode(seq, op, payload=()):
    frame = bytearray(16)
    frame[:5] = bytes((0xA5, 0x5A, 1, seq, op))
    frame[5:5 + len(payload)] = bytes(payload)
    frame[15] = crc8(frame[2:15])
    return bytes(frame)


class AckSession:
    """同一时间仅一个请求；重试保持原seq和帧，避免FPGA重复执行音符。"""

    def __init__(self, write, seq, timeout=1.5, retries=2):
        self.write, self.seq = write, seq
        self.timeout, self.retries = timeout, retries
        self.pending = None
        self.buffer = bytearray()
        self.broken = False

    def feed(self, data):
        self.buffer.extend(data)
        while len(self.buffer) >= 16:
            if self.buffer[:3] != b"\xa5\x5a\x01" or self.buffer[15] != crc8(self.buffer[2:15]):
                del self.buffer[0]
                continue
            frame = bytes(self.buffer[:16])
            del self.buffer[:16]
            pending = self.pending
            if (pending and not pending[2].done() and frame[4] == 0x80
                    and frame[3] == pending[0] and frame[5] == pending[1]):
                pending[2].set_result(frame[6])

    def lose(self, reason="设备连接已断开"):
        self.broken = True
        if self.pending and not self.pending[2].done():
            self.pending[2].set_exception(ConnectionError(reason))

    async def request(self, op, payload=()):
        if self.broken:
            raise ConnectionError("原生播放会话已关闭")
        if self.pending:
            raise RuntimeError("原生播放不允许并发协议请求")
        seq = self.seq
        self.seq = (seq + 1) & 255
        frame = encode(seq, op, payload)
        ack = asyncio.get_running_loop().create_future()
        self.pending = (seq, op, ack)
        try:
            for attempt in range(self.retries + 1):
                # ACK可能在write返回之前到达，先登记pending；不要求界面转发。
                await self.write(frame)
                try:
                    status = await asyncio.wait_for(asyncio.shield(ack), self.timeout)
                except asyncio.TimeoutError:
                    if attempt < self.retries:
                        continue
                    raise ConnectionError("ACK超时，停止播放并关闭连接；请重新连接") from None
                if status:
                    raise RuntimeError("FPGA NACK status=" + str(status))
                return
        except (ConnectionError, OSError, asyncio.CancelledError):
            self.broken = True
            raise
        finally:
            if not ack.done():
                ack.cancel()
            elif not ack.cancelled():
                ack.exception()  # 消费写入失败与断连同拍时的异常，避免遗留future告警。
            self.pending = None
