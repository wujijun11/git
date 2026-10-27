"""原生单调时钟调度器。曲谱是音符事件，声音仍由FPGA实时HDL合成。"""
import asyncio

from .protocol import AckSession

MAX_EVENTS = 100000
MAX_DURATION_MS = 6 * 60 * 60 * 1000


def integer(value, low, high, label):
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{label}必须是{low}..{high}的整数")
    return value


def validate_rows(rows):
    """重验已映射的MIDI事件；单位ms，禁止悬音、同音重叠及超过64个按住音符。"""
    if not isinstance(rows, list) or not 1 <= len(rows) <= MAX_EVENTS:
        raise ValueError("实时曲谱事件数必须为1..100000")
    active, result, elapsed = set(), [], 0
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("无效曲谱事件")
        delta = integer(row.get("deltaMs"), 0, MAX_DURATION_MS, "事件间隔ms")
        elapsed += delta
        if elapsed > MAX_DURATION_MS:
            raise ValueError("实时曲谱最长6小时")
        midi = integer(row.get("midi"), 0, 127, "MIDI音高")
        on = integer(row.get("on"), 0, 1, "按下/松开")
        velocity = integer(row.get("velocity"), 1 if on else 0, 127, "力度")
        if bool(on) == (midi in active):
            raise ValueError("音符按下/松开不配对：MIDI " + str(midi))
        if on:
            active.add(midi)
        else:
            active.remove(midi)
        if len(active) > 64:
            raise ValueError("同时按住的音符超过64个")
        result.append(dict(deltaMs=delta, midi=midi, on=on, velocity=velocity))
    if active:
        raise ValueError("曲谱结尾缺少松开事件")
    return result


class NativePlayback:
    """在BLE原生事件循环运行。UI仅查询进度；不参与计时、ACK或保活。

    max_late_ms保持原250ms保护，不丢弃快速音符。每次ACK后才推进事件。
    只释放本任务发出的source=63音符；不发送全局PANIC，不干扰实体键。
    """

    def __init__(self, rows, timbre, seq, token, write, *, max_late_ms=250,
                 heartbeat_seconds=1.0, ack_timeout=1.5, retries=2):
        self.rows = validate_rows(rows)
        self.timbre = integer(timbre, 0, 3, "音色")
        self.token = token
        self.session = AckSession(write, integer(seq, 0, 255, "seq"), ack_timeout, retries)
        self.stop_event = asyncio.Event()
        self.held = set()
        self.completed = 0
        self.max_late_ms = max_late_ms
        self.heartbeat_seconds = heartbeat_seconds
        self.late_ms = 0.0
        self.state, self.error = "playing", None

    def stop(self):
        self.stop_event.set()
        self.state = "stopping"

    def lose(self):
        self.stop()
        self.session.lose()

    def snapshot(self):
        return dict(state=self.state, completed=self.completed, total=len(self.rows),
                    maxLateMs=self.late_ms, error=self.error, nextSeq=self.session.seq,
                    token=self.token, connectionLost=self.session.broken)

    async def run(self):
        clock = asyncio.get_running_loop().time
        due = last_request = clock()
        try:
            for row in self.rows:
                due += row["deltaMs"] / 1000
                while not self.stop_event.is_set() and clock() < due:
                    # 长休止和长按期间也由原生线程保活，避免界面暂停导致source63超时。
                    remaining = min(due - clock(), self.heartbeat_seconds - (clock() - last_request))
                    if remaining <= 0:
                        await self.session.request(8, [0])
                        last_request = clock()
                    else:
                        try:
                            await asyncio.wait_for(self.stop_event.wait(), remaining)
                        except asyncio.TimeoutError:
                            pass
                if self.stop_event.is_set():
                    break
                self.late_ms = max(self.late_ms, (clock() - due) * 1000)
                if self.late_ms > self.max_late_ms:
                    raise RuntimeError("发送落后曲谱超过250ms，已停止；请减少音轨或降低曲速")
                midi, on = row["midi"], row["on"]
                # 先记归属：NOTE ON已发但NACK/写入状态未知时也需要尝试释放。
                if on:
                    self.held.add(midi)
                await self.session.request(1, [63, midi, row["velocity"], self.timbre, on])
                if not on:
                    self.held.discard(midi)
                last_request = clock()
                self.completed += 1
                self.late_ms = max(self.late_ms, (clock() - due) * 1000)
                if not self.stop_event.is_set() and self.late_ms > self.max_late_ms:
                    raise RuntimeError("蓝牙确认落后曲谱超过250ms，已停止")
        except Exception as exc:
            self.error = str(exc) or type(exc).__name__
        finally:
            # 不在NOTE ON未确认时抢发NOTE OFF；停止会等当前事务落定。
            for midi in sorted(self.held):
                if self.session.broken:
                    break
                try:
                    await self.session.request(1, [63, midi, 0, self.timbre, 0])
                except Exception as exc:
                    self.error = self.error or str(exc)
                    # 松键结果未知时关闭连接，停止保活，让板上看门狗兜底释放。
                    self.session.broken = True
                    break
            self.held.clear()
            self.state = "error" if self.error else "stopped" if self.stop_event.is_set() else "finished"
        return self.snapshot()
