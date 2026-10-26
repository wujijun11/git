"""验证长曲谱只在明确选择实时播放时放宽板上容量，并核对两端转换一致。"""
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
import mido
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score_library.midi_import import convert


class RealtimeMidiTests(unittest.TestCase):
    def test_long_midi_and_mobile_match(self):
        midi = mido.MidiFile()
        track = mido.MidiTrack()
        midi.tracks.append(track)
        for i in range(600):
            pitch = 36 + i % 60
            track.append(mido.Message("note_on", note=pitch, velocity=100, time=24))
            track.append(mido.Message("note_off", note=pitch, time=24))
        data = io.BytesIO()
        midi.save(file=data)
        options = {"tracks": [0], "direct": True, "maxEvents": 1024}
        offline = convert(data.getvalue(), "long", options)
        self.assertFalse(offline["canUpload"])
        self.assertEqual(offline["eventCount"], 1200)
        realtime = convert(data.getvalue(), "long", {**options, "realtime": True})
        self.assertTrue(realtime["canStream"])
        self.assertFalse(realtime["canUpload"])
        self.assertNotIn("mapping", realtime["score"])
        self.assertEqual(realtime["score"]["transport"], "realtime")
        root = Path(__file__).resolve().parents[2]
        script = """const fs=require('fs'),s=require('./mobile/web/music/smf.js');
const i=JSON.parse(fs.readFileSync(0,'utf8'));
console.log(JSON.stringify(s.convert(s.parse(Uint8Array.from(i.bytes)), 'long', i.options)));"""
        mobile = json.loads(subprocess.check_output(["node", "-e", script], cwd=root,
            input=json.dumps({"bytes": list(data.getvalue()), "options": {**options, "realtime": True}}).encode()))
        self.assertEqual(mobile["score"]["rows"], realtime["score"]["rows"])
        self.assertTrue(mobile["canStream"])
        self.assertFalse(mobile["canUpload"])


if __name__ == "__main__":
    unittest.main()
