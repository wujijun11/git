from pathlib import Path
import faulthandler,hashlib,importlib.util,json,os,subprocess,sys
sys.stdout.reconfigure(encoding='utf-8',errors='replace')
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
spec=importlib.util.spec_from_file_location('localassets',ROOT/'desktop/native_host.py')
native=importlib.util.module_from_spec(spec);spec.loader.exec_module(native)
inputs={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'desktop/native_host.py',*sorted((ROOT/'desktop/web').glob('*'))] if p.is_file()}
faulthandler.enable();faulthandler.dump_traceback_later(15,exit=True)
assets=native.LocalAssets(ROOT/'desktop/web');faulthandler.cancel_dump_traceback_later()
try:
 env=dict(os.environ,TANG_UI_SMOKE_URL=assets.url)
 p=subprocess.run(['C:/Users/asus/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe',str(HERE/'test_diagnostic_ui.cjs')],cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=75)
 (HERE/'diagnostic-ui.log').write_text(p.stdout+p.stderr,encoding='utf-8');print(p.stdout+p.stderr)
 unchanged=all(hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest for name,digest in inputs.items())
 result=json.loads((HERE/'diagnostic-ui-result.json').read_text(encoding='utf-8'))
 result.update(sourceHashes=inputs,sourcesUnchanged=unchanged);(HERE/'diagnostic-ui-result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
 raise SystemExit(0 if p.returncode==0 and unchanged and result['accepted'] else 1)
finally:assets._close()
