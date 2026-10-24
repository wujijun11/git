"""Package the reviewed native project and unchanged manufacturing exports.

Does not place a manufacturing order or modify the live EDA project.
"""
import hashlib
import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SOURCE = Path('C:/Users/asus/Documents/LCEDA-Pro/projects/AHCT125-LED-R1')
RELEASE = ROOT / 'release'
NATIVE = RELEASE / 'project' / 'AHCT125-LED-R1'
ZIP = ROOT / '74AHCT125_LED_R1_带元件生产资料_20261018.zip'


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy(source, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)
    assert sha256(source) == sha256(dest), dest


def stage_design():
    for name in [
        'AHCT125-LED-R1.eprj3', 'sch/Schematic1/P1.esch2',
        'sch/Schematic1/Schematic1.ecfg', 'pcb/PCB1.epcb2',
        'panel/Panel1.epan2',
    ]:
        copy(SOURCE / name, NATIVE / name)
    for name in [
        'Gerber_AHCT125_LED_R1.zip',
        'BOM_AHCT125_LED_R1.xlsx', 'CPL_AHCT125_LED_R1.xlsx',
        'BOM_AHCT125_LED_R1.csv', 'CPL_AHCT125_LED_R1.csv',
        'Assembly_AHCT125_LED_R1.html', 'PCB_AHCT125_LED_R1.pdf',
        'AHCT125_LED_R1.net',
    ]:
        copy(SOURCE / name, RELEASE / 'production' / name)
    for source_name, target_name in [
        ('pcb-check.png', 'PCB.png'), ('schematic.png', 'Schematic.png'),
    ]:
        copy(SOURCE / source_name, RELEASE / 'preview' / target_name)


def finish():
    # Copy final instructions and only the successful, reviewed check records.
    for name in ['README.md', 'assembly_order_notes.md']:
        copy(ROOT / name, RELEASE / name)
    for name in [
        'schematic_review.md', 'footprint_review.md',
        'manufacturing_review.md', 'manufacturing_review.json',
        'layout_review.md', 'fixed-ground-geometry.json',
        'independent-ground-check.json', 'check_ground_connectivity.py',
    ]:
        copy(ROOT / 'verification' / name, RELEASE / 'verification' / name)
    for name in ['sch-check.json', 'pcb-check-ground-contours.json',
                 'release-reopen-check.json']:
        data = json.loads((ROOT / 'references' / name).read_text(encoding='utf-8-sig'))
        assert data['ok'] is True, name
        # Keep bulky netlist only in its native .net file.
        if name == 'sch-check.json':
            assert data['value']['passed'] is True
            data['value'].pop('net', None)
        elif name == 'pcb-check-ground-contours.json':
            assert data['value']['passed'] is True
        else:
            assert data['value']['schematicPassed'] is True
            assert data['value']['pcbPassed'] is True
            assert data['value']['components'] == 9
        dest = RELEASE / 'verification' / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    # The locked copper is editable source; include the generator and its audit
    # input for maintainers, with dependencies/usage explained in README.
    copy(ROOT / 'generate_ground_plane.py', RELEASE / 'generate_ground_plane.py')
    copy(ROOT / 'references' / 'critical-layout.json',
         RELEASE / 'references' / 'critical-layout.json')
    # Remove only the two paths created by the earlier packaging layout.
    for relative in ['maintenance/generate_ground_plane.py',
                     'maintenance/references/critical-layout.json']:
        old = RELEASE / relative
        if old.is_file():
            old.unlink()
    (RELEASE / 'maintenance' / 'README.md').write_text('''# 固定地铜维护说明

交付 PCB 的底层地铜为141个锁定 FILL；这不是会自动避让的 POUR。
更改铜层几何后必须重新生成地铜、打开原生编辑器运行 DRC、核对 Gerber，并重新导出制造文件。

根目录 `generate_ground_plane.py` 是本次生成所用脚本，依赖 Python 和 Shapely 2.2.0。
维护时先关闭此项目的 EDA 会话，再将脚本中的 `PROJECT` 改为实际工程目录；
用原生 API 重新采集当前元件焊盘坐标，更新根目录的
`references/critical-layout.json`。不能在改过布局后直接使用本次坐标快照。

独立只读审查脚本在 `verification/check_ground_connectivity.py`。
复跑时也需将其中 `PROJECT` 和 `GERBER` 路径改为当前工程及导出文件的位置。

该生成器仅针对本次“全部 SMD 位于顶层”的设计。增加底层 SMD、
新增底层铜形状、改板框或改走线时，应扩展相应阻挡几何，不能直接运行就当作完成检查。
0.30mm 为目标避让参数，最终间距以原生 DRC 和制造审核为准。
''', encoding='utf-8')
    manifest = {
        'revision': 'AHCT125-LED-R1', 'date': '2026-10-18',
        'board_mm': [40, 30], 'assembled_component_count': 9,
        'assembly': {'smd': 5, 'through_hole': 4},
        'validation': 'Native SCH/PCB DRC and manufacturing file consistency checks passed.',
        'prototype_status': 'Not fabricated, assembled, or physically tested.',
        'panel_status': 'Single-board exports. Factory panel design/approval required.',
        'files': [
            {'path': p.relative_to(RELEASE).as_posix(), 'bytes': p.stat().st_size,
             'sha256': sha256(p)}
            for p in sorted(RELEASE.rglob('*'))
            if p.is_file() and p.name != 'manifest.json'
        ],
    }
    (RELEASE / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    with zipfile.ZipFile(ZIP, 'w', zipfile.ZIP_DEFLATED, compresslevel=7) as archive:
        for p in sorted(RELEASE.rglob('*')):
            if p.is_file():
                archive.write(p, Path('74AHCT125_LED_R1') / p.relative_to(RELEASE))
    with zipfile.ZipFile(ZIP) as archive:
        assert archive.testzip() is None
        for entry in manifest['files']:
            contents = archive.read('74AHCT125_LED_R1/' + entry['path'])
            assert hashlib.sha256(contents).hexdigest() == entry['sha256']
    print(json.dumps({'zip': str(ZIP), 'bytes': ZIP.stat().st_size,
                      'sha256': sha256(ZIP), 'files': len(manifest['files'])+1}, ensure_ascii=False))


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('phase', choices=['stage', 'finish'])
    args = parser.parse_args()
    if args.phase == 'stage':
        stage_design()
        print(json.dumps({'native_project': str(NATIVE / 'AHCT125-LED-R1.eprj3')}, ensure_ascii=False))
    else:
        finish()
