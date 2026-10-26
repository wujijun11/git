"""核对推荐曲库客户端、APK资源和测试记录后生成独立交付，不触碰硬件。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import zipfile

ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'delivery-recommendations'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source,'sha256').hexdigest().upper()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    evidence=ROOT/'verification/recommendations'
    build=read(evidence/'package/build-manifest.json')
    smoke=read(evidence/'package/packaged-smoke-test.json')
    ui=read(evidence/'ui-result.json')
    live=read(evidence/'live-result.json')
    if not smoke['ok'] or smoke['checks'].get('score_library.recommendations')!='ok' or ui['pageErrors']:
        raise RuntimeError('推荐打包/界面测试尚未通过')
    exe=OUTPUT/'windows/TangNeonStudio/TangNeonStudio.exe'
    if digest(exe)!=build['exeSHA256']:
        raise RuntimeError('Windows程序校验不符')
    for asset in build['webAssets']:
        if digest(ROOT/'desktop/web'/asset['path'])!=asset['sha256']:
            raise RuntimeError('Windows界面资源不同步：'+asset['path'])
    for source in build['pythonSources']:
        if digest(ROOT/'desktop'/source['path'])!=source['sha256']:
            raise RuntimeError('Windows源码不同步：'+source['path'])
    apk=OUTPUT/'android/TangSynthRemote-1.6-debug.apk'
    apk.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(ROOT/'mobile/android/output/TangSynthRemote-debug.apk',apk)
    with zipfile.ZipFile(apk) as package:
        for path in (ROOT/'mobile/web').rglob('*'):
            if path.is_file():
                member='assets/'+path.relative_to(ROOT/'mobile/web').as_posix()
                if hashlib.sha256(package.read(member)).hexdigest().upper()!=digest(path):
                    raise RuntimeError('APK界面资源与源码不同步：'+member)
    docs=OUTPUT/'docs'
    docs.mkdir(exist_ok=True)
    for name in ['推荐曲目与刷新_20261025.md','电脑快捷键与滑条操作_20261025.md','蓝牙延迟优化与测量_20261025.md']:
        shutil.copy2(ROOT/'docs'/name,docs/name)
    spec=importlib.util.spec_from_file_location('delivery_helpers',ROOT/'scripts/make-local-delivery.py')
    helper=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    archive=OUTPUT/'TangMega60K_Synth_recommendations_source.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as package:
        for path,relative in helper.source_files():
            package.write(path,'TangMega60K_Synth/'+relative.as_posix())
    report={'feature':'曲库推荐、换一批及联网刷新','changedHardware':False,'requiresFpgaOrC3Download':False,
            'windowsPreservesCustomShortcuts':True,'androidVersion':'1.6','ui':ui,
            'liveCatalog':{'firstCount':len(live['first']['items']),'nextCount':len(live['next']['items']),
                           'different':live['firstVsNextDifferent'],'cachedRead':live['cachedRead'],
                           'downloadedAndInspected':len(live['downloadedFileInspection'])},
            'hardwareAccessedThisFeature':False,'packageSmoke':smoke,'desktopBuildManifest':build,
            'artifacts':[{'path':path.relative_to(OUTPUT).as_posix(),'bytes':path.stat().st_size,'sha256':digest(path)}
                         for path in [exe,apk,archive]]}
    (OUTPUT/'manifest.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'output':str(OUTPUT),'artifacts':report['artifacts']},ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
