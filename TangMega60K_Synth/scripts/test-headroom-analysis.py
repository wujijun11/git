"""分析器的合成夹具检查；不代表HDL或板卡测试。"""
import copy
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('headroom_analysis', Path(__file__).with_name('analyze-headroom-smoothing.py'))
analysis = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analysis)
fixture = [{
    'frame': 1, 'tag': 1, 'old_l': 128000, 'old_r': -128000,
    'new_l': 128000, 'new_r': -128000, 'active': 1, 'shift': 6,
    'gain_q10': 65536, 'master_gain': 2048, 'raw_l': 1000, 'raw_r': -1000, 'guard': 0,
}, {
    'frame': 2, 'tag': 2, 'old_l': 64000, 'old_r': -64000,
    'new_l': 127000, 'new_r': -127000, 'active': 2, 'shift': 5,
    'gain_q10': 65024, 'master_gain': 2048, 'raw_l': 1000, 'raw_r': -1000, 'guard': 0,
}]
result = analysis.analyze(fixture)
assert result['transitions'][0]['oldGainChangeContribution'] == 64000
assert result['transitions'][0]['newGainChangeContribution'] == 1000
for field, value in [('frame', 7), ('new_l', 127002), ('gain_q10', 70000), ('guard', 1)]:
    invalid = copy.deepcopy(fixture)
    invalid[1][field] = value
    try:
        analysis.analyze(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError('must reject invalid ' + field)
print('HEADROOM ANALYZER PASS independent fixture, counterfactual gain contribution, corrupt PCM and frame rejection; no hardware')
