"""Validate the first-version passive interconnect map.

This deliberately checks the safety boundaries that are easy to break when
turning the interface definition into an EasyEDA schematic/PCB.  It does not
claim that connector footprints or mechanical orientation have been verified.
"""
from __future__ import annotations

import csv
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAP = HERE / "connector_map.csv"


def load_rows():
    with MAP.open(newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def main() -> int:
    rows = load_rows()
    by_pin = {(r["connector"], int(r["pin"])): r for r in rows}
    errors: list[str] = []

    # Used FPGA J13 positions are intentionally limited to the documented
    # interface slice; J13-11 must remain an explicit no-connect.
    for pin in range(1, 15):
        if ("J_FPGA_J13", pin) not in by_pin:
            errors.append(f"missing J_FPGA_J13 pin {pin}")
    if by_pin.get(("J_FPGA_J13", 11), {}).get("net") != "NC_5V":
        errors.append("J13-11 is not marked NC_5V")

    # C3 is a crossed UART at the FPGA side.
    expected_c3 = {1: "C3_TX7_TO_FPGA_RX", 2: "C3_RX6_FROM_FPGA_TX", 3: "GND"}
    for pin, net in expected_c3.items():
        if by_pin.get(("J_C3", pin), {}).get("net") != net:
            errors.append(f"J_C3.{pin} must be {net}")

    # Each MPR bus must stay separate and all ADD pins use address 0x5A.
    for n in (1, 2, 3):
        if by_pin.get((f"J_MPR{n}", 3), {}).get("net") != "GND":
            errors.append(f"J_MPR{n}.3 ADD must be GND")
        for pin, suffix in ((4, "SCL"), (5, "SDA")):
            net = by_pin.get((f"J_MPR{n}", pin), {}).get("net")
            if net != f"MPR{n}_{suffix}":
                errors.append(f"J_MPR{n}.{pin} must be MPR{n}_{suffix}")

    # 5V auxiliary power may only terminate at the AHCT side and the external
    # power connector.  This catches accidental backfeed into FPGA/MPR/C3.
    for (connector, pin), row in by_pin.items():
        if row["net"] == "LED_5V_AUX" and connector not in {"J_AHCT", "J_LED_PWR"}:
            errors.append(f"LED_5V_AUX appears on {connector}.{pin}")
        if row["voltage"] == "5V" and connector in {"J_FPGA_J13", "J_PWR_3V3", "J_C3"}:
            if not (connector == "J_FPGA_J13" and pin == 11 and row["net"] == "NC_5V"):
                errors.append(f"unexpected 5V on {connector}.{pin}")

    if errors:
        for error in errors:
            print(f"FAIL: {error}")
        return 1

    print(f"PASS: {len(rows)} mapped pins; J13-11 NC; C3 UART crossed; MPR buses isolated; 5V_AUX bounded")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
