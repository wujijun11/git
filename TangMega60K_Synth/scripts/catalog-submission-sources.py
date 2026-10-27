"""只读清点冻结Git版本的源码与主工程模块关系，供作品说明文档引用。

不编译/下载，不执行被检查的源码，不改RTL、约束、ROM、客户端或硬件设计。
可达关系是静态实例解析，不能替代综合器的参数裁剪和资源报告。
"""
import argparse
import ast
import collections
import hashlib
import json
import posixpath
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CODE_EXTENSIONS = {
    '.v', '.sv', '.ino', '.cpp', '.h', '.c', '.py', '.js', '.cjs', '.java',
    '.ps1', '.cmd', '.tcl', '.do', '.html', '.css', '.gradle',
}
EXCLUDED_PREFIXES = ('verification/', 'docs/', 'releases/')


def git(*arguments):
    """Git只用于读取明确版本，不做切换、拉取、提交或上传。"""
    return subprocess.check_output(['git', *arguments], cwd=ROOT)


def frozen_files(revision):
    """批量读取 Git blob，保留中文/空格路径，不混入工作区修改。"""
    prefix = git('rev-parse', '--show-prefix').decode().strip()
    entries = []
    for record in git('ls-tree', '-r', '-z', '--full-tree', revision).split(b'\0'):
        if not record:
            continue
        metadata, raw_path = record.split(b'\t', 1)
        _, kind, object_id = metadata.split()
        path = raw_path.decode('utf-8')
        if kind == b'blob' and path.startswith(prefix):
            entries.append((path[len(prefix):], object_id))
    if not entries:
        raise ValueError('指定提交中没有本工程文件')
    request = b''.join(object_id + b'\n' for _, object_id in entries)
    blobs = subprocess.check_output(
        ['git', 'cat-file', '--batch'], cwd=ROOT, input=request,
    )
    cursor = 0
    result = {}
    for path, object_id in entries:
        end = blobs.index(b'\n', cursor)
        actual_id, kind, size = blobs[cursor:end].split()
        if actual_id != object_id or kind != b'blob':
            raise ValueError(f'读取 Git 对象失败：{path}')
        cursor = end + 1
        size = int(size)
        result[path] = blobs[cursor:cursor + size]
        cursor += size + 1
    return result


def strip_hdl_comments(text):
    # 先保留换行地清理注释，再跳过字符串，防止把注释/ROM文件名当成实例。
    return re.sub(
        r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"',
        lambda match: '\n' * match.group().count('\n'), text, flags=re.S,
    )


def skip_balanced(text, start):
    depth = 0
    for index in range(start, len(text)):
        if text[index] == '(':
            depth += 1
        elif text[index] == ')':
            depth -= 1
            if depth == 0:
                return index + 1
    raise ValueError('HDL实例参数括号没有闭合')


def modules_from_sources(sources):
    """分析已知RTL模块的直接实例；不展开generate或厂商原语。"""
    modules = {}
    for path, text in sources.items():
        if Path(path).suffix not in {'.v', '.sv'} or not path.startswith('rtl/'):
            continue
        cleaned = strip_hdl_comments(text)
        for match in re.finditer(r'\bmodule\s+(\w+)\b(.*?)\bendmodule\b', cleaned, re.S):
            name = match[1]
            if name in modules:
                raise ValueError(f'重复RTL模块名：{name}')
            modules[name] = {'file': path, 'body': match[2], 'instances': []}
    known = '|'.join(sorted(map(re.escape, modules), key=len, reverse=True))
    pattern = re.compile(r'\b(' + known + r')\b\s*(#\s*)?')
    for module in modules.values():
        for match in pattern.finditer(module['body']):
            cursor = match.end()
            if match[2]:
                if cursor >= len(module['body']) or module['body'][cursor] != '(':
                    continue
                cursor = skip_balanced(module['body'], cursor)
            instance = re.match(r'\s*(\w+)\s*\(', module['body'][cursor:])
            if instance:
                module['instances'].append({'module': match[1], 'instance': instance[1]})
    return modules


def category(path, reachable_files):
    if path.startswith('firmware/libraries/'):
        return '第三方BLE库（含本地修正）'
    if path == 'rtl/clock/pll_init.v':
        return '厂商PLL初始化IP'
    if path.startswith('rtl/'):
        return '完整顶层静态可达RTL' if path in reachable_files else '其他RTL/独立入口'
    groups = (
        ('desktop/tests/', 'Windows测试'), ('desktop/', 'Windows应用'),
        ('mobile/tests/', '手机测试'), ('mobile/', '手机应用/构建'),
        ('firmware/', 'C3固件/测试'), ('scripts/', '构建/验证/离线生成工具'),
        ('sim/', 'HDL仿真/冻结参考'), ('hardware/', '硬件CAD工具或导出副本'),
        ('examples/', '接入示例'),
    )
    for prefix, label in groups:
        if path.startswith(prefix):
            return label
    return '独立工程或IP配套脚本'


def inspect_source(path, text):
    """读取用途线索和顶层定义；遇到无法解析的Python只记线索，不执行它。"""
    lines = text.splitlines()
    header = [line.strip() for line in lines[:30]
              if line.strip().startswith(('//', '#', '/*', '*', '<!--', '"""', "'''"))][:5]
    definitions = []
    if Path(path).suffix == '.py':
        try:
            tree = ast.parse(text)
            doc = ast.get_docstring(tree)
            if doc:
                header.insert(0, doc[:500])
            definitions = [node.name for node in tree.body
                           if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))]
        except SyntaxError:
            pass
    else:
        definitions = re.findall(r'\b(?:module|class|function)\s+(\w+)', strip_hdl_comments(text))
    return {'lines': len(lines), 'purposeHints': header[:5], 'definitions': definitions[:30]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', default='603a417', help='冻结的作品源码版本')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    revision = git('rev-parse', args.revision + '^{commit}').decode().strip()
    frozen = frozen_files(revision)
    sources = {}
    inventory = []
    for path, raw in sorted(frozen.items()):
        has_code_suffix = Path(path).suffix.lower() in CODE_EXTENSIONS
        is_code = has_code_suffix and not path.startswith(EXCLUDED_PREFIXES)
        item = {'path': path, 'bytes': len(raw),
                'sha256': hashlib.sha256(raw).hexdigest().upper(),
                'isCode': is_code, 'isArchiveCode': has_code_suffix and not is_code}
        if has_code_suffix:
            source_text = raw.decode('utf-8-sig', errors='replace')
            item.update(inspect_source(path, source_text))
            if is_code:
                sources[path] = source_text
        inventory.append(item)
    project = ET.fromstring(frozen['full/ContestFull.gprj'])
    listed = []
    for element in project.findall('./FileList/File'):
        if element.get('type') == 'file.verilog' and element.get('enable') == '1':
            path = posixpath.normpath('full/' + element.get('path'))
            if path not in frozen:
                raise FileNotFoundError(f'主工程缺少输入：{path}')
            listed.append(path)
    modules = modules_from_sources(sources)
    active = set()
    pending = ['board_contest_full_top']
    while pending:
        name = pending.pop()
        if name in active:
            continue
        active.add(name)
        pending.extend(item['module'] for item in modules[name]['instances'])
    reachable_files = {modules[name]['file'] for name in active}
    for item in inventory:
        if item['isCode']:
            item['category'] = category(item['path'], reachable_files)
    args.output.mkdir(parents=True, exist_ok=True)
    graph = {name: {'file': info['file'], 'instances': info['instances'], 'reachable': name in active}
             for name, info in modules.items()}
    result = {
        'sourceRevision': revision, 'sourceVersion': 'slider-volume local test; hardware not verified',
        'trackedFileCount': len(inventory), 'codeFileCount': len(sources),
        'archiveCodeSuffixFileCount': sum(item['isArchiveCode'] for item in inventory),
        'codeLineCount': sum(item.get('lines', 0) for item in inventory if item['isCode']),
        'mainProjectListedFiles': listed, 'staticReachableModuleCount': len(active),
        'staticReachableFileCount': len(reachable_files), 'staticReachableFiles': sorted(reachable_files),
        'categories': dict(collections.Counter(item['category'] for item in inventory if item['isCode'])),
        'method': '冻结Git对象与静态实例关系；包含条件分支，不等于综合后模块/资源或逐文件验收',
        'files': inventory, 'modules': graph,
    }
    (args.output / '源码清单.json').write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8',
    )
    keys = ('sourceRevision', 'trackedFileCount', 'codeFileCount', 'archiveCodeSuffixFileCount',
            'staticReachableModuleCount', 'staticReachableFileCount', 'categories')
    print(json.dumps({key: result[key] for key in keys}, ensure_ascii=True))


if __name__ == '__main__':
    main()
