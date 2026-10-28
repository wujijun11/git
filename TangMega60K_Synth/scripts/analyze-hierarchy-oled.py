"""按可读菜单文字独立核对渲染器12帧数据；预览来自仿真，不代表实屏。"""
import argparse
import csv
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TITLES = ['', '总菜单', '声音设置', '音色选择', '音区选择', '音效选择', '表情选择', '录制回放', '曲谱指引']
ITEMS = ['', '声音表情录放曲谱', '音色音区音效返回', '钢琴风琴正弦FM',
         '低2低1标准高1', '关闭延迟混响合唱', '音量弯音颤音复位', '开始结束回放停止', '播放停止指引学习']


def expected_byte(row, ids, font):
    view, mode, page, column = (row[k] for k in ('view','mode','page','column'))
    line = page//2
    if view==0:
        lines = [ ['音量控制','弯音控制','颤音控制'][mode],
                  f"弯音{'-' if row['negative'] else '+'}{row['value']:04d}" if mode==1
                  else f"{'音量' if mode==0 else '深度'} {row['value']:03d}%",
                  '', ['长按左端选模式','音分松手回零','百分比调节深度'][mode] ]
        if line==2:
            percent = max(0,min(100,row['percent']))
            if column in (4,123):
                return 7 if page%2 else 252
            if 4<column<123:
                fill = 6<=column<=121 and (column-6)*100<percent*116
                return (7 if fill else 4) if page%2 else (252 if fill else 4)
            return 0
    else:
        lines = [TITLES[view],ITEMS[view],'事件数 0012','长按右端回音量']
    text = lines[line].ljust(8)
    value = font[ids[text[column//16]]*32 + (page%2)*16 + column%16]
    if view!=0 and line==1 and column//32==row['zone']:
        value ^= 255
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture',type=Path)
    parser.add_argument('output',type=Path)
    args = parser.parse_args()
    manifest = json.loads((ROOT/'licenses/menu-hierarchy-font/manifest.json').read_text(encoding='utf-8'))
    font_path = ROOT/'rtl/audio/rom/menu_hierarchy_font.hex'
    font = [int(x,16) for x in font_path.read_text(encoding='ascii').split()]
    frames = {}
    for raw in csv.DictReader(args.capture.open(encoding='ascii')):
        row = {key:int(value) for key,value in raw.items()}
        number = row['frame']
        frame = frames.setdefault(number,{})
        index = row['page']*128+row['column']
        if index in frame:
            raise ValueError(f'重复像素：frame={number} index={index}')
        expected = expected_byte(row,manifest['glyphs'],font)
        if row['data'] != expected:
            raise ValueError(f'文字/单位/高亮/刻度不符：{row}, expected={expected}')
        frame[index]=row['data']
    if len(frames)!=12 or any(set(frame)!=set(range(1024)) for frame in frames.values()):
        raise ValueError('需要12个完整的128x64帧')
    args.output.mkdir(parents=True,exist_ok=True)
    spec = importlib.util.spec_from_file_location('wave_preview',ROOT/'scripts/analyze-oled-wave.py')
    preview = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(preview)
    for number in (0,1,2,3,4,5,6,7,8,9,10):
        preview.render([frames[number][i] for i in range(1024)],args.output/f'menu_{number:02d}.png')
    result = {'passed':True,'frames':12,'bytesCompared':12288,'hardwareTested':False,
              'captureSHA256':hashlib.sha256(args.capture.read_bytes()).hexdigest().upper(),
              'fontSHA256':hashlib.sha256(font_path.read_bytes()).hexdigest().upper(),
              'checks':['四类主菜单','声音三级菜单','四种音效','表情四项','带符号弯音音分','颤音百分比','音量百分比','区域预览高亮','控制刻度']}
    (args.output/'analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(result,ensure_ascii=False))


if __name__=='__main__':
    main()
