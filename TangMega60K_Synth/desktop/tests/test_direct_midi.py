"""直接音高曲谱转换：保持全部音符，拒绝实际超限，不生成PCM。"""
import io
import sys
import unittest
from pathlib import Path
import mido

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from score_library.midi_import import convert


def example(chord=False, count=30):
    midi=mido.MidiFile(ticks_per_beat=480)
    track=mido.MidiTrack()
    midi.tracks.append(track)
    for n in range(count):
        track.append(mido.Message('note_on',note=n,velocity=100))
        if not chord:track.append(mido.Message('note_off',note=n,time=120))
    if chord:
        for n in range(count):track.append(mido.Message('note_off',note=n,time=120 if n==0 else 0))
    stream=io.BytesIO();midi.save(file=stream);return stream.getvalue()


class DirectMidiTests(unittest.TestCase):
    def test_all_128_pitches_are_preserved_without_key_mapping(self):
        result=convert(example(count=128),'all',{'tracks':[0],'direct':True,'compact':True})
        self.assertTrue(result['canUpload'])
        self.assertEqual(result['pitchCount'],128)
        self.assertEqual(result['peakPolyphony'],1)
        self.assertEqual(result['score']['version'],2)
        self.assertNotIn('mapping',result['score'])
        self.assertEqual([r['midi'] for r in result['score']['rows'][::2]],list(range(128)))
        self.assertTrue(all('key' not in r for r in result['score']['rows']))

    def test_legacy_still_rejects_more_than_25_and_does_not_discard_notes(self):
        result=convert(example(),'legacy',{'tracks':[0],'compact':True})
        self.assertFalse(result['canUpload'])
        self.assertEqual(result['eventCount'],60)

    def test_64_held_is_valid_but_65_is_rejected(self):
        for count in [64,65]:
            result=convert(example(chord=True,count=count),'chord',{'tracks':[0],'direct':True})
            self.assertEqual(result['canUpload'],count==64)
            self.assertEqual(result['peakPolyphony'],count)

    def test_capacity_still_applies_and_invalid_option_is_rejected(self):
        data=example(count=128)
        with self.assertRaises(ValueError):convert(data,'bad',{'tracks':[0],'direct':'yes'})
        # 257音的重复旋律在256事件旧容量下不可上传，不能截断。
        midi=mido.MidiFile(file=io.BytesIO(example(count=128)))
        midi.tracks[0].extend(midi.tracks[0][:-1])
        stream=io.BytesIO();midi.save(file=stream)
        result=convert(stream.getvalue(),'long',{'tracks':[0],'direct':True,'maxEvents':256})
        self.assertFalse(result['canUpload'])
        self.assertGreater(result['eventCount'],256)


if __name__=='__main__':unittest.main(verbosity=2)
