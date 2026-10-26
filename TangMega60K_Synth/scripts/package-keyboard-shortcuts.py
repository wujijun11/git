"""整理电脑快捷键交付：核对程序/源码/界面测试，保留其他交付不覆盖。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import zipfile

ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'delivery-keyboard-shortcuts'


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source,'sha256').hexdigest().upper()


def read(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    evidence=ROOT/'verification/keyboard-shortcuts'
    manifest=read(evidence/'package/build-manifest.json')
    smoke=read(evidence/'package/packaged-smoke-test.json')
    ui=read(evidence/'ui-result.json')
    if not smoke['ok'] or smoke['checks'].get('preferences')!='ok' or ui['pageErrors']:
        raise RuntimeError('打包自检或快捷键界面验证未通过')
    exe=OUTPUT/'windows/TangNeonStudio/TangNeonStudio.exe'
    if digest(exe)!=manifest['exeSHA256']:
        raise RuntimeError('Windows程序校验不符')
    for source in manifest['webAssets']+manifest['pythonSources']:
        path=ROOT/'desktop'/('web' if source in manifest['webAssets'] else '')/source['path']
        if digest(path)!=source['sha256']:
            raise RuntimeError('源码与交付程序不一致：'+str(path))
    doc=ROOT/'docs/电脑快捷键与滑条操作_20261025.md'
    shutil.copy2(doc,OUTPUT/doc.name)
    spec=importlib.util.spec_from_file_location('delivery_helpers',ROOT/'scripts/make-local-delivery.py')
    helpers=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helpers)
    archive=OUTPUT/'TangMega60K_Synth_shortcuts_source.zip'
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as package:
        for path,relative in helpers.source_files():
            package.write(path,'TangMega60K_Synth/'+relative.as_posix())
    result={'feature':'电脑快捷键自定义','changedHardware':False,'requiresFpgaOrC3Download':False,
            'settings':'%LOCALAPPDATA%/TangNeonStudio/preferences/keyboard-shortcuts.json',
            'scope':'仅更新电脑客户端，原低延迟连接、模式同步、MIDI与曲库保留',
            'ui':ui,'packageSmoke':smoke,'desktopBuildManifest':manifest,
            'artifacts':[{'path':str(path.relative_to(OUTPUT)),'bytes':path.stat().st_size,'sha256':digest(path)}
                         for path in [exe,doc if doc.is_relative_to(OUTPUT) else OUTPUT/doc.name,archive]]}
    (OUTPUT/'manifest.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps({'output':str(OUTPUT),'artifacts':result['artifacts']},ensure_ascii=False,indent=2))


if __name__=='__main__':
    main()
