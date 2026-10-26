"""将本次可维护RTL/测试复制到独立英文目录，保留输入SHA256，不覆盖原实现。"""
import argparse
import hashlib
import json
import shutil
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SUFFIXES = {'.v', '.sv', '.hex', '.tcl', '.py', '.ps1', '.cmd', '.gprj', '.cst', '.sdc', '.gao', '.do'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='本机记录JSON，非构建输出')
    parser.add_argument('--stage-parent', type=Path,
                        help='可写的纯英文隔离目录父路径；默认使用系统临时目录')
    args = parser.parse_args()
    if args.stage_parent:
        parent = args.stage_parent.resolve()
        if not str(parent).isascii():
            raise ValueError('隔离目录父路径必须为ASCII，避免EDA工具处理中文路径失败')
        parent.mkdir(parents=True, exist_ok=True)
    else:
        parent = None
    stage = Path(tempfile.mkdtemp(prefix='TangDirectScore_', dir=parent))
    if not str(stage).isascii():
        raise ValueError('系统临时目录含非ASCII字符，请使用英文用户名或TEMP目录后重试')
    inputs = []
    for folder in ('rtl', 'sim', 'scripts', 'full'):
        for source in sorted((ROOT / folder).rglob('*')):
            relative = source.relative_to(ROOT)
            if (not source.is_file() or source.suffix.lower() not in SUFFIXES or
                    any(part in {'impl', 'work', '__pycache__'} for part in relative.parts) or
                    relative.parts[:2] == ('full', 'rtl')):
                continue
            target = stage / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            inputs.append({'path': relative.as_posix(), 'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
    baseline = ROOT / 'verification/direct-score/baseline.json'
    if baseline.is_file():
        (stage / 'verification').mkdir(exist_ok=True)
        shutil.copy2(baseline, stage / 'verification/baseline.json')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'stage': str(stage), 'inputs': inputs}, indent=2), encoding='utf-8')
    print(stage)


if __name__ == '__main__':
    main()
