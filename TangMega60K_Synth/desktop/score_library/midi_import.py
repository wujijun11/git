"""标准MIDI文件转为V1/V2现有曲谱事件，不生成或保存PCM。

全曲保留在电脑；用户明确选择音轨和时间片段后才转换。新版硬件最多1024事件、
键位模式最多25种音高；直接模式保存MIDI音高，不修改键位。超过事件或复音限制返回错误。
"""
import io
from collections import Counter
import mido

MAX_MESSAGES = 200000


def inspect_midi(data):
    if len(data) > 4 * 1024 * 1024:
        raise ValueError("MIDI必须小于4MiB")
    midi = mido.MidiFile(file=io.BytesIO(data))
    if midi.type == 2 or midi.ticks_per_beat <= 0:
        raise ValueError("暂不支持异步Type 2或SMPTE时间格式；请另存为Type 0/1 MIDI")
    if len(midi.tracks) > 128 or sum(map(len, midi.tracks)) > MAX_MESSAGES:
        raise ValueError("MIDI过于复杂：最多128音轨、20万消息")
    messages, tracks = [], []
    for index, track in enumerate(midi.tracks):
        tick = 0
        count = 0
        for order, message in enumerate(track):
            tick += message.time
            messages.append((tick, index, order, message))
            count += message.type == "note_on" and message.velocity > 0
        tracks.append({"index": index, "name": track.name or f"音轨 {index + 1}", "notes": count})
    messages.sort(key=lambda item: item[:3])
    # 全部音轨的速度事件都参与时间换算，单独选择旋律轨也不会丢失速度变化。
    tempo, previous_tick, seconds = 500000, 0, 0.0
    timed = []
    for tick, track, _, message in messages:
        seconds += mido.tick2second(tick - previous_tick, midi.ticks_per_beat, tempo)
        previous_tick = tick
        timed.append((round(seconds * 1000), track, message))
        if message.type == "set_tempo":
            tempo = message.tempo
    return {"tracks": tracks, "durationMs": round(seconds * 1000)}, timed


def convert(data, title, options, attribution=None):
    info, timed = inspect_midi(data)
    max_events = options.get("maxEvents", 1024)
    realtime = options.get("realtime", False)
    if type(realtime) is not bool:
        raise ValueError("实时播放选项必须为布尔值")
    direct = options.get("direct", False)
    if type(direct) is not bool:
        raise ValueError("直接播放选项必须为布尔值")
    if type(max_events) is not int or max_events not in (256, 1024):
        raise ValueError("曲谱容量应选择旧版256或新版1024")
    # 实时曲谱保存在上位机，不占FPGA的1024行RAM；仍限制解析规模与时长。
    direct = direct or realtime
    if realtime:
        max_events = 100000
    selected = options.get("tracks")
    valid_tracks = {track["index"] for track in info["tracks"]}
    if not isinstance(selected, list) or not selected or any(type(t) is not int or t not in valid_tracks for t in selected):
        raise ValueError("请选择至少一个有效音轨")
    start, end = options.get("startMs", 0), options.get("endMs", info["durationMs"])
    if type(start) is not int or type(end) is not int or not 0 <= start < end <= max(1, info["durationMs"]):
        raise ValueError("片段时间应满足：0 ≤ 开始 < 结束 ≤ 曲目总时长，单位毫秒")
    if realtime and end - start > 6 * 60 * 60 * 1000:
        raise ValueError("实时曲谱最长6小时")
    key_mapping = options.get("mapping", list(range(60, 85)))
    if (not isinstance(key_mapping, list) or len(key_mapping) != 25 or
            any(type(n) is not int or not 0 <= n <= 127 for n in key_mapping)):
        raise ValueError("键位映射必须为25个0–127整数")
    held = Counter()
    pitch_count = Counter()
    pitch_velocity = {}
    warnings = set()
    output = []
    opened = False

    def seed():
        nonlocal opened
        if not opened:
            output.extend((0, pitch, pitch_velocity[pitch], 1) for pitch, count in sorted(pitch_count.items()) if count)
            opened = True

    for time_ms, track, message in timed:
        if track not in selected:
            continue
        if time_ms >= start:
            seed()
        if time_ms >= end:
            break
        if message.type in ("control_change", "pitchwheel", "aftertouch", "polytouch", "sysex"):
            warnings.add("踏板、弯音、触后及其他控制消息未导入，只导入音符与力度")
        if message.type not in ("note_on", "note_off"):
            continue
        if message.channel == 9:
            warnings.add("含打击乐通道，将用当前乐器音色演奏其音高；可取消该音轨")
        identity = (track, message.channel, message.note)
        old = pitch_count[message.note]
        is_on = message.type == "note_on" and message.velocity > 0
        if is_on:
            pitch_velocity[message.note] = message.velocity
            held[identity] += 1
            pitch_count[message.note] += 1
            if old:
                warnings.add("相同音高重叠已合并为一个键位，不能保留各声部原音色")
            if time_ms >= start and not old:
                output.append((time_ms - start, message.note, message.velocity, 1))
        elif held[identity]:
            held[identity] -= 1
            pitch_count[message.note] -= 1
            if time_ms >= start and pitch_count[message.note] == 0:
                output.append((time_ms - start, message.note, 0, 0))
    seed()
    # 片段结束显式释放所有仍然按住的键，避免截取曲谱产生悬挂音。
    output.extend((end - start, pitch, 0, 0) for pitch, count in sorted(pitch_count.items()) if count)
    pitches = sorted({event[1] for event in output})
    errors = []
    compact = options.get("compact", False)
    if compact and not direct:
        if len(pitches) > 25:
            errors.append(f"片段含{len(pitches)}种音高，超出25键映射；请选择更短片段或较少音轨")
        else:
            key_mapping = (pitches + [n for n in range(60, 85) if n not in pitches] +
                           [n for n in range(128) if n not in pitches])[:25]
            warnings.add("上传时将重新设置25个实体琴键的音高；曲谱播放前请把滑条音区设为标准")
    missing = [pitch for pitch in pitches if pitch not in key_mapping]
    if missing and not direct:
        errors.append("以下MIDI音高不在当前25键映射：" + ", ".join(map(str, missing)))
    if not output:
        errors.append("所选片段没有可演奏音符")
    if len(output) > max_events:
        errors.append(f"片段需要{len(output)}条事件，当前播放方式最多{max_events}条；请选择更短片段")
    active_pitches = set()
    peak_polyphony = 0
    for _, pitch, _, on in output:
        if on:
            active_pitches.add(pitch)
        else:
            active_pitches.discard(pitch)
        peak_polyphony = max(peak_polyphony, len(active_pitches))
    if direct:
        warnings.add("蓝牙实时播放：播放期间保持连接和上位机前台运行，不改键位，不提供逐键灯光指引；密集和弦受传输速度限制" if realtime else
                     "脱离25键直接播放：需新版FPGA支持，使用板上当前音色，不改实体键位，不提供逐键灯光指引")
        warnings.add("与手动演奏共用64声部，释放尾音也占声部；密集片段可能达到上限")
        if peak_polyphony > 64:
            errors.append(f"片段同时按住{peak_polyphony}个音，超过64声部；请选择较少音轨")
    rows, previous = [], 0
    for time_ms, pitch, velocity, on in output:
        rows.append({"deltaMs": time_ms - previous, **({"midi": pitch} if direct else {"key": key_mapping.index(pitch) if pitch in key_mapping else 0}),
                     "velocity": velocity, "on": on})
        previous = time_ms
    doc = {"version": 2 if direct else 1, "title": str(title)[:120], "rows": rows,
           "attribution": attribution or {}, "segment": {"startMs": start, "endMs": end, "tracks": selected}}
    if direct:
        doc["playback"] = "direct"
        if realtime:
            doc["transport"] = "realtime"
    else:
        doc["mapping"] = key_mapping
    return {"score": doc, "canUpload": not errors and not realtime, "canStream": not errors and realtime,
            "maxEvents": max_events, "errors": errors, "warnings": sorted(warnings),
            "eventCount": len(rows), "pitchCount": len(pitches), "peakPolyphony": peak_polyphony, "durationMs": end - start,
            "pianoRoll": [{"ms": t, "midi": n, "velocity": v, "on": on} for t, n, v, on in output]}
