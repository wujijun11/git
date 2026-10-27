"""假GATT+真实asyncio；不扫描、不连接板卡。验证事件完整性和协议边界。"""
import asyncio
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_host import NativeHost, _Context
from realtime_native import NativePlayback, validate_rows
from realtime_native.protocol import AckSession, encode


def note(midi, on, delta=0):
    return dict(midi=midi, on=on, deltaMs=delta, velocity=90 if on else 0)


class NativeTests(unittest.IsolatedAsyncioTestCase):
    def wire(self, rows, **options):
        frames = []
        async def write(frame):
            frames.append(frame)
            ack = encode(frame[3], 0x80, [frame[4], 0])
            # 拆包、噪声和数据响应均走真实解码器，不调用request的内部完成方法。
            player.session.feed(b"garbage" + ack[:9])
            player.session.feed(ack[9:] + encode(frame[3], 0x81))
        player = NativePlayback(rows, 2, 254, "test", write, **options)
        return player, frames

    async def test_fast_chords_sequence_wrap_all_events_no_ui(self):
        rows = []
        for _ in range(20):
            rows += [note(60, 1), note(64, 1), note(67, 1), note(60, 0, 2), note(64, 0), note(67, 0)]
        player, frames = self.wire(rows)
        result = await player.run()
        self.assertEqual(result["state"], "finished")
        self.assertEqual(result["completed"], len(rows))
        self.assertEqual([tuple(f[5:10]) for f in frames], [(63, r["midi"], r["velocity"], 2, r["on"]) for r in rows])
        self.assertEqual([f[3] for f in frames], [(254 + i) & 255 for i in range(len(rows))])

    async def test_stop_while_on_inflight_releases_after_ack(self):
        written, permit = asyncio.Event(), asyncio.Event()
        frames = []
        async def write(frame):
            frames.append(frame)
            if frame[9]:
                written.set()
                await permit.wait()
            player.session.feed(encode(frame[3], 128, [frame[4], 0]))
        player = NativePlayback([note(60, 1), note(60, 0, 10000)], 1, 1, "stop", write)
        task = asyncio.create_task(player.run())
        await written.wait()
        player.stop()
        self.assertEqual(len(frames), 1)
        permit.set()
        result = await task
        self.assertEqual(result["state"], "stopped")
        self.assertEqual([f[9] for f in frames], [1, 0])
        self.assertEqual(result["completed"], 1)

    async def test_idle_keepalive_without_ui_queries(self):
        player, frames = self.wire([note(60, 1), note(60, 0, 10000)], heartbeat_seconds=.015)
        original_write = player.session.write
        async def write(frame):
            await original_write(frame)
            if sum(f[4] == 8 for f in frames) == 3:
                player.stop()
        player.session.write = write
        # 用第三次保活作为停止因果点，不依赖Windows在80ms内唤醒几次。
        self.assertEqual((await asyncio.wait_for(player.run(), 2))["state"], "stopped")
        self.assertEqual(sum(f[4] == 8 for f in frames), 3)
        self.assertEqual(sum(f[4] == 1 for f in frames), 2)

    async def test_too_slow_preserves_threshold_and_releases(self):
        frames = []
        async def write(frame):
            frames.append(frame)
            if frame[9]:
                await asyncio.sleep(.03)
            player.session.feed(encode(frame[3], 128, [frame[4], 0]))
        player = NativePlayback([note(60, 1), note(60, 0, 100)], 2, 0, "slow", write, max_late_ms=20)
        result = await player.run()
        self.assertEqual(result["state"], "error")
        self.assertEqual([f[9] for f in frames], [1, 0])
        self.assertFalse(result["connectionLost"])

    async def test_retry_identical_frame_wrong_ack_ignored(self):
        frames = []
        async def write(frame):
            frames.append(frame)
            session.feed(encode((frame[3] + 1) & 255, 128, [1, 0]))
            session.feed(encode(frame[3], 128, [2, 0]))
            if len(frames) == 2:
                session.feed(encode(frame[3], 128, [1, 0]))
        session = AckSession(write, 255, timeout=.005)
        await session.request(1, [63, 60, 80, 2, 1])
        self.assertEqual(frames[0], frames[1])
        self.assertEqual(session.seq, 0)

    async def test_ack_timeout_closes_no_future_events(self):
        frames = []
        async def write(frame):
            frames.append(frame)
        player = NativePlayback([note(60, 1), note(60, 0, 100)], 2, 0, "lost", write, ack_timeout=.003, retries=1)
        result = await player.run()
        self.assertTrue(result["connectionLost"])
        self.assertEqual(len(frames), 2)
        self.assertEqual(frames[0], frames[1])

    async def test_nack_releases_owned_notes(self):
        player, frames = self.wire([note(60, 1), note(60, 0, 100)])
        async def write(frame):
            frames.append(frame)
            player.session.feed(encode(frame[3], 128, [1, 1 if frame[9] else 0]))
        player.session.write = write
        self.assertEqual((await player.run())["state"], "error")
        self.assertEqual([f[9] for f in frames], [1, 0])

    async def test_stop_before_start_sends_nothing(self):
        player, frames = self.wire([note(60, 1), note(60, 0, 100)])
        player.stop()
        self.assertEqual((await player.run())["state"], "stopped")
        self.assertEqual(frames, [])

    async def test_disconnect_wakes_pending_ack(self):
        started = asyncio.Event()
        async def write(frame):
            started.set()
        player = NativePlayback([note(60, 1), note(60, 0, 100)], 2, 0, "lost", write)
        task = asyncio.create_task(player.run())
        await started.wait()
        player.lose()
        result = await asyncio.wait_for(task, .1)
        self.assertTrue(result["connectionLost"])

    async def test_host_routes_acks_without_any_ui_callback(self):
        context = _Context("ble", 7)
        context.connected = True
        host = NativeHost.__new__(NativeHost)
        host._context, host._live = context, lambda g: g == 7
        host._queue_callback = lambda *args: self.fail("原生播放期间不应将ACK送到界面")
        async def write(frame, generation):
            host._receive(encode(frame[3], 128, [frame[4], 0]), context)
        host._write = write
        result = await host._play_realtime([note(60, 1), note(60, 0, 2)], 2, 8, "host", 7)
        self.assertEqual(result["nextSeq"], 10)
        self.assertIsNone(context.playback)
        with self.assertRaisesRegex(RuntimeError, "过期"):
            await host._playback_control("host", 6, True)

    async def test_host_stop_before_start_and_wrong_token_isolation(self):
        context = _Context("serial", 7)
        context.connected = True
        host = NativeHost.__new__(NativeHost)
        host._context, host._live = context, lambda g: g == 7
        await host._playback_control("cancelled", 7, True)
        async def write(frame, generation):
            context.playback.session.feed(encode(frame[3], 128, [frame[4], 0]))
        host._write = write
        rows = [note(60, 1), note(60, 0, 2)]
        self.assertEqual((await host._play_realtime(rows, 2, 0, "cancelled", 7))["state"], "stopped")
        self.assertEqual((await host._play_realtime(rows, 2, 0, "new", 7))["state"], "finished")

    def test_validation_rejects_bad_rows_and_accepts_full_midi(self):
        self.assertEqual(len(validate_rows([note(0, 1), note(0, 0), note(127, 1), note(127, 0)])), 4)
        for rows in ([], [note(60, 1)], [note(60, 0)], [note(60, 1), note(60, 1), note(60, 0)],
                     [note(60, 1, True), note(60, 0)]):
            with self.assertRaises(ValueError):
                validate_rows(rows)


if __name__ == "__main__":
    unittest.main(verbosity=2)
