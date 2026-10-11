"""Review measured MPR121 captures; never write sensor registers or PCB files.

Python 3, standard library only. Baseline registers expose the upper eight bits
of the internal ten-bit baseline: delta_est = (baseline_raw8 << 2) - filtered.
Candidates are a conservative project heuristic, not NXP factory calibration.
"""
import argparse
import csv
import hashlib
import io
import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ENVIRONMENTS = ("amp_off", "amp_on_idle", "amp_on_loud")
PHASES = ("idle", "held", "released", "neighbor")
COLUMNS = (
    "sample_id", "time_ms", "environment", "module", "electrode", "phase",
    "filtered", "baseline_raw8", "ack_ok", "ovcf", "oor", "acff", "arff",
)
FAULTS = ("ovcf", "oor", "acff", "arff")


def load_mapping(path=ROOT / "mapping.csv", raw_bytes=None):
    raw = Path(path).read_bytes() if raw_bytes is None else raw_bytes
    rows = list(csv.DictReader(io.StringIO(raw.decode("utf-8-sig"), newline="")))
    expected = [(1, e) for e in range(8)] + [(2, e) for e in range(8)] + [(3, e) for e in range(9)]
    actual = [(int(r["mpr121_board"]), int(r["mpr121_electrode"][3:])) for r in rows]
    if actual != expected or [int(r["midi"]) for r in rows] != list(range(60, 85)):
        raise ValueError("mapping.csv does not match R1's 8/8/9 channels and MIDI 60..84")
    for index, r in enumerate(rows):
        if int(r["key_index"]) != index or r["net"] != f"E{index:02d}" or r["connector"] != f"J{actual[index][0]}" or int(r["connector_pin"]) != actual[index][1] + 1:
            raise ValueError(f"mapping.csv connector mismatch for key {index}")
    return rows


def read_samples(path, mapping, raw_bytes=None):
    valid_channels = {(int(r["mpr121_board"]), int(r["mpr121_electrode"][3:])) for r in mapping}
    samples = defaultdict(list)
    identities = set()
    last_times = {}
    raw = Path(path).read_bytes() if raw_bytes is None else raw_bytes
    with io.StringIO(raw.decode("utf-8-sig"), newline="") as source:
        reader = csv.DictReader(source)
        if reader.fieldnames != list(COLUMNS):
            raise ValueError("CSV columns must exactly match calibration_template.csv")
        for line, r in enumerate(reader, 2):
            try:
                if None in r or any(v is None for v in r.values()):
                    raise ValueError("extra or missing cells")
                for column in COLUMNS:
                    if column not in ("environment", "phase"):
                        r[column] = int(r[column])
                channel = (r["module"], r["electrode"])
                if channel not in valid_channels:
                    raise ValueError("unused or unknown module/electrode")
                if r["environment"] not in ENVIRONMENTS or r["phase"] not in PHASES:
                    raise ValueError("unknown environment/phase")
                if r["sample_id"] < 0 or r["time_ms"] < 0:
                    raise ValueError("negative sample_id/time_ms")
                if not 0 <= r["filtered"] <= 1023 or not 0 <= r["baseline_raw8"] <= 255:
                    raise ValueError("filtered must be 10-bit, baseline_raw8 must be 8-bit")
                if any(r[f] not in (0, 1) for f in ("ack_ok",) + FAULTS):
                    raise ValueError("ACK and fault flags must be 0 or 1")
                identity = channel + (r["sample_id"],)
                if identity in identities:
                    raise ValueError("duplicate sample_id for this channel")
                if channel in last_times and r["time_ms"] <= last_times[channel]:
                    raise ValueError("time_ms must increase strictly for each channel")
                identities.add(identity)
                last_times[channel] = r["time_ms"]
                r["delta_est"] = (r["baseline_raw8"] << 2) - r["filtered"]
                samples[channel].append(r)
            except (ValueError, TypeError) as error:
                raise ValueError(f"CSV line {line}: {error}") from error
    return samples


def analyze(mapping, samples, min_samples=30, margin=4):
    if min_samples < 2 or margin < 1:
        raise ValueError("min_samples must be >=2 and margin must be >=1")
    keys = []
    for key in mapping:
        module = int(key["mpr121_board"])
        electrode = int(key["mpr121_electrode"][3:])
        capture = samples.get((module, electrode), [])
        valid = [r for r in capture if r["ack_ok"] and not any(r[f] for f in FAULTS)]
        fault_count = len(capture) - len(valid)
        groups = {(env, phase): [r["delta_est"] for r in valid if r["environment"] == env and r["phase"] == phase]
                  for env in ENVIRONMENTS for phase in PHASES}
        missing = [f"{env}/{phase}" for (env, phase), values in groups.items() if len(values) < min_samples]
        reasons = []
        if missing:
            reasons.append("insufficient_data")
        if fault_count:
            reasons.append("capture_contains_sensor_or_ack_fault")
        idle = [d for (env, phase), values in groups.items() if phase != "held" for d in values]
        held = [d for (env, phase), values in groups.items() if phase == "held" for d in values]
        candidate = None
        # Read-out baseline discards two bits. Actual delta may be up to 3
        # counts higher than delta_est. Noise takes that uncertainty upward;
        # held uses its conservative lower bound. Equality is not sufficient
        # for MPR121's strict touch/release comparisons.
        noise_ceiling = max(idle) + 3 if idle else None
        held_floor = min(held) if held else None
        if not reasons:
            release = max(1, noise_ceiling + margin + 1)
            touch_max = min(255, held_floor - margin - 1)
            if release + 2 > touch_max:
                reasons.append("no_safe_threshold_gap")
            else:
                touch = (release + 2 + touch_max) // 2
                candidate = {
                    "touch_threshold": touch, "release_threshold": release,
                    "touch_register": f"0x{0x41 + 2 * electrode:02X}",
                    "release_register": f"0x{0x42 + 2 * electrode:02X}",
                }
        keys.append({
            "key_index": int(key["key_index"]), "note": key["note"], "midi": int(key["midi"]),
            "connector": key["connector"], "connector_pin": int(key["connector_pin"]),
            "module": module, "electrode": electrode, "fault_samples": fault_count,
            "sample_counts": {f"{env}/{phase}": len(values) for (env, phase), values in groups.items()},
            "missing_groups": missing, "noise_ceiling_with_3_count_uncertainty": noise_ceiling,
            "held_delta_lower_bound": held_floor,
            "status": "CANDIDATE_REQUIRES_HARDWARE_RETEST" if candidate else "BLOCKED",
            "reasons": reasons, "candidate": candidate,
        })
    return {
        "schema_version": 1,
        "status": "CANDIDATES_REQUIRE_HARDWARE_RETEST" if all(k["candidate"] for k in keys) else "INCOMPLETE_OR_UNSAFE",
        "algorithm": "project heuristic: observed extrema + baseline quantization + configurable margin",
        "minimum_samples_per_environment_phase": min_samples, "margin_counts": margin,
        "environments": list(ENVIRONMENTS), "phases": list(PHASES),
        "module_status_masks": {"1": "0x00FF", "2": "0x00FF", "3": "0x01FF"},
        "hardware_validation": "NOT_PERFORMED_BY_THIS_TOOL",
        "latency_validation": "NOT_PERFORMED_BY_THIS_TOOL",
        "register_writes": "NONE; review candidates and retest on hardware",
        "keys": keys,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="measured CSV, using calibration_template.csv columns")
    parser.add_argument("--out", type=Path, required=True, help="new JSON report path; never overwrites an existing file")
    parser.add_argument("--min-samples", type=int, default=30)
    parser.add_argument("--margin", type=int, default=4, help="engineering margin in 10-bit delta counts, default 4")
    args = parser.parse_args()
    try:
        if args.out.exists():
            raise ValueError("output already exists; choose a new report filename")
        if args.out.suffix.lower() != ".json":
            raise ValueError("output must be a .json report")
        # Hash exactly the bytes analyzed, even if a logger modifies its file
        # later. Captures should still be finalized before running this tool.
        mapping_bytes = (ROOT / "mapping.csv").read_bytes()
        capture_bytes = args.capture.read_bytes()
        mapping = load_mapping(raw_bytes=mapping_bytes)
        report = analyze(mapping, read_samples(args.capture, mapping, raw_bytes=capture_bytes), args.min_samples, args.margin)
        report["capture_sha256"] = hashlib.sha256(capture_bytes).hexdigest()
        report["mapping_sha256"] = hashlib.sha256(mapping_bytes).hexdigest()
        with args.out.open("x", encoding="utf-8") as target:
            json.dump(report, target, ensure_ascii=False, indent=2)
            target.write("\n")
        count = sum(k["candidate"] is not None for k in report["keys"])
        print(f"{count}/25 candidates. {report['status']}. No hardware or PCB files changed.")
        return 0 if count == 25 else 2
    except (ValueError, OSError, UnicodeError) as error:
        print(f"Calibration input error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
