"""Independent Python CRC/layout reference against the actual JS codec."""
import json
import os
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]

def crc8(data):
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ (7 if value & 128 else 0)) & 255
    return value

assert crc8(b"123456789") == 0xF4
js = """
const P=require('./web/protocol.js');
const rows=[];
for(let i=0;i<2000;i++)rows.push(Array.from(P.encode(i&255,(i*13)&255,Array.from({length:10},(_,j)=>(i*19+j*37)&255))));
process.stdout.write(JSON.stringify(rows));
"""
packets = json.loads(subprocess.check_output([os.environ.get("TANG_TEST_NODE", "node"), "-e", js], cwd=ROOT, text=True))
for i, packet in enumerate(packets):
    assert packet[:5] == [165,90,1,i&255,(i*13)&255]
    assert packet[5:15] == [(i*19+j*37)&255 for j in range(10)]
    assert packet[15] == crc8(packet[2:15]), (i, packet)
score = json.loads((ROOT / "examples/score.json").read_text(encoding="utf-8"))
assert score["version"] == 1 and len(score["rows"]) == 8
print("ALL PYTHON/JS PACKET PARITY TESTS PASSED (2000 independent vectors)")
