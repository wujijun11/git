"""Extract measured PnR results; never turn simulation into hardware acceptance."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def required(pattern, text, label):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        raise ValueError(f"Missing {label} in Gowin report")
    return match


def summarize(pnr):
    timing_path = pnr / "ContestFull.tr"
    resource_path = pnr / "ContestFull.rpt.txt"
    timing = timing_path.read_text(encoding="utf-8-sig")
    resources = resource_path.read_text(encoding="utf-8-sig")
    result = {
        "createdTime": required(r"<Created Time>:\s*(.+)", timing, "created time")[1].strip(),
        "part": required(r"<Part Number>:\s*(.+)", timing, "part")[1].strip(),
        "pathsAnalyzed": int(required(r"<Numbers of Paths Analyzed>:\s*(\d+)", timing, "path count")[1]),
        "endpointsAnalyzed": int(required(r"<Numbers of Endpoints Analyzed>:\s*(\d+)", timing, "endpoint count")[1]),
        "violations": {}, "minimumSlackNs": {}, "worstPaths": {},
        "resources": {}, "clocks": [], "artifacts": [],
        "hardwareValidated": False,
    }
    for kind in ("Setup", "Hold"):
        result["violations"][kind.lower()] = int(required(
            rf"<Numbers of {kind} Violated Endpoints>:\s*(\d+)", timing, kind)[1])
    for number, kind in enumerate(("Setup", "Hold", "Recovery", "Removal"), 1):
        section = required(
            rf"^3\.1\.{number} {kind} Paths Table\s*\n([\s\S]*?)(?=^3\.[12]\.|\Z)",
            timing, f"{kind} table")[1]
        paths = re.findall(r"^\s+\d+\s+(-?\d+\.\d+)\s+(\S+)\s+(\S+)", section, re.MULTILINE)
        if not paths:
            raise ValueError(f"No {kind} paths; inspect report before accepting this build")
        worst = min(paths, key=lambda row: float(row[0]))
        result["minimumSlackNs"][kind.lower()] = float(worst[0])
        result["worstPaths"][kind.lower()] = {"from": worst[1], "to": worst[2]}
    for label in ("Logic", "Register", "BSRAM", "DSP"):
        match = required(rf"^\s+{label}\s+\|\s+([\d.]+)/([\d.]+)\s+\|\s+(\d+)%", resources, label)
        used, capacity = float(match[1]), float(match[2])
        result["resources"][label] = {"used": used, "capacity": capacity,
            "reportedPercent": int(match[3]), "free": capacity - used}
    clock_section = required(r"^2\.3 Max Frequency Summary\s*\n([\s\S]*?)^2\.4 ", timing, "Fmax table")[1]
    for name, constraint, actual, level in re.findall(
            r"^\s+\d+\s+(\S+)\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)\s+(\d+)", clock_section, re.MULTILINE):
        result["clocks"].append({"name": name, "constraintMHz": float(constraint),
            "fmaxMHz": float(actual), "logicLevel": int(level)})
    for name in ("ContestFull.fs", "ContestFull.tr", "ContestFull.rpt.txt"):
        path = pnr / name
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        result["artifacts"].append({"name": name, "size": path.stat().st_size,
            "sha256": digest})
    result["timingPass"] = not any(result["violations"].values()) and min(result["minimumSlackNs"].values()) >= 0
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pnr", type=Path, default=Path(__file__).resolve().parents[1] / "full/impl/pnr")
    parser.add_argument("--baseline", type=Path, help="Directory containing the previous fs/tr/rpt.txt")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = {"current": summarize(args.pnr)}
    if args.baseline:
        result["baseline"] = summarize(args.baseline)
        result["change"] = {
            "setupSlackImprovementNs": round(result["current"]["minimumSlackNs"]["setup"] - result["baseline"]["minimumSlackNs"]["setup"], 3),
            "bsramBlocksSaved": result["baseline"]["resources"]["BSRAM"]["used"] - result["current"]["resources"]["BSRAM"]["used"],
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"timingPass": result["current"]["timingPass"],
        "minimumSlackNs": result["current"]["minimumSlackNs"],
        "bsram": result["current"]["resources"]["BSRAM"],
        "output": str(args.output)}, ensure_ascii=False))
    return 0 if result["current"]["timingPass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
