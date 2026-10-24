"""Decode 48-bit main-project GAO status sampled on the independent sys_clk.

The default 50 MHz is an explicit design assumption, never a CSV clock
measurement. Unknown, contradictory and omitted samples retain their positions.
This diagnostic report never automatically declares hardware PASS or FAIL.
"""
from __future__ import annotations

import argparse
from collections import Counter
import csv
import hashlib
import importlib.util
import json
import math
from pathlib import Path


_spec = importlib.util.spec_from_file_location("main_gao_numeric", Path(__file__).with_name("analyze-main-gao.py"))
_numeric = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_numeric)
BASES = _numeric.BASES
number = _numeric.number
WIDTH = 48
BUS = "debug_status[47:0]"
FIELDS = {
    "board_ready": (0, 1), "audio_locked": (1, 1), "ready_sync": (2, 1),
    "rst_n": (3, 1), "audio_rst_n": (4, 1), "sensor_overflow": (5, 1),
    "panic_request": (6, 1), "panic_quiescing": (7, 1),
    "pressed_50": (8, 3), "pressed_sync": (11, 3), "playing": (14, 1),
    "guide": (15, 1), "sensor_ready": (16, 3), "sensor_fault": (19, 3),
    "voices": (22, 7), "last_note": (29, 7),
    "first_qualified_lock": (36, 1), "second_qualified_lock": (37, 1),
    "first_lock_stable": (38, 1), "second_lock_stable": (39, 1),
    "first_raw_lock": (40, 1), "first_raw_reset": (41, 1),
    "second_raw_lock": (42, 1), "second_raw_reset": (43, 1),
    "audio_heartbeat_bit8": (44, 1), "i2s_bclk": (45, 1),
    "i2s_lrclk": (46, 1), "i2s_data": (47, 1),
}
BIT_NAMES = {low + bit: name if width == 1 else f"{name}[{bit}]"
             for name, (low, width) in FIELDS.items() for bit in range(width)}
assert set(BIT_NAMES) == set(range(WIDTH))


def load_capture(path: Path, radix: str = "hex"):
    raw = path.read_bytes()
    lines = raw.decode("utf-8-sig").splitlines()
    header_line = next((i for i, line in enumerate(lines)
                        if line.lstrip().lower().startswith("time unit:")), None)
    if header_line is None:
        raise ValueError("GAO 'time unit:' data header not found")
    records = list(csv.reader(lines[header_line:], skipinitialspace=True))
    header = [cell.strip() for cell in records[0]]
    named = [name for name in header if name]
    if len(named) != len(set(named)):
        raise ValueError("duplicate nonempty CSV column names")
    index = {name: i for i, name in enumerate(header) if name}
    bit_columns = {bit: f"debug_status[{bit}]" for bit in range(WIDTH)
                   if f"debug_status[{bit}]" in index}
    aggregate = BUS in index
    complete = len(bit_columns) == WIDTH
    if not aggregate and not complete:
        raise ValueError("missing aggregate status bus or complete 48 individual bit columns")
    rows, errors, contradictions = [], [], []
    compared_rows, partial_bit_rows, unknown_aggregate_rows = 0, 0, 0
    for cells in records[1:]:
        if not cells or not any(cell.strip() for cell in cells):
            continue
        row_id = len(rows)
        if len(cells) == len(header) - 1 and header[-1] == "":
            cells.append("")
        if len(cells) != len(header):
            raise ValueError(f"row {row_id}: {len(cells)} fields, expected {len(header)}")

        def read(name, base, width):
            try:
                return number(cells[index[name]], base, width)
            except ValueError as exc:
                errors.append({"row": row_id, "signal": name,
                               "token": cells[index[name]], "error": str(exc)})
                return None

        word = read(BUS, BASES[radix], WIDTH) if aggregate else None
        if aggregate and word is None:
            unknown_aggregate_rows += 1
        bits = {bit: read(name, 2, 1) for bit, name in bit_columns.items()}
        all_present_known = all(bit is not None for bit in bits.values())
        if not all_present_known:
            partial_bit_rows += 1
        if aggregate and word is not None and bits:
            compared_rows += 1
            bad = [bit for bit, value in bits.items() if value is not None and value != ((word >> bit) & 1)]
            if bad:
                contradictions.append({"row": row_id, "aggregate_hex": f"{word:012X}", "mismatched_bits": bad})
                word = None
        if not aggregate and complete and all_present_known:
            word = sum(value << bit for bit, value in bits.items())
        # Do not silently replace an unknown aggregate by apparently valid bits,
        # or accept a known aggregate while an exported bit is unknown.
        if bits and not all_present_known:
            word = None
        try:
            timestamp = float(cells[0].strip())
            if not math.isfinite(timestamp):
                timestamp = None
        except ValueError:
            timestamp = None
        rows.append({"row": row_id, "export_time": timestamp, "word": word})
    if not rows:
        raise ValueError("no sample rows")
    return rows, {
        "file": str(path.resolve()), "sha256": hashlib.sha256(raw).hexdigest().upper(),
        "header_line_1based": header_line + 1, "export_time_column": header[0],
        "columns": named, "aggregate_present": aggregate,
        "complete_bit_columns": complete,
        "missing_bit_columns": [bit for bit in range(WIDTH) if bit not in bit_columns],
        "compared_rows": compared_rows, "partial_bit_rows": partial_bit_rows,
        "unknown_aggregate_rows": unknown_aggregate_rows,
        "bus_bit_mismatches": contradictions, "parse_errors": errors,
    }


def extract(word, low, width):
    return None if word is None else (word >> low) & ((1 << width) - 1)


def summarize(rows, values):
    histogram = Counter("unknown" if value is None else str(value) for value in values)
    runs, changes, rising, falling = [], [], [], []
    previous = None
    previous_index = None
    for row, value in zip(rows, values):
        sample = row["sample_index"]
        adjacent = previous_index is not None and sample == previous_index + 1
        if not runs or value != previous or not adjacent:
            runs.append({"start_sample": sample, "first_csv_row": row["row"], "samples": 1, "value": value})
        else:
            runs[-1]["samples"] += 1
        if adjacent and value is not None and previous is not None and value != previous:
            changes.append({"sample_index": sample, "from": previous, "to": value})
            if previous == 0 and value == 1:
                rising.append(sample)
            elif previous == 1 and value == 0:
                falling.append(sample)
        previous, previous_index = value, sample
    return {"histogram_decimal": dict(histogram), "known_rows": len(values) - histogram.get("unknown", 0),
            "unknown_rows": histogram.get("unknown", 0), "known_adjacent_transition_count": len(changes),
            "transitions": changes, "runs": runs,
            "rising_edge_sample_indices": rising, "falling_edge_sample_indices": falling}


def stable_relation(rows, controls, observed, expected, guard):
    evaluated, excluded, mismatches = 0, 0, []
    for index, row in enumerate(rows):
        window = rows[max(0, index - guard):min(len(rows), index + guard + 1)]
        reference = tuple(row["fields"][name] for name in controls)
        contiguous = all(b["sample_index"] == a["sample_index"] + 1 for a, b in zip(window, window[1:]))
        stable = all(tuple(item["fields"][name] for name in controls) == reference for item in window)
        # Require an entire two-sided guard and known control/output values.
        if len(window) != guard * 2 + 1 or not contiguous or not stable or None in reference or row["fields"][observed] is None:
            excluded += 1
            continue
        evaluated += 1
        want = int(expected(row["fields"]))
        got = row["fields"][observed]
        if got != want:
            mismatches.append({"csv_row": row["row"], "sample_index": row["sample_index"], "observed": got, "expected": want})
    return {"stable_rows_evaluated": evaluated, "transition_unknown_or_boundary_rows_excluded": excluded,
            "mismatch_count": len(mismatches), "mismatches": mismatches,
            "guard_samples_each_side": guard,
            "interpretation": "Diagnostic stable-run consistency only; asynchronous multi-bit transitions are excluded. No automatic hardware verdict."}


def analyze(path, sample_rate=50_000_000.0, radix="hex", expected_rows=2048, guard=2, synthetic=False):
    if not math.isfinite(sample_rate) or sample_rate <= 0:
        raise ValueError("sample rate must be finite and positive")
    if guard < 1 or expected_rows < 1:
        raise ValueError("stable guard and expected row count must be positive")
    rows, source = load_capture(Path(path), radix)
    timeline = _numeric.timeline(rows, sample_rate)
    for row in rows:
        row["fields"] = {name: extract(row["word"], low, width) for name, (low, width) in FIELDS.items()}
    valid = sum(row["word"] is not None for row in rows)
    summaries = {name: summarize(rows, [row["fields"][name] for row in rows]) for name in FIELDS}
    return {
        "hardware_verdict": "NOT_ASSESSED", "synthetic_input": synthetic,
        "source": source, "radix": radix,
        "sampling": {"assumed_sys_clk_hz": sample_rate, "is_clock_measurement": False,
                     "note": "50 MHz default is the design assumption. Export timestamps are display settings, not measured hardware clock periods."},
        "timeline": timeline,
        "rows": {"total": len(rows), "valid_known_words": valid,
                 "unknown_or_invalid_words": len(rows) - valid,
                 "expected_valid_words": expected_rows, "valid_count_matches_expected": valid == expected_rows,
                 "unknown_or_invalid_csv_rows": [row["row"] for row in rows if row["word"] is None],
                 "unknown_or_invalid_sample_indices": [row["sample_index"] for row in rows if row["word"] is None]},
        "bit_map": {str(bit): BIT_NAMES[bit] for bit in range(WIDTH)},
        "field_map": {name: {"low_bit": low, "width": width} for name, (low, width) in FIELDS.items()},
        "fields": summaries,
        "individual_bits": {str(bit): summarize(rows, [extract(row["word"], bit, 1) for row in rows]) for bit in range(WIDTH)},
        "clock_edge_counts": {name: {"rising": len(summaries[name]["rising_edge_sample_indices"]),
                                      "falling": len(summaries[name]["falling_edge_sample_indices"]),
                                      "note": "Observed adjacent known samples only; no edges are inferred across unknowns or missing rows."}
                              for name in ("audio_heartbeat_bit8", "i2s_bclk", "i2s_lrclk")},
        "stable_relations": {
            "system_rst_n": stable_relation(rows, ("ready_sync", "pressed_sync"), "rst_n",
                                             lambda f: bool(f["ready_sync"]) and not bool(f["pressed_sync"] & 4), guard),
            "audio_rst_n": stable_relation(rows, ("rst_n", "sensor_overflow", "panic_request", "panic_quiescing"), "audio_rst_n",
                                            lambda f: bool(f["rst_n"]) and not any(f[name] for name in ("sensor_overflow", "panic_request", "panic_quiescing")), guard),
            "qualified_audio_lock": stable_relation(rows, ("first_qualified_lock", "second_qualified_lock", "first_lock_stable", "second_lock_stable"), "audio_locked",
                                                    lambda f: all(f[name] for name in ("first_qualified_lock", "second_qualified_lock", "first_lock_stable", "second_lock_stable")), guard),
        },
        "limitations": ["Two-stage sampling does not make asynchronous multi-bit words atomic.",
                        "2048 known rows and clock transitions do not establish correct FPGA audio or physical wiring.",
                        "A static heartbeat can indicate a stopped source clock or a source that did not change in this limited window.",
                        "Reset consistency is reported only on guarded stable control runs and never treated as an automatic hardware PASS/FAIL."],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--sample-rate", type=float, default=50_000_000.0)
    parser.add_argument("--radix", choices=BASES, default="hex")
    parser.add_argument("--expected-valid-rows", type=int, default=2048)
    parser.add_argument("--stable-guard", type=int, default=2)
    parser.add_argument("--synthetic", action="store_true")
    args = parser.parse_args()
    report = analyze(args.capture, args.sample_rate, args.radix, args.expected_valid_rows, args.stable_guard, args.synthetic)
    content = json.dumps(report, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content, encoding="utf-8")
        print(str(args.output.resolve()))
    else:
        print(content)


if __name__ == "__main__":
    main()
