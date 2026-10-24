"""Package an explicitly selected FPGA build, APK and C3 firmware after hash checks.

This accepts isolated build snapshots, so an old full/impl cannot silently be
exported after a source change. It does not flash hardware or upload anything.
"""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import shutil
import uuid
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
CORE_NAMES = set(('full_system global_panic control_router expression_merge note_arbiter runtime_fx '
    'runtime_fx_storage remote_note_watchdog audio_visualizer audio_monitor_cdc watchdog_arbiter '
    'mpr121_i2c mpr121_frontend mpr121_backpressure mpr121_timing mpr121_capacity performance '
    'performance_retrigger performance_commit board_local_actions ws2812_waveform ws2812_matrix '
    'remote_uart video_encoder video_timing video_vendor audio_units audio_engine_n4 audio_i2s '
    'ws2812_reject_zero ws2812_reject_large ws2812_reject_map ws2812_reject_duplicate').split())


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def local(root, relative):
    relative = str(relative).replace('\\', '/')
    path = (root / relative).resolve()
    require(path.is_relative_to(root.resolve()), 'Path leaves root: ' + relative)
    return path


def same_file(path, expected):
    require(path.is_file() and sha(path) == expected.lower(), 'Missing or changed file: ' + str(path))


def validate(build_root, core_root, phone_manifest):
    records = []
    metadata = {}
    def read_metadata(path):
        data = path.read_bytes()
        metadata[path] = hashlib.sha256(data).hexdigest()
        return json.loads(data.decode('utf-8-sig'))
    build = read_metadata(build_root / 'build-results.json')
    require(build.get('buildAccepted') and build.get('protectedImplUnchanged'), 'FPGA build not accepted')
    physical = build['current']
    require(not any(physical['violations'].values()) and min(physical['minimumSlackNs'].values()) > 0, 'FPGA timing failed')
    for entry in read_metadata(build_root / 'snapshot-inputs.json'):
        same_file(local(PROJECT, entry['path']), entry['sha256'])
    pnr = build_root / 'full/impl/pnr'
    names = {'ContestFull.fs', 'ContestFull.tr', 'ContestFull.rpt.txt'}
    found = set()
    for artifact in physical['artifacts']:
        name = Path(artifact['path']).name
        if name in names:
            source = pnr / name
            same_file(source, artifact['sha256'])
            records.append((source, 'fpga/' + name, artifact['sha256'].lower()))
            found.add(name)
    require(found == names, 'FPGA artifact catalog incomplete')
    timing = (pnr / 'ContestFull.tr').read_text(encoding='utf-8-sig')
    for kind in ['Setup', 'Hold']:
        match = re.search(r'<Numbers of ' + kind + r' Violated Endpoints>:\s*(\d+)', timing)
        require(match is not None and int(match[1]) == 0, 'Actual STA fails ' + kind)
    records += [(build_root / 'build-results.json', 'evidence/fpga-build-results.json', metadata[build_root / 'build-results.json']),
                (build_root / 'snapshot-inputs.json', 'evidence/fpga-source-inputs.json', metadata[build_root / 'snapshot-inputs.json'])]

    core = read_metadata(core_root / 'manifest.json')
    rows = read_metadata(core_root / 'test-summary.json')
    require(core.get('Suite') == 'Core' and core.get('Status') == 'Passed' and core.get('Passed') and core.get('Compiled')
            and not core.get('InfrastructureError') and core.get('InputsUnchanged')
            and core.get('PassedCases') == 33 and not core.get('FailedCases'), 'Core33 not complete')
    require(len(rows) == 33 and len({x['Name'] for x in rows}) == 33 and all(x['Passed'] for x in rows), 'Core33 summary incomplete')
    require({x['Name'] for x in rows} == CORE_NAMES and set(core['SelectedCaseNames']) == CORE_NAMES
            and len(core['SelectedCaseNames']) == 33 and core['Cases'] == rows, 'Core33 case catalog differs')
    for row in rows:
        require(not row['TimedOut'] and not row['Failure'], 'Core33 case failed: ' + row['Name'])
        log_path = local(core_root, row['Log'])
        log_bytes = log_path.read_bytes()
        transcript = log_bytes.decode('utf-8-sig', errors='replace')
        fatals = re.findall(r'^\s*#?\s*\*\*\s+Fatal[^\r\n]*', transcript, re.M | re.I)
        errors = re.findall(r'^\s*#?\s*\*\*\s+Error(?:\s|:)[^\r\n]*', transcript, re.M | re.I)
        expected_rejection = row['Name'].startswith('ws2812_reject_')
        require(row['ExpectedRejection'] == expected_rejection and not errors, 'Core33 rejection kind differs')
        if expected_rejection:
            require(row['ExitCode'] in (0, 1) and len(fatals) == 1 and row['ExpectedFatal']
                and fatals[0].strip().endswith('Fatal: ' + row['ExpectedFatal'])
                and re.search(r'\bTime:\s*0\s+(?:fs|ps|ns|us|ms|sec|s)\b', transcript)
                and ('Instance: /' + row['Top'] + '/dut') in transcript
                and 'PARAMETER_NOT_REJECTED' not in transcript, 'Core33 DUT rejection missing: ' + row['Name'])
        else:
            require(row['ExitCode'] == 0 and not fatals and row['ExpectedMarker']
                and row['ExpectedMarker'] in transcript and not re.search(r'\bErrors:\s*[1-9][0-9]*', transcript),
                'Core33 PASS marker missing: ' + row['Name'])
        records.append((log_path, 'evidence/core-logs/' + row['Name'] + '.log', hashlib.sha256(log_bytes).hexdigest()))
    for item in read_metadata(core_root / 'inputs.json'):
        if item['Kind'] != 'Vendor':
            same_file(local(PROJECT, item['StagedPath']), item['Sha256Before'])
    records += [(core_root / 'manifest.json', 'evidence/core-manifest.json', metadata[core_root / 'manifest.json']),
                (core_root / 'test-summary.json', 'evidence/core-summary.json', metadata[core_root / 'test-summary.json']),
                (core_root / 'inputs.json', 'evidence/core-inputs.json', metadata[core_root / 'inputs.json'])]

    phone = read_metadata(phone_manifest)
    require(phone.get('Accepted') and phone.get('InputsUnchanged') and phone.get('SignatureV1V2Verified'), 'Phone verification not accepted')
    require(phone['Lint']['Errors'] == phone['Lint']['Warnings'] == 0, 'Android lint is not clean')
    require(phone['SourcesBefore'] == phone['SourcesAfter'], 'Phone source changed during build')
    # Adding a new Java/resource/asset file must invalidate an old APK even
    # when every previously cataloged file still has exactly the same bytes.
    source_files = list((PROJECT / 'mobile/web').rglob('*'))
    source_files += list((PROJECT / 'mobile/android/app/src').rglob('*'))
    source_files += list((PROJECT / 'mobile/tests').glob('test_*'))
    fixed_inputs = {'mobile/android/build.gradle', 'mobile/android/settings.gradle',
        'mobile/android/app/build.gradle', 'mobile/android/tools/bootstrap.py',
        'scripts/build-android.ps1', 'scripts/test-remote-mobile.ps1'}
    actual_phone_inputs = {x.relative_to(PROJECT).as_posix() for x in source_files if x.is_file()} | fixed_inputs
    def is_phone_input(name):
        return (name.startswith(('mobile/web/', 'mobile/android/app/src/')) or
                (name.startswith('mobile/tests/test_') and '/' not in name.removeprefix('mobile/tests/')) or
                name in fixed_inputs)
    cataloged_phone_inputs = {x for x in phone['SourcesAfter'] if is_phone_input(x)}
    require(actual_phone_inputs == cataloged_phone_inputs, 'Phone source file set changed')
    for name, expected in phone['SourcesAfter'].items():
        same_file(local(PROJECT, name), expected)
    apk = local(PROJECT, phone['Apk']['Path'])
    same_file(apk, phone['Apk']['Sha256'])
    require(apk.stat().st_size == phone['Apk']['Bytes'], 'APK size differs')
    actual_assets = {x.relative_to(PROJECT / 'mobile/web').as_posix() for x in (PROJECT / 'mobile/web').rglob('*') if x.is_file()}
    require(actual_assets == {x['Path'] for x in phone['PackagedAssets']}, 'Phone asset file set changed')
    with zipfile.ZipFile(apk) as package:
        for asset in phone['PackagedAssets']:
            source = local(PROJECT / 'mobile/web', asset['Path'])
            same_file(source, asset['Sha256'])
            require(package.read('assets/' + asset['Path']) == source.read_bytes(), 'APK contains stale asset: ' + asset['Path'])
    records += [(apk, 'phone/' + apk.name, phone['Apk']['Sha256'].lower()), (phone_manifest, 'evidence/phone-delivery-manifest.json', metadata[phone_manifest])]

    bridge_root = PROJECT / 'firmware/ble_bridge'
    bridge_manifest = bridge_root / 'output/build-manifest.json'
    bridge = read_metadata(bridge_manifest)
    require(bridge.get('exitCode') == 0 and bridge.get('core') == 'esp32:esp32@3.3.5'
            and bridge.get('fqbn') == 'esp32:esp32:waveshare_esp32_c3_zero:CDCOnBoot=default,FlashSize=4M', 'C3 target or compile result is invalid')
    expected_sources = {x['name'] for x in bridge['sourceFiles']}
    actual_sources = {x.name for x in bridge_root.iterdir() if x.is_file() and x.suffix in {'.ino', '.h', '.hpp', '.c', '.cpp'}}
    require(expected_sources == actual_sources, 'C3 source file set changed')
    for source in bridge['sourceFiles']:
        require(Path(source['name']).name == source['name'], 'Invalid C3 source name')
        same_file(bridge_root / source['name'], source['sha256'])
    required_bins = {'ble_bridge.ino.bin', 'ble_bridge.ino.bootloader.bin', 'ble_bridge.ino.partitions.bin', 'ble_bridge.ino.merged.bin'}
    found = set()
    for artifact in bridge['artifacts']:
        require(Path(artifact['name']).name == artifact['name'], 'Invalid C3 artifact name')
        source = bridge_root / 'output' / artifact['name']
        same_file(source, artifact['sha256'])
        if artifact['name'] in required_bins:
            records.append((source, 'c3/' + artifact['name'], artifact['sha256'].lower()))
            found.add(artifact['name'])
    require(found == required_bins, 'C3 flash artifacts incomplete')
    records.append((bridge_manifest, 'evidence/c3-build-manifest.json', metadata[bridge_manifest]))
    for path, expected in metadata.items():
        same_file(path, expected)
    return records, physical['minimumSlackNs'], phone['Apk']['Sha256']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fpga-build', type=Path, required=True)
    parser.add_argument('--core-run', type=Path, required=True)
    parser.add_argument('--phone-manifest', type=Path, required=True)
    parser.add_argument('--output-root', type=Path, default=PROJECT / 'release')
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args()
    records, timing, apk_sha = validate(args.fpga_build.resolve(), args.core_run.resolve(), args.phone_manifest.resolve())
    if args.validate_only:
        print(json.dumps({'accepted': True, 'selectedFiles': len(records), 'minimumSlackNs': timing, 'apkSha256': apk_sha}))
        return 0
    output_root = args.output_root.resolve()
    require(output_root.is_relative_to(PROJECT / 'release'), 'Output must remain under the local release directory')
    folder = output_root / ('verified_' + dt.datetime.now().strftime('%Y%m%d_%H%M%S') + '_' + uuid.uuid4().hex[:8])
    folder.mkdir(parents=True, exist_ok=False)
    files = []
    for source, relative, expected in records:
        same_file(source, expected)
        destination = local(folder, relative)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        require(sha(destination) == expected == sha(source), 'File changed while copied: ' + str(source))
        files.append({'path': relative, 'bytes': destination.stat().st_size, 'sha256': expected})
    # Check all source fingerprints again after packaging; a concurrent edit
    # must not produce a success manifest for mismatched binaries.
    refreshed = validate(args.fpga_build.resolve(), args.core_run.resolve(), args.phone_manifest.resolve())
    require(refreshed == (records, timing, apk_sha), 'Verified inputs changed during packaging')
    note = ('# 本次受验交付\n\n'
            'FPGA文件在fpga/，手机APK在phone/，微雪ESP32-C3-Zero固件在c3/。\n\n'
            'FPGA请选择本包ContestFull.fs；原工程full/impl可能是旧产物。\n'
            'C3的merged.bin是完整4MB闪存镜像（起始0x0）；单独应用bin不能按0x0直接烧录。\n'
            '烧录前应确认开发板型号、供电与接线；本工具未进行任何硬件下载。\n\n'
            '当前Setup/Hold余量(ns)：' + str(timing['setup']) + '/' + str(timing['hold']) + '。\n'
            '附带的是构建和数字回归证据；手机射频、触摸/LED/音频实物验收仍待执行。\n')
    (folder / 'README.md').write_text(note, encoding='utf-8')
    manifest = {'createdAt': dt.datetime.now().astimezone().isoformat(), 'accepted': True,
        'sourceProject': str(PROJECT), 'fpgaBuild': str(args.fpga_build.resolve()),
        'coreRun': str(args.core_run.resolve()), 'phoneManifest': str(args.phone_manifest.resolve()),
        'hardwareProgrammedOrValidated': False, 'minimumSlackNs': timing, 'files': files}
    (folder / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    archive = folder.with_suffix('.zip')
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED) as package:
        for path in sorted(folder.rglob('*')):
            if path.is_file():
                package.write(path, path.relative_to(folder).as_posix())
    with zipfile.ZipFile(archive) as package:
        for item in files:
            require(hashlib.sha256(package.read(item['path'])).hexdigest() == item['sha256'],
                    'Archive content mismatch: ' + item['path'])
    print(json.dumps({'accepted': True, 'folder': str(folder), 'archive': str(archive), 'archiveSHA256': sha(archive), 'files': len(files)}, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
