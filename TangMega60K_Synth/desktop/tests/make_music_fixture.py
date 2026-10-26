"""生成浏览器测试需要的真实MIDI转换结果，确保新工作区可复现测试。"""
import io
import json
import sys
from pathlib import Path
import mido

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from score_library.midi_import import convert


def main():
    target = Path(sys.argv[1])
    target.parent.mkdir(parents=True, exist_ok=True)
    midi = mido.MidiFile(ticks_per_beat=480)
    track = mido.MidiTrack()
    for note in (40, 42):
        track.append(mido.Message('note_on', note=note, velocity=100))
        track.append(mido.Message('note_off', note=note, time=480))
    midi.tracks.append(track)
    stream = io.BytesIO()
    midi.save(file=stream)
    result = convert(stream.getvalue(), 'test.mid', {
        'tracks': [0], 'startMs': 0, 'endMs': 1000, 'compact': True})
    target.write_text(json.dumps(result), encoding='utf-8')


if __name__ == '__main__':
    main()
