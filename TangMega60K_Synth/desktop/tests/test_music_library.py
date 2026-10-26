"""不连接硬件的曲谱转换/目录解析回归；真实联网冒烟单独记录。"""
import io
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch
import mido

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score_library.midi_import import convert, inspect_midi
from score_library.mutopia import ListingParser, MutopiaCatalog, checked_url
from score_library.service import ScoreLibrary


def midi_bytes(messages, tempo=500000):
    midi = mido.MidiFile(ticks_per_beat=480)
    track = mido.MidiTrack([mido.MetaMessage("set_tempo", tempo=tempo)])
    track.extend(messages)
    midi.tracks.append(track)
    stream = io.BytesIO()
    midi.save(file=stream)
    return stream.getvalue()


def pair(note=60, ticks=480):
    return [mido.Message("note_on", note=note, velocity=100), mido.Message("note_off", note=note, time=ticks)]


class MusicLibraryTests(unittest.TestCase):
    def prepare(self, data, **kwargs):
        info, _ = inspect_midi(data)
        return convert(data, "test", {"tracks": [0], "endMs": info["durationMs"], **kwargs})

    def test_tempo_change(self):
        data = midi_bytes(pair() + [mido.MetaMessage("set_tempo", tempo=1000000)] + pair(62))
        result = self.prepare(data)
        self.assertEqual([r["deltaMs"] for r in result["score"]["rows"]], [0, 500, 0, 1000])

    def test_segment_seeds_and_releases_held_notes(self):
        result = self.prepare(midi_bytes(pair()), startMs=100, endMs=300)
        self.assertEqual(result["score"]["rows"], [
            {"deltaMs": 0, "key": 0, "velocity": 100, "on": 1},
            {"deltaMs": 200, "key": 0, "velocity": 0, "on": 0}])

    def test_range_is_not_silently_dropped(self):
        result = self.prepare(midi_bytes(pair(40)))
        self.assertFalse(result["canUpload"])
        self.assertEqual(result["eventCount"], 2)
        compact = self.prepare(midi_bytes(pair(40)), compact=True)
        self.assertTrue(compact["canUpload"])
        self.assertEqual(compact["score"]["mapping"][0], 40)

    def test_capacity_is_not_truncated(self):
        result = self.prepare(midi_bytes(sum((pair() for _ in range(513)), [])))
        self.assertFalse(result["canUpload"])
        self.assertEqual(result["eventCount"], 1026)

    def test_exactly_1024_and_legacy_capacity(self):
        data = midi_bytes(sum((pair() for _ in range(512)), []))
        result = self.prepare(data)
        self.assertTrue(result["canUpload"])
        self.assertEqual(result["eventCount"], 1024)
        self.assertEqual(result["maxEvents"], 1024)
        legacy = self.prepare(data, maxEvents=256)
        self.assertFalse(legacy["canUpload"])
        self.assertEqual(legacy["eventCount"], 1024)

    def test_invalid_capacity(self):
        with self.assertRaises(ValueError):
            self.prepare(midi_bytes(pair()), maxEvents=4096)

    def test_more_than_25_distinct_pitches(self):
        result = self.prepare(midi_bytes(sum((pair(n) for n in range(40, 66)), [])), compact=True)
        self.assertFalse(result["canUpload"])
        self.assertEqual(result["pitchCount"], 26)

    def test_velocity_zero_and_overlap(self):
        data = midi_bytes([mido.Message("note_on", note=60), mido.Message("note_on", note=60, channel=1),
                           mido.Message("note_off", note=60, time=240),
                           mido.Message("note_on", note=60, channel=1, velocity=0, time=240)])
        result = self.prepare(data)
        self.assertEqual(len(result["score"]["rows"]), 2)
        self.assertEqual(result["score"]["rows"][-1]["deltaMs"], 500)
        self.assertTrue(result["warnings"])

    def test_unsupported_controls_are_visible(self):
        result = self.prepare(midi_bytes([mido.Message("control_change", control=64, value=127)] + pair()))
        self.assertTrue(any("踏板" in warning for warning in result["warnings"]))

    def test_track_selection_uses_global_tempo(self):
        midi = mido.MidiFile(ticks_per_beat=480)
        midi.tracks = [mido.MidiTrack([mido.MetaMessage("set_tempo", tempo=1000000)]), mido.MidiTrack(pair())]
        stream = io.BytesIO(); midi.save(file=stream)
        result = self.prepare(stream.getvalue(), tracks=[1])
        self.assertEqual(result["score"]["rows"][-1]["deltaMs"], 1000)

    def test_invalid_files_and_options(self):
        with self.assertRaises(Exception): inspect_midi(b"not midi")
        with self.assertRaises(ValueError): self.prepare(midi_bytes(pair()), tracks=[99])
        with self.assertRaises(ValueError): self.prepare(midi_bytes(pair()), startMs=300, endMs=100)

    def test_zip_is_memory_only_and_bounded(self):
        with tempfile.TemporaryDirectory() as folder:
            service = ScoreLibrary(folder)
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, "w") as archive:
                archive.writestr("../../example.mid", midi_bytes(pair()))
            result = service.load_bytes(stream.getvalue(), "archive.zip")
            self.assertEqual(len(result["files"]), 1)
            self.assertEqual(list(Path(folder).iterdir()), [])
            self.assertTrue(service.prepare(result["files"][0]["token"], {"tracks": [0], "endMs": 500})["canUpload"])
            with self.assertRaises(ValueError): service.fetch("arbitrary url")

    def test_url_restrictions(self):
        for url in ("http://localhost/a.mid", "file:///a", "https://example.com/a", "https://www.mutopiaproject.org:99/a"):
            with self.assertRaises(ValueError): checked_url(url)
        self.assertTrue(checked_url("http://www.mutopiaproject.org/ftp/a.mid").startswith("https:"))

    def test_catalog_parse_and_cache(self):
        html = '<table class="result-table"><tr>' + ''.join(f'<td>{value}</td>' for value in
            ['Title', 'Composer', '', '', 'Piano', '', '', '', '', '<a href="../legal.html#publicdomain">Public Domain</a>',
             '<a href="piece-info.cgi?id=1">More</a>', '', '<a href="https://www.mutopiaproject.org/ftp/test.mid">.mid file</a>']) + '</tr></table>'
        parser = ListingParser(); parser.feed(html)
        self.assertEqual(parser.results[0]["title"], "Title")
        with tempfile.TemporaryDirectory() as folder:
            catalog = MutopiaCatalog(folder)
            with patch("score_library.mutopia.download", return_value=html.encode()) as fetch:
                first = catalog.search("Title"); second = catalog.search("Title")
                self.assertEqual(fetch.call_count, 1)
                self.assertTrue(second["cached"])
                self.assertEqual(first["items"][0]["license"], "Public Domain")


if __name__ == "__main__":
    unittest.main(verbosity=2)
