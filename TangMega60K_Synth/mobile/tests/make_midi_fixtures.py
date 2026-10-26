"""使用已验证的Windows转换器生成手机解析器交叉参考，不访问硬件或网络。"""
import io
import json
import sys
from pathlib import Path
import mido

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'desktop'))
from score_library.midi_import import convert, inspect_midi


def build_case(name, tracks, options=None):
    midi = mido.MidiFile(type=1, ticks_per_beat=480)
    for messages in tracks:
        track = mido.MidiTrack(messages)
        midi.tracks.append(track)
    out = io.BytesIO()
    midi.save(file=out)
    data = out.getvalue()
    info, _ = inspect_midi(data)
    settings = dict(tracks=list(range(len(tracks))), startMs=0,
                    endMs=max(1, info['durationMs']), mapping=list(range(60, 85)), maxEvents=1024)
    settings.update(options or {})
    return dict(name=name, bytes=list(data), options=settings,
                expected=convert(data, name, settings), info=info)


def main():
    msg = mido.Message
    meta = mido.MetaMessage
    melody = [msg('note_on', note=60, velocity=90), msg('note_off', note=60, time=480),
              msg('note_on', note=64, velocity=110), msg('note_on', note=64, velocity=0, time=480)]
    tempo = [meta('set_tempo', tempo=500000), meta('set_tempo', tempo=1000000, time=480), meta('end_of_track', time=480)]
    cases = [build_case('tempo', [tempo, melody]),
             build_case('segment-held', [melody], dict(startMs=100, endMs=600)),
             build_case('selected-track-tempo', [tempo, melody], dict(tracks=[1])),
             build_case('overlap', [melody, [msg('note_on', note=60, velocity=40), msg('note_off', note=60, time=240)]]),
             build_case('controls', [[msg('control_change', control=64, value=127), msg('pitchwheel'), *melody]]),
             build_case('mapping-missing', [[msg('note_on', note=40), msg('note_off', note=40, time=480)]]),
             build_case('compact', [[msg('note_on', note=40), msg('note_off', note=40, time=480)]], dict(compact=True)),
             build_case('drums', [[msg('note_on', channel=9, note=60), msg('note_off', channel=9, note=60, time=480)]])]
    many = []
    for _ in range(513):
        many.extend([msg('note_on', note=60, time=1), msg('note_off', note=60, time=1)])
    cases.append(build_case('over-capacity', [many]))
    all_pitches=[]
    for pitch in range(128):
        all_pitches.extend([msg('note_on',note=pitch,velocity=96),msg('note_off',note=pitch,time=120)])
    cases.append(build_case('direct-128-pitches',[all_pitches],dict(direct=True,compact=True)))
    for count in (64,65):
        chord=[msg('note_on',note=pitch,velocity=96) for pitch in range(count)]
        chord.extend(msg('note_off',note=pitch,time=120 if pitch==0 else 0) for pitch in range(count))
        cases.append(build_case(f'direct-{count}-held',[chord],dict(direct=True)))
    destination = ROOT / 'verification/mobile/midi-fixtures.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(cases, ensure_ascii=False), encoding='utf-8')
    print(f'Generated {len(cases)} independent mido/Windows reference cases: {destination}')


if __name__ == '__main__':
    main()
