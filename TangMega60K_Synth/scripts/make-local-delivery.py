"""整理本地交付：核对实际构建源码/程序、复制产物、生成清单及源码包。

不执行Git提交、网络上传、FPGA下载或手机安装。临时工具、密钥和构建缓存不入包。
"""
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
import zipfile
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'delivery-mode-sync'


def sha(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest().upper()


def json_file(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def source_files():
    """只打包可维护工程；排除开发密钥、工具、日志缓存和生成程序。"""
    omitted = {'.git', 'tmp', 'verification', 'delivery', 'delivery-mode-sync', '__pycache__', '.gradle',
               'node_modules', 'impl', 'dist', 'output', 'build', '_recovery'}
    for path in sorted(ROOT.rglob('*')):
        relative = path.relative_to(ROOT)
        if not path.is_file() or any(part in omitted or part.startswith('delivery-') for part in relative.parts):
            continue
        if path.name in {'local.properties', 'license.dat'} or path.suffix.lower() in {'.lic', '.jks', '.keystore', '.pyc'}:
            continue
        if path.name.startswith('.env'):
            continue
        yield path, relative


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=OUTPUT)
    parser.add_argument('--desktop-evidence', type=Path, default=ROOT / 'verification/desktop/package-mode-sync')
    parser.add_argument('--apk-version', default='1.4')
    parser.add_argument('--with-ble', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    desktop_evidence = args.desktop_evidence.resolve()
    output.mkdir(exist_ok=True)
    evidence = ROOT / 'verification/mode-sync-frozen-build'
    build = json_file(evidence / 'build-results.json')
    if not build.get('buildAccepted'):
        raise RuntimeError('实际整机报告未通过，拒绝标记可交付')
    inputs = json_file(evidence / 'snapshot-inputs.json')
    mismatches = []
    for item in inputs:
        current = ROOT / item['path'].replace('\\', '/')
        expected = item.get('expectedSourceSha256', item['sha256'])
        if not current.is_file() or sha(current) != expected.upper():
            mismatches.append(item['path'])
    if mismatches:
        raise RuntimeError('现有构建输入与已验证快照不符：' + ', '.join(mismatches))
    fpga = output / 'fpga/ContestFull_ModeSync1024.fs'
    fpga.parent.mkdir(exist_ok=True)
    shutil.copy2(evidence / 'full/impl/pnr/ContestFull.fs', fpga)
    expected_fs = next(item['sha256'].upper() for item in build['current']['artifacts'] if item['path'].endswith('.fs'))
    if sha(fpga) != expected_fs:
        raise RuntimeError('复制的位流校验失败')
    apk = output / f'android/TangSynthRemote-{args.apk_version}-debug.apk'
    apk.parent.mkdir(exist_ok=True)
    shutil.copy2(ROOT / 'mobile/android/output/TangSynthRemote-debug.apk', apk)
    with zipfile.ZipFile(apk) as archive:
        for path in (ROOT / 'mobile/web').rglob('*'):
            if path.is_file():
                member = 'assets/' + path.relative_to(ROOT / 'mobile/web').as_posix()
                if hashlib.sha256(archive.read(member)).hexdigest().upper() != sha(path):
                    raise RuntimeError('APK界面资源与源码不一致：' + member)
    desktop = json_file(desktop_evidence / 'build-manifest.json')
    exe = output / 'windows/TangNeonStudio/TangNeonStudio.exe'
    if sha(exe) != desktop['exeSHA256']:
        raise RuntimeError('Windows程序与打包报告不符')
    for asset in desktop['webAssets']:
        if sha(ROOT / 'desktop/web' / asset['path']) != asset['sha256']:
            raise RuntimeError('Windows界面资源与打包报告不符：' + asset['path'])
    for source in desktop.get('pythonSources', []):
        if sha(ROOT / 'desktop' / source['path']) != source['sha256']:
            raise RuntimeError('Windows Python模块与打包报告不符：' + source['path'])
    cases = json_file(next((ROOT / 'verification/mode-sync-modelsim-english').glob('*/test-summary.json')))
    if not all(case['Passed'] for case in cases):
        raise RuntimeError('ModelSim存在失败项')
    queue = json_file(ROOT / ('verification/ble-latency/queue-test.json' if args.with_ble else 'verification/desktop/queue-mode-sync.json'))
    if not queue['accepted']:
        raise RuntimeError('实时琴键回归未通过')
    smoke = json_file(desktop_evidence / 'packaged-smoke-test.json')
    if not smoke['ok']:
        raise RuntimeError('Windows打包自检失败')
    manifest = {
        'date': datetime.now().astimezone().isoformat(),
        'sourceBaseCommit': '223ed7201f28a94d9738aca8eb815b06c287bcf6',
        'sourceLocation': str(ROOT),
        'sourceNote': '旧个人功能工作区的独立延续副本；旧工作区、旧程序和远端均未覆盖',
        'scoreEvents': 1024, 'recordEvents': 1024, 'sampleRate': 48000,
        'pcmBits': 24, 'i2sSlotBits': 32, 'audioClockHz': 49152000,
        'fpgaSourceInputsMatchPassedBuild': True,
        'fpgaBuildAccepted': True,
        'resources': build['current']['resources'],
        'minimumSlackNs': build['current']['minimumSlackNs'],
        'modelsimCasesPassed': len(cases), 'realtimeQueueCasesPassed': len(queue['cases']),
        'mobileMidi': json_file(ROOT / 'verification/mobile/midi-test-result.json'),
        'mobileUi': json_file(ROOT / 'verification/mobile/music-ui-result.json'),
        'actualBoardDownloaded': False, 'actualPhoneInstalled': False,
        'actualBleTestedThisDelivery': False, 'oledPinsAssigned': False,
        'normalShortNotesDiscarded': False,
        'c3CandidateFullCompileVerified': False,
        'modeSyncUi': json_file(ROOT / 'verification/mobile/mode-sync-ui.json'),
        'artifacts': [],
    }
    for path in [fpga, apk, exe]:
        manifest['artifacts'].append({'path': path.relative_to(output).as_posix(), 'bytes': path.stat().st_size, 'sha256': sha(path)})
    if args.with_ble:
        bridge = json_file(output / 'c3/build-manifest.json')
        if bridge['uploaded'] or bridge['exitCode'] != 0 or not bridge['bleLibrary']['selectionVerified']:
            raise RuntimeError('C3构建清单不符合本地仅编译交付')
        for entry in bridge['sourceFiles']:
            if sha(ROOT / 'firmware/ble_bridge' / entry['name']).lower() != entry['sha256'].lower():
                raise RuntimeError('C3源码与编译结果不符：' + entry['name'])
        for entry in bridge['libraryFiles']:
            if sha(ROOT / entry['path']).lower() != entry['sha256'].lower():
                raise RuntimeError('C3 BLE库与编译结果不符：' + entry['path'])
        manifest['c3CandidateFullCompileVerified'] = True
        manifest['c3HardwareValidated'] = False
        manifest['actualReadOnlyBaseline'] = json_file(ROOT / 'verification/ble-latency/live-fpga-ready.json')
        manifest['windowsPreferenceReadOnlyTrial'] = json_file(ROOT / 'verification/ble-latency/live-windows-fast.json')
        manifest['actualBleTestedThisDelivery'] = True
        manifest['userReportedFpgaDownloaded'] = True
        manifest['agentDownloadedFpgaOrC3'] = False
        manifest['actualBoardDownloaded'] = True
        manifest['optimizedC3Flashed'] = False
        manifest['audioLatencyMeasured'] = False
        for policy in ['desktop/ble_link.py','firmware/ble_bridge/bridge_link_policy.h','firmware/ble_bridge/bridge_notify_policy.h']:
            path = ROOT / policy
            manifest.setdefault('policySources', []).append({'path':policy,'sha256':sha(path)})
        for entry in bridge['artifacts']:
            path = output / 'c3' / entry['name']
            if sha(path).lower() != entry['sha256'].lower():
                raise RuntimeError('C3产物校验不符')
            manifest['artifacts'].append({'path': path.relative_to(output).as_posix(), 'bytes': path.stat().st_size, 'sha256': sha(path)})
    documentation = output / 'docs'
    documentation.mkdir(exist_ok=True)
    for name in ['滑条菜单与曲库交付_20261025.md', '资源核对与曲谱扩容评估_20261025.md', '手机版曲库与蓝牙按键说明_20261025.md', '模式同步与蓝牙延迟修正_20261025.md']:
        shutil.copy2(ROOT / 'docs' / name, documentation / name)
    if args.with_ble:
        shutil.copy2(ROOT / 'docs/蓝牙延迟优化与测量_20261025.md', documentation)
    source_zip = output / 'TangMega60K_Synth_Menu1024_source.zip'
    with zipfile.ZipFile(source_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path, relative in source_files():
            archive.write(path, 'TangMega60K_Synth/' + relative.as_posix())
    manifest['artifacts'].append({'path': source_zip.name, 'bytes': source_zip.stat().st_size, 'sha256': sha(source_zip)})
    (output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'output': str(output), 'buildInputsChecked': len(inputs), 'artifacts': manifest['artifacts']}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
