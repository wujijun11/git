"""将冻结源码清单和人工用途说明渲染成逐文件 Markdown 索引。

用途说明与自动清点分离：文件变动时必须补齐人工说明，不能靠文件名
自动宣称功能正确。只读取文档数据，不导入产品代码，不编译或连接硬件。
"""

import argparse
import collections
import json
from pathlib import Path
from urllib.parse import quote


def cell(value):
    """转义表格分隔符和换行，避免源码名称破坏文档布局。"""
    return str(value).replace('|', '\\|').replace('\n', ' ')


def file_link(path):
    return f'[{path}](../../{quote(path, safe="/")})'


def other_purpose(path):
    """非程序文件按用途分类；历史记录只说明性质，不推断其中结果有效。"""
    suffix = Path(path).suffix.lower()
    if path.startswith('verification/'):
        return '历史验证记录/固定输入/采集资料；对应版本和实际结果须看同目录清单。'
    if path.startswith('docs/reports/'):
        return '报告原始证据或摘要；按日期、候选和冻结输入核对，不能混作当前实测。'
    if path.startswith('docs/'):
        return '接口、算法、装配、使用或历史技术说明；日期早的说明可能不代表当前入口。'
    if path.startswith('releases/'):
        return '已归档发布包/清单/说明；不是默认正在编译的源码，需匹配版本。'
    if suffix == '.gprj':
        return 'Gowin工程入口：列出器件与输入文件；具体顶层由配套构建脚本指定。'
    if suffix == '.cst':
        return '物理引脚和I/O电平约束；须对应此工程的实物接线。'
    if suffix == '.sdc':
        return '时钟、生成时钟和时序约束；不是通过缩短文档数字提高硬件速度。'
    if suffix == '.rao':
        return 'GAO片内逻辑分析仪配置；启用会影响资源与布局，须区分调试/发布构建。'
    if suffix == '.hex':
        rom = {
            'waves': '数学周期波形查表数据', 'midi': '128个MIDI音高的频率控制字',
            'velocity': '力度到幅度的曲线', 'piano': '原钢琴数学查表数据',
            'sine': '正弦波表', 'ratio': '弯音/颤音的音高比例查表',
            'polar_lane0': '八成分钢琴偶数通道的分段幅度/相位参数',
            'polar_lane1': '八成分钢琴奇数通道的分段幅度/相位参数',
            'polar_ratios': '八成分非整数谐波频率比例',
            'menu_font': 'OLED中文/符号字模',
            'goertzel_1024_64': '64个Goertzel显示频点系数',
        }
        return rom.get(Path(path).stem, 'ROM或检查数据，具体读入者见配套HDL/脚本') + '；HDL初始化输入，不等于整段录音。'
    if path.startswith('firmware/libraries/'):
        return '第三方BLE库的许可、来源、构建描述或完整性清单；须保留。'
    if path.startswith('assets/audio/'):
        return '音色离线拟合参数、参考来源或授权说明；不可据此宣称实时播放原始PCM。'
    if path.startswith('licenses/'):
        return '第三方素材/字体授权与来源，提交源码时随相关素材保留。'
    if suffix in {'.epro2', '.eprj3', '.epcb', '.epcb2', '.esch', '.esch2', '.epan', '.epan2', '.ecfg'}:
        return '嘉立创EDA原生硬件设计/项目配置；不是Gowin输入，需原生DRC和实物装配验收。'
    if path.startswith('hardware/'):
        return '硬件几何/网络/器件清单、预览、制造导出或检查资料；按子目录README使用。'
    if suffix in {'.png', '.jpg', '.jpeg', '.svg'}:
        return '示意、波形或界面图片；需区分预览/仿真和真实实物照片。'
    if suffix == '.xml' and path.startswith('mobile/android/'):
        return 'Android权限、资源或备份策略配置，配合原生Java和Gradle打包。'
    if path.endswith('requirements.txt'):
        return 'Python依赖与版本清单。'
    if path.endswith('README.md'):
        return '所在模块的入口、用法与验证边界说明。'
    if Path(path).name in {'.gitignore', '.gitattributes'}:
        return 'Git忽略/文本属性规则，控制缓存、生成物与换行处理。'
    return '配套配置/数据/说明；结合所属目录使用，不作为独立可执行功能。'


def render(directory):
    catalog = json.loads((directory / '源码清单.json').read_text(encoding='utf-8'))
    roles = json.loads((directory / '文件用途.json').read_text(encoding='utf-8'))
    archive_roles = json.loads((directory / '归档文件用途.json').read_text(encoding='utf-8'))
    code = [item for item in catalog['files'] if item['isCode']]
    expected = {item['path'] for item in code}
    if set(roles) != expected:
        raise ValueError(f'用途说明覆盖不一致：缺少{sorted(expected - set(roles))}；多余{sorted(set(roles) - expected)}')
    archive = [item for item in catalog['files'] if item.get('isArchiveCode')]
    if set(archive_roles) != {item['path'] for item in archive}:
        raise ValueError('归档代码/HTML报告的用途说明覆盖不一致')
    groups = collections.defaultdict(list)
    for item in code:
        groups[item['category']].append(item)
    lines = [
        '# 源码逐文件说明', '', '[返回阅读入口](README.md)', '',
        f'冻结版本：`{catalog["sourceRevision"]}`。开发源码区共{len(code)}个代码文件，'
        f'{catalog["codeLineCount"]}行；行数包含第三方库、测试和导出副本，不能当作原创代码量。', '',
        '用途基于本次源码阅读和静态关系；“有测试文件”不等于“本轮执行并通过”。'
        '主工程静态可达包含generate条件分支，综合后可能裁剪；例如audio_fx内部支路在完整工程被关闭。', '',
        '文件链接指向当前工作区；若以后修改代码，需切回上述冻结版本才能与本索引逐字对应。', '',
        f'另有{len(archive)}项带代码扩展名的归档快照、测试脚本和生成HTML报告，文末逐一解释；'
        '它们不混入520项开发源码统计，不遗漏其文件路径。', '',
        '| 分类 | 文件数 |', '|---|---:|',
    ]
    lines.extend(f'| {cell(name)} | {len(items)} |' for name, items in groups.items())
    for name, items in groups.items():
        lines.extend(['', f'## {name}', '', '| 文件 | 行数 | 用途 |', '|---|---:|---|'])
        for item in items:
            path = item['path']
            lines.append(f'| {file_link(path)} | {item["lines"]} | {cell(roles[path])} |')
    lines.extend(['', '## 归档快照、运行脚本与生成HTML报告', '',
                  '下列文件来自docs/reports、verification或releases，保留当次版本；'
                  '重复快照不是另一套同时运行的引擎，生成HTML报告也不算原创应用。', '',
                  '| 文件 | 用途 |', '|---|---|'])
    lines.extend(f'| {file_link(item["path"])} | {cell(archive_roles[item["path"]])} |' for item in archive)
    lines.extend(['', '## 本轮新增文档工具（不计入冻结基线520项）', '',
        f'- {file_link("scripts/catalog-submission-sources.py")}：读取明确Git提交、清点哈希和静态模块关系。',
        f'- {file_link("scripts/render-source-guide.py")}：核对用途覆盖并生成本索引与其他文件索引。',
        '- `文件用途.json`和`归档文件用途.json`：人工维护的职责；`源码清单.json`：机器清点结果。', ''])
    (directory / '源码逐文件说明.md').write_text('\n'.join(lines), encoding='utf-8')
    other = [item for item in catalog['files'] if not item['isCode']]
    lines = ['# 其他工程文件索引', '', '[返回阅读入口](README.md)', '',
             f'补充列出冻结版本的{len(other)}个配套/归档文件，与520个开发源码文件合计1654项；'
             f'其中{len(archive)}项归档代码/HTML报告另在源码逐文件说明文末详列。'
             '报告、图像、压缩包、ROM和约束不是同一种文件；此表按用途分类，不代替报告内容审查。', '',
             '| 文件 | 用途 |', '|---|---|']
    lines.extend(f'| {file_link(item["path"])} | {cell(archive_roles.get(item["path"], other_purpose(item["path"]))) } |' for item in other)
    (directory / '其他工程文件索引.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    lines = ['# 主工程模块连接索引', '', '[返回阅读入口](README.md)', '',
             '下表仅列从board_contest_full_top静态遍历到的已知RTL模块。'
             '不展开generate参数、不统计实例复制数量、不含外部厂商原语；因此不能拿表长当资源或振荡器数量。', '',
             '| 模块 | 定义文件 | 直接实例化的模块（实例名） |', '|---|---|---|']
    for name, item in sorted(catalog['modules'].items()):
        if not item['reachable']:
            continue
        children = '；'.join(f'{value["module"]}（{value["instance"]}）' for value in item['instances']) or '无本清单可识别的子模块'
        lines.append(f'| `{name}` | {file_link(item["file"])} | {cell(children)} |')
    (directory / '主工程模块连接索引.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return {'codeFilesExplained': len(code), 'archiveFilesExplained': len(archive), 'otherFilesIndexed': len(other)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, required=True, help='清单与用途JSON所在目录')
    args = parser.parse_args()
    print(json.dumps(render(args.directory), ensure_ascii=True))


if __name__ == '__main__':
    main()
