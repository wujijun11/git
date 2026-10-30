"""生成分层菜单独立字模与渲染器，保留旧menu_font.hex和旧字符编号。"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
TITLES = ['连续表情','总菜单','声音设置','音色选择','音区选择','音效选择','表情选择','录制回放','曲谱指引','延音设置']
ITEMS = ['','声音表情录放曲谱','音色音区音效返回','钢琴风琴正弦FM',
         '低2低1标准高1','关闭延迟混响合唱','音量弯音颤音复位','开始结束回放停止','播放停止指引学习','关闭开启返回主页']
LABELS = ['音量控制','弯音控制','颤音控制','音量 000%','弯音+0000','深度 000%',
          '错误','请等待','录制中','播放中','指引中','事件数','长按左端选模式','音分松手回零','百分比调节深度','长按右端回音量','-',
          '延音关闭','延音开启','音色音区音效延音']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('font_gzip', type=Path)
    args = parser.parse_args()
    old = json.loads((ROOT/'licenses/menu-font/manifest.json').read_text(encoding='utf-8'))
    source_sha = hashlib.sha256(args.font_gzip.read_bytes()).hexdigest()
    if source_sha != old['sourceSha256']:
        raise ValueError('原始字体与既有授权记录哈希不一致')
    # 追加字形，保留已验F571的既有编号与像素；仍校验同一OFL原字体。
    previous = ROOT/'licenses/menu-hierarchy-font/manifest.json'
    chars = list(json.loads(previous.read_text(encoding='utf-8'))['glyphs']) if previous.exists() else list(old['glyphs'])
    for char in ''.join(TITLES+ITEMS+LABELS):
        if char not in chars:
            chars.append(char)
    if len(chars)>128:
        raise ValueError('字模超过7位编号')
    ids = {char:index for index,char in enumerate(chars)}
    spec = importlib.util.spec_from_file_location('legacy_font_generator', ROOT/'scripts/generate-menu-font.py')
    legacy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(legacy)
    glyphs = legacy.extract_glyphs(args.font_gzip,chars)
    depth = (1 << (len(chars)-1).bit_length())*32
    data = [byte for char in chars for byte in glyphs[char]]
    data += [0]*(depth-len(data))
    (ROOT/'rtl/audio/rom/menu_hierarchy_font.hex').write_text(''.join(f'{byte:02X}\n' for byte in data),encoding='ascii')
    license_dir = ROOT/'licenses/menu-hierarchy-font'
    license_dir.mkdir(parents=True,exist_ok=True)
    for name in ('COPYING','OFL-1.1.txt'):
        shutil.copy2(ROOT/'licenses/menu-font'/name,license_dir/name)
    (license_dir/'manifest.json').write_text(json.dumps({**old,'font':'HierarchyMenuGlyphSubset',
        'glyphs':ids,'romBytes':depth},ensure_ascii=False,indent=2),encoding='utf-8')
    def packed(value):
        if len(value)>8:
            raise ValueError(value)
        number=sum(ids[c] << (7*i) for i,c in enumerate(value.ljust(8)))
        return f"56'h{number:014x}"
    template = (ROOT/'scripts/templates/oled_hierarchy_renderer.v.in').read_text(encoding='utf-8')
    for i,text in enumerate(TITLES):
        template = template.replace(f'@TITLE{i}@',packed(text))
    for i,text in enumerate(ITEMS):
        template = template.replace(f'@ITEM{i}@',packed(text))
    for i,text in enumerate(LABELS):
        template = template.replace(f'@LABEL{i}@',packed(text))
    template = template.replace('@ZERO@',str(ids['0'])).replace('@PLUS@',str(ids['+']))
    template = template.replace('@MINUS@',str(ids['-'])).replace('@DEPTH@',str(depth))
    if '@' in template.replace('always @','always '):
        raise ValueError('渲染模板仍有未替换标记')
    (ROOT/'rtl/visual/oled_hierarchy_renderer.v').write_text(template,encoding='utf-8')
    print(json.dumps({'glyphs':len(chars),'romBytes':depth,'legacyFontUnchanged':True}))


if __name__=='__main__':
    main()
