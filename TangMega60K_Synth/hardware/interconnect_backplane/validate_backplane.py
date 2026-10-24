"""Check electrical consistency of the passive backplane interface definition.

This is not a PCB DRC or proof of physical plug compatibility.  Module pin
order, connector orientation, footprints and mounting geometry remain subject
to verification against the actual hardware.
"""
from __future__ import annotations

import csv
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAP = HERE / "connector_map.csv"
SPEC = HERE / "backplane_spec.json"


def load_rows():
    with MAP.open(newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def validate(rows, spec):
    """Return errors without silently discarding duplicate or malformed pins."""
    errors: list[str] = []
    by_pin = {}
    for line, row in enumerate(rows, 2):
        try:
            connector = row["connector"].strip()
            pin = int(row["pin"])
            if not connector or pin < 1 or str(pin) != row["pin"].strip():
                raise ValueError("connector and positive integer pin required")
            for field in ("silkscreen", "net", "source", "voltage"):
                if not row[field] or not row[field].strip():
                    raise ValueError(f"empty {field}")
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(f"CSV line {line}: {exc}")
            continue
        key = connector, pin
        if key in by_pin:
            errors.append(f"duplicate connector/pin {connector}.{pin}")
            continue
        by_pin[key] = row

    expected = {
        "J_FPGA_J13": {
            1: "MPR1_SCL", 2: "MPR1_SDA", 3: "MPR2_SCL", 4: "MPR2_SDA",
            5: "MPR3_SCL", 6: "MPR3_SDA", 7: "C3_TX7_TO_FPGA_RX",
            8: "C3_RX6_FROM_FPGA_TX", 9: "MPR1_IRQ", 10: "MPR2_IRQ",
            11: "NC_5V", 12: "GND", 13: "MPR3_IRQ", 14: "LED_DATA_3V3",
        },
        "J_PWR_3V3": {1: "3V3_MPR", 2: "GND"},
        "J_C3": {1: "C3_TX7_TO_FPGA_RX", 2: "C3_RX6_FROM_FPGA_TX", 3: "GND"},
        "J_AHCT": {1: "LED_DATA_3V3", 2: "GND"},
        "J_AHCT_PWR": {1: "LED_5V_AUX", 2: "GND"},
        "J_LED_PWR": {1: "LED_5V_AUX", 2: "GND"},
    }
    for n in (1, 2, 3):
        expected[f"J_MPR{n}"] = {
            1: "3V3_MPR", 2: "GND", 3: "GND", 4: f"MPR{n}_SCL",
            5: f"MPR{n}_SDA", 6: f"MPR{n}_IRQ",
        }

    required = {(connector, pin): net for connector, pins in expected.items()
                for pin, net in pins.items()}
    for (connector, pin), net in required.items():
        actual = by_pin.get((connector, pin), {}).get("net")
        if actual != net:
            errors.append(f"{connector}.{pin}: expected {net}, got {actual!r}")

    # All 40 J13 contacts must be accounted for, including the unused ones.
    nc_pins = {11, *range(15, 41)}
    required_nc = {f"J_FPGA_J13.{pin}" for pin in nc_pins}
    nc_list = spec.get("doNotConnect", [])
    if not isinstance(nc_list, list) or any(not isinstance(x, str) for x in nc_list):
        errors.append("spec.doNotConnect must be a list of pin names")
        nc_list = []
    duplicates = [pin for pin, count in Counter(nc_list).items() if count > 1]
    if duplicates:
        errors.append(f"duplicate spec.doNotConnect entries: {duplicates}")
    if set(nc_list) != required_nc:
        errors.append(f"spec.doNotConnect mismatch: missing {sorted(required_nc - set(nc_list))}; "
                      f"unexpected {sorted(set(nc_list) - required_nc)}")

    members = defaultdict(set)
    for (connector, pin), row in by_pin.items():
        net = row["net"]
        members[net].add((connector, pin))
        if (connector, pin) not in required:
            if connector != "J_FPGA_J13" or pin not in nc_pins:
                errors.append(f"unexpected connector/pin {connector}.{pin}")
            elif not net.startswith("NC"):
                errors.append(f"unused J13 pin {pin} must be NC, got {net}")
        wanted_voltage = "0V" if net == "GND" else (
            "5V" if net in {"LED_5V_AUX", "NC_5V"} else "3.3V")
        if not net.startswith("NC") or pin == 11:
            if row["voltage"] != wanted_voltage:
                errors.append(f"{connector}.{pin}: {net} needs voltage {wanted_voltage}")

    # Verify complete endpoint sets, not only net spelling at one connector.
    expected_members = defaultdict(set)
    for key, net in required.items():
        expected_members[net].add(key)
    for net, endpoints in expected_members.items():
        if members[net] != endpoints:
            errors.append(f"{net}: endpoint set mismatch, expected {sorted(endpoints)}, "
                          f"got {sorted(members[net])}")
    for net, endpoints in members.items():
        if net.startswith("NC") and len(endpoints) != 1:
            errors.append(f"no-connect net {net} is shared by {sorted(endpoints)}")

    connectors = spec.get("connectors", {})
    if not isinstance(connectors, dict):
        errors.append("spec.connectors must be an object")
        connectors = {}
    if set(connectors) != set(expected):
        errors.append(f"spec connector set mismatch: expected {sorted(expected)}")
    for connector, pins in expected.items():
        entry = connectors.get(connector, {})
        if not isinstance(entry, dict):
            errors.append(f"spec.{connector} must be an object")
            continue
        connector_type = entry.get("type", "")
        if isinstance(connector_type, str):
            array_match = re.search(r"(\d+)\s*[xX×]\s*(\d+)", connector_type)
            simple_match = re.search(r"(\d+)-pin\b", connector_type)
            count = (int(array_match[1]) * int(array_match[2]) if array_match else
                     int(simple_match[1]) if simple_match else None)
            expected_count = 40 if connector == "J_FPGA_J13" else len(pins)
            if count is not None and count != expected_count:
                errors.append(f"spec.{connector}.type describes {count} pins, "
                              f"expected {expected_count}")
        else:
            errors.append(f"spec.{connector}.type must be a string")
        order = entry.get("order")
        if order is not None:
            actual_order = [by_pin.get((connector, pin), {}).get("silkscreen")
                            for pin in range(1, len(pins) + 1)]
            if order != actual_order:
                errors.append(f"spec.{connector}.order contradicts CSV: {order!r} != {actual_order!r}")
        elif connector != "J_FPGA_J13":
            errors.append(f"spec.{connector}.order is required")
    return errors


def main() -> int:
    try:
        rows = load_rows()
        spec = json.loads(SPEC.read_text(encoding="utf-8-sig"))
        if not isinstance(spec, dict):
            raise ValueError("spec must be a JSON object")
        errors = validate(rows, spec)
    except (OSError, csv.Error, json.JSONDecodeError, ValueError) as exc:
        print(f"FAIL: cannot load interface definition: {exc}")
        return 1

    if errors:
        for error in errors:
            print(f"FAIL: {error}")
        return 1

    print(f"PASS electrical consistency: {len(rows)} mapped pins; 40 J13 pins accounted for; "
          "UART crossed; 3 MPR buses isolated; separate AHCT signal/power; 5V_AUX bounded")
    print("NOT VERIFIED: physical module pin order, connector orientation, footprints, "
          "mounting geometry and native PCB DRC. This is not fabrication approval.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
