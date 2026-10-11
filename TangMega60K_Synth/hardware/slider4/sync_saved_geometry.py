"""Update only native object bodies in a closed, previously imported LCEDA PCB.

Retain project/document/object IDs so the local eprj3 references stay valid.
The generator's exchange file remains independently importable.
"""
from pathlib import Path
import json

ROOT = Path(__file__).parent
NAME = 'Touch25_Slider4_100x20_R1'
TARGET = ROOT / (NAME + '_Final') / 'pcb' / (NAME + '.epcb2')

def read(path):
    return [tuple(json.loads(x) for x in s.removesuffix('|').split('||'))
            for s in path.read_text(encoding='utf-8').splitlines() if s]

source = read(ROOT / (NAME + '.epru'))
source = source[next(i for i, (h, b) in enumerate(source)
                     if h['type'] == 'DOCHEAD' and b['docType'] == 'PCB'):]
target = read(TARGET)
assert len(source) == len(target), (len(source), len(target))
changed = []
for i, ((sh, sb), (th, tb)) in enumerate(zip(source, target)):
    assert sh['type'] == th['type'], (i, sh['type'], th['type'])
    if sh['type'] not in ('DOCHEAD', 'META') and sb != tb:
        assert sh['type'] in ('FILL', 'LINE'), (i, sh['type'])
        target[i] = (th, sb)
        changed.append({'record': i, 'kind': sh['type'], 'net': sb['netName']})
assert len(changed) in (0, 8), changed
compact = lambda x: json.dumps(x, ensure_ascii=False, separators=(',', ':'))
TARGET.write_text('|\n'.join(compact(h) + '||' + compact(b)
                             for h, b in target), encoding='utf-8')
print(json.dumps({'updated': str(TARGET), 'geometry_changes': changed}))
