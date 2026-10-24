"""Decode passive UART GAO 48-bit values or exported analyzer CSV.

Raw packed binary counters cross two observation flops; interpret stable runs.
The CSV timing unit is a display/export setting, not a measured FPGA clock.
"""
from pathlib import Path
import argparse
import importlib.util
import json
import re


HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
_spec = importlib.util.spec_from_file_location("main_status_gao_loader",
    PROJECT / "scripts/analyze-main-status-gao.py")
_loader = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_loader)


FIELDS = {
    "board_ready": (0, 1), "audio_locked": (1, 1), "ready_sync": (2, 1),
    "rst_n": (3, 1), "uart_rx_level": (4, 1), "uart_tx_level": (5, 1),
    "rx_falling_edges": (6, 8), "rx_valid_bytes": (14, 8),
    "last_rx_byte": (22, 8), "commands_accepted": (30, 3),
    "responses_accepted": (33, 3), "tx_started_bytes": (36, 8),
    "crc_error_seen": (44, 1), "framing_error_seen": (45, 1),
    "overflow_seen": (46, 1), "timeout_seen": (47, 1),
}


def decode(value):
    if value is None:
        return {"packedHex": None, **{name: None for name in FIELDS}, "lastRxByteHex": None}
    result = {name: (value >> offset) & ((1 << width) - 1)
              for name, (offset, width) in FIELDS.items()}
    return {"packedHex": f"{value:012X}", **result,
            "lastRxByteHex": f"{result['last_rx_byte']:02X}"}


def number(text):
    text = text.strip().replace("_", "")
    match = re.fullmatch(r"(?:48'h|0x)?([0-9a-fA-F]{1,12})", text)
    if not match:
        raise ValueError("Expected a maximum 12-digit hexadecimal GAO value.")
    return int(match[1], 16)


def parse_csv(path):
    rows, source = _loader.load_capture(path, "hex")
    timeline = _loader._numeric.timeline(rows, 50_000_000.0)
    samples = [{"csvRow": row["row"], "sample_index": row["sample_index"],
                "exportTime": row["export_time"], **decode(row["word"])} for row in rows]
    runs = []
    for sample in samples:
        if runs and runs[-1]["packedHex"] == sample["packedHex"] and sample["sample_index"] == runs[-1]["lastSample"]+1:
            runs[-1]["sampleCount"] += 1
            runs[-1]["lastSample"] = sample["sample_index"]
        else:
            runs.append({**sample, "firstSample": sample["sample_index"],
                         "lastSample": sample["sample_index"], "sampleCount": 1})
    counter_names = ("rx_falling_edges", "rx_valid_bytes", "commands_accepted",
                     "responses_accepted", "tx_started_bytes")
    decreases = []
    for before, after in zip(samples, samples[1:]):
        if before["packedHex"] is None or after["packedHex"] is None or after["sample_index"] != before["sample_index"]+1:
            continue
        for name in counter_names:
            if after[name] < before[name]:
                decreases.append({"field": name, "beforeSample": before["sample_index"],
                    "afterSample": after["sample_index"], "before": before[name], "after": after[name],
                    "interpretation": "Possible wrap, reset or asynchronous multi-bit transition; not a measured negative event count."})
    terminal = runs[-1] if runs[-1]["packedHex"] is not None and runs[-1]["sampleCount"] >= 4 else None
    unknown = [sample["sample_index"] for sample in samples if sample["packedHex"] is None]
    reset_samples = [sample["sample_index"] for sample in samples if sample["rst_n"] == 0]
    return {"csv": str(path.resolve()), "sampleCount": len(samples), "source": source,
            "timeline": timeline, "sampling": {"assumedSampleHz": 50_000_000, "isClockMeasurement": False},
            "knownSampleCount": len(samples)-len(unknown), "unknownOrInvalidSampleCount": len(unknown),
            "unknownOrInvalidSampleIndices": unknown,
            "inferredMissingSampleCount": timeline["inferred_missing_samples"],
            "contradictoryRowCount": len(source["bus_bit_mismatches"]),
            "missingBitColumnCount": len(source["missing_bit_columns"]),
            "partialBitRowCount": source["partial_bit_rows"],
            "unknownAggregateRowCount": source["unknown_aggregate_rows"],
            "parseErrorCount": len(source["parse_errors"]),
            "first": samples[0], "last": samples[-1], "terminalStableRun": terminal,
            "terminalStableRunUnavailableReason": None if terminal else "Final row is unknown or final unchanged contiguous run has fewer than four samples.",
            "observedResetSampleIndices": reset_samples, "observedCounterDecreases": decreases,
            "runs": runs, "samples": samples,
            "caution": "Counter CDC values during transitions are diagnostic-only. Unknown, contradictory and omitted samples retain positions. No automatic hardware verdict."}


def delta(before, after):
    fields = ("rx_falling_edges", "rx_valid_bytes", "commands_accepted",
              "responses_accepted", "tx_started_bytes")
    result = {}
    for name in fields:
        modulus = 1 << FIELDS[name][1]
        result[name] = {"before": before[name], "after": after[name], "modulus": modulus,
            "moduloDelta": (after[name] - before[name]) % modulus,
            "counterDecreased": after[name] < before[name],
            "warning": "Assumes no intervening FPGA reset/reprogramming and fewer than the modulus events; hidden full wraps are possible even when unchanged."}
    return result


def compare_captures(before_path, after_path):
    before, after = parse_csv(before_path), parse_csv(after_path)
    endpoints = before["terminalStableRun"], after["terminalStableRun"]
    observed_reset = bool(before["observedResetSampleIndices"] or after["observedResetSampleIndices"])
    available = all(endpoint is not None for endpoint in endpoints) and not observed_reset
    return {"before": before, "after": after, "hardwareVerdict": "NOT_ASSESSED",
        "terminalStableModuloDelta": delta(*endpoints) if available else None,
        "comparisonUnavailableReason": None if available else "Observed reset or missing terminal stable endpoint.",
        "assumptions": ["No FPGA reset/reprogramming/reload between captures; this cannot be proved by two short captures.",
            "Fewer than 256 RX edge/byte or TX byte events, and fewer than 8 accepted commands/responses in the interval.",
            "Stable endpoints avoid observed CDC transitions but do not establish coherent counters throughout the uncaptured interval."],
        "warnings": ["Modulo deltas are not absolute event counts. Full wraps may look unchanged; decreases may be wrap, reset or CDC effects.",
            "Do not infer electrical wiring correctness or hardware PASS/FAIL automatically from these counters."]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--value")
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--after", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.value:
        result = decode(number(args.value))
    elif args.csv:
        result = parse_csv(args.csv)
    elif args.before and args.after:
        result = compare_captures(args.before, args.after)
    else:
        parser.error("Use --value, --csv or --before with --after.")
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        if args.output.exists():
            raise FileExistsError("Refuse to overwrite an existing result.")
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")


if __name__ == "__main__":
    main()
