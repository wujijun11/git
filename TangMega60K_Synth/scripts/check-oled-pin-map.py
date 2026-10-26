"""核对OLED新增GPIO及原理图映射，检查CST全局球位冲突，不替代实物导通测试。"""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    cst = ROOT / "full/contest_full.cst"
    text = cst.read_text(encoding="utf-8-sig")
    pins = {}
    owners = {}
    for signal, location in re.findall(r'^IO_LOC\s+"([^"]+)"\s+([^;]+);', text, re.MULTILINE):
        assert signal not in pins, f"Duplicate IO_LOC: {signal}"
        pads = re.findall(r"[A-Z]+\d+", location)
        pins[signal] = pads
        for pad in pads:
            assert pad not in owners, f"Pad {pad} used by {owners.get(pad)} and {signal}"
            owners[pad] = signal
    for signal, expected in (("oled_scl", "A20"), ("oled_sda", "B20")):
        assert pins.get(signal) == [expected], signal
        row = re.search(r'^IO_PORT\s+"' + signal + r'"\s+([^;]+);', text, re.MULTILINE)
        assert row and "IO_TYPE=LVCMOS33" in row[1] and "BANK_VCCIO=3.3" in row[1]
        assert "PULL_MODE=NONE" in row[1], "Use verified external 3.3V pullups"
    sources = {}
    for name in ("core30353_p1.png", "core30354_p1.png", "neo31005_p7.png", "neo31005_p19.png"):
        sources[name] = hashlib.sha256((ROOT / "hardware/wiring31005" / name).read_bytes()).hexdigest()
    print(json.dumps({"passed": True, "pins": {"oled_scl": "A20/J13-15", "oled_sda": "B20/J13-16"},
                      "tracedNets": ["C2399/J1-11 -> SDRAM0_D11 -> J13-15", "C2399/J1-13 -> SDRAM0_D10 -> J13-16"],
                      "cstPadsChecked": len(owners), "referenceImagesSha256": sources,
                      "mappingMethod": "manual trace of both 60K core schematics and 31005 dock pages 7/19",
                      "physicalContinuityMeasured": False}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
