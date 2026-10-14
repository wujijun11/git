"""Build a fresh ContestFull snapshot without overwriting the board implementation.

Every invocation creates a new directory. --prepare-only captures inputs without
starting Gowin; --run-snapshot starts only an unbuilt snapshot prepared here.
The RTL, ROM, constraints and original build Tcl are copied without edits.
"""
import argparse
import datetime as dt
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
LOCAL_TZ = dt.timezone(dt.timedelta(hours=8))
GOWIN_DEFAULT = Path(r"C:\Gowin\Gowin_V1.9.12_x64\IDE\bin\gw_sh.exe")
BASELINE_DEFAULT = PROJECT / "verification/modelsim-20261014/build_snapshot_20261014_124217/build-results.json"
ROMS = (
    "waves.hex", "midi.hex", "velocity.hex", "sine.hex", "ratio.hex",
    "piano.hex", "polar_lane0.hex", "polar_lane1.hex", "polar_ratios.hex",
)


def now():
    return dt.datetime.now(LOCAL_TZ).isoformat()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest().upper()


def file_inventory(root):
    return sorted([
        {"path": str(path.relative_to(root)), "size": path.stat().st_size, "sha256": sha256(path)}
        for path in root.rglob("*") if path.is_file()
    ], key=lambda entry: entry["path"])


def ensure_within(path, root):
    resolved = path.resolve()
    if not resolved.is_relative_to(root.resolve()):
        raise ValueError(f"Path leaves the intended project directory: {resolved}")
    return resolved


def input_check(snapshot, entries, source_root=PROJECT):
    checks = []
    for entry in entries:
        source, staged = source_root / entry["path"], snapshot / entry["path"]
        main_source = PROJECT / entry["path"]
        source_sha = sha256(source) if source.is_file() else None
        staged_sha = sha256(staged) if staged.is_file() else None
        main_sha = sha256(main_source) if main_source.is_file() else None
        checks.append({**entry, "sourceSha256": source_sha, "snapshotSha256": staged_sha,
                       "sourceMatches": source_sha == entry["sha256"],
                       "snapshotMatches": staged_sha == entry["sha256"],
                       "mainProjectSha256": main_sha,
                       "mainProjectMatches": main_sha == entry["sha256"]})
    return checks


def prepare(variant, output_root, gowin, baseline, source_root=PROJECT):
    source_root = ensure_within(source_root, PROJECT)
    output_root = ensure_within(output_root, PROJECT / "verification")
    stamp = dt.datetime.now(LOCAL_TZ).strftime("%Y%m%d_%H%M%S")
    snapshot = output_root / f"build_{variant}_{stamp}_{uuid.uuid4().hex[:8]}"
    snapshot.mkdir(parents=True, exist_ok=False)
    gprj = source_root / "full/ContestFull.gprj"
    dependencies = []
    sources = {gprj, source_root / "scripts/build-contest-full.tcl"}
    for item in ET.parse(gprj).getroot().findall("./FileList/File"):
        if item.get("enable", "1") != "1":
            continue
        source = ensure_within(gprj.parent / item.attrib["path"], source_root)
        if not source.is_file():
            raise FileNotFoundError(source)
        sources.add(source)
        dependencies.append({"path": str(source.relative_to(source_root)),
                             "type": item.attrib["type"], "sha256": sha256(source)})
    sources.update(source_root / "rtl/audio/rom" / name for name in ROMS)
    sources.add(source_root / "rtl/visual/goertzel_1024_64.hex")
    entries = []
    for source in sorted(sources, key=str):
        if not source.is_file():
            raise FileNotFoundError(source)
        relative = source.relative_to(source_root)
        target = snapshot / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        entry = {"path": str(relative), "size": source.stat().st_size, "sha256": sha256(source)}
        if sha256(target) != entry["sha256"]:
            raise ValueError(f"Snapshot copy differs: {target}")
        entries.append(entry)
    write_json(snapshot / "snapshot-inputs.json", entries)
    write_json(snapshot / "gprj-dependencies.json", dependencies)
    write_json(snapshot / "protected-impl-before.json", file_inventory(PROJECT / "full/impl"))
    metadata = {"snapshot": str(snapshot), "project": str(PROJECT), "sourceRoot": str(source_root), "variant": variant,
                "createdAt": now(), "gowin": str(gowin), "baselineReport": str(baseline),
                "gprjDependencies": len(dependencies), "inputFiles": len(entries),
                "preparedOnly": True, "driverSha256": sha256(Path(__file__).resolve())}
    write_json(snapshot / "snapshot-metadata.json", metadata)
    return snapshot


def required(pattern, text, label):
    match = re.search(pattern, text, re.MULTILINE)
    if match is None:
        raise ValueError(f"Missing {label} in actual Gowin report")
    return match


def summarize(pnr):
    timing = (pnr / "ContestFull.tr").read_text(encoding="utf-8-sig", errors="replace")
    resources = (pnr / "ContestFull.rpt.txt").read_text(encoding="utf-8-sig", errors="replace")
    result = {"createdTime": required(r"<Created Time>:\s*(.+)", timing, "created time")[1].strip(),
              "part": required(r"<Part Number>:\s*(.+)", timing, "part")[1].strip(),
              "pathsAnalyzed": int(required(r"<Numbers of Paths Analyzed>:\s*(\d+)", timing, "paths")[1]),
              "endpointsAnalyzed": int(required(r"<Numbers of Endpoints Analyzed>:\s*(\d+)", timing, "endpoints")[1]),
              "violations": {}, "minimumSlackNs": {}, "worstPaths": {},
              "resources": {}, "clocks": [], "artifacts": [], "hardwareValidated": False}
    for kind in ("Setup", "Hold"):
        result["violations"][kind.lower()] = int(required(
            rf"<Numbers of {kind} Violated Endpoints>:\s*(\d+)", timing, f"{kind} endpoints")[1])
    for index, kind in enumerate(("Setup", "Hold", "Recovery", "Removal"), 1):
        section = required(
            rf"^3\.1\.{index} {kind} Paths Table\s*\n([\s\S]*?)(?=^3\.1\.[1-4] |^3\.2 |\Z)",
            timing, f"bounded {kind} table")[1]
        rows = re.findall(r"^\s+\d+\s+(-?\d+\.\d+)\s+(\S+)\s+(\S+)", section, re.MULTILINE)
        if not rows:
            raise ValueError(f"No {kind} path rows in actual report")
        worst = min(rows, key=lambda row: float(row[0]))
        result["minimumSlackNs"][kind.lower()] = float(worst[0])
        result["worstPaths"][kind.lower()] = {"from": worst[1], "to": worst[2]}
    for kind in ("Logic", "Register", "BSRAM", "DSP"):
        row = required(rf"^\s+{kind}\s+\|\s+([\d.]+)/([\d.]+)\s+\|\s+(\d+)%", resources, kind)
        used, capacity = float(row[1]), float(row[2])
        result["resources"][kind] = {"used": used, "capacity": capacity,
                                     "reportedPercent": int(row[3]), "free": capacity - used}
    section = required(r"^2\.3 Max Frequency Summary\s*\n([\s\S]*?)^2\.4 ", timing, "Fmax table")[1]
    for name, constraint, actual, level in re.findall(
            r"^\s+\d+\s+(\S+)\s+([\d.]+)\(MHz\)\s+([\d.]+)\(MHz\)\s+(\d+)", section, re.MULTILINE):
        result["clocks"].append({"name": name, "constraintMHz": float(constraint),
                                 "fmaxMHz": float(actual), "logicLevel": int(level)})
    for name in ("ContestFull.fs", "ContestFull.tr", "ContestFull.rpt.txt"):
        path = pnr / name
        result["artifacts"].append({"path": str(path), "size": path.stat().st_size, "sha256": sha256(path)})
    result["timingPass"] = not any(result["violations"].values()) and min(result["minimumSlackNs"].values()) >= 0
    return result


def analyze(snapshot, run, log):
    metadata = read_json(snapshot / "snapshot-metadata.json")
    before = read_json(snapshot / "protected-impl-before.json")
    after = file_inventory(PROJECT / "full/impl")
    write_json(snapshot / "protected-impl-after.json", after)
    source_root = Path(metadata.get("sourceRoot", str(PROJECT)))
    checks = input_check(snapshot, read_json(snapshot / "snapshot-inputs.json"), source_root)
    write_json(snapshot / "snapshot-inputs-after.json", checks)
    result = {"snapshot": str(snapshot), "variant": metadata["variant"], "run": run,
              "sourceOrigin": str(source_root), "protectedMainProject": str(PROJECT),
              "baselineReport": metadata["baselineReport"],
              "protectedImplUnchanged": before == after, "protectedImplFileCount": len(before),
              "sourceInputsMatch": all(entry["sourceMatches"] for entry in checks),
              "snapshotInputsMatch": all(entry["snapshotMatches"] for entry in checks),
              "mainProjectInputsMatch": all(entry["mainProjectMatches"] for entry in checks),
              "mainProjectInputMismatches": [entry["path"] for entry in checks if not entry["mainProjectMatches"]],
              "sourceMatchingNote": "sourceInputsMatch means the explicitly named source origin; mainProjectInputsMatch is a separate full 80-input check.",
              "buildAcceptanceNote": "Frozen source-origin build/timing and original implementation protection only. Main-source adoption and hardware validation are separate.",
              "sourceInputFileCount": len(checks), "timingPassMarker": "FULL BUILD TIMING PASS" in log,
              "warningCount": len(re.findall(r"^WARN\s+", log, re.MULTILINE)),
              "errorLines": re.findall(r"^.*(?:ERROR\s*\(|Full build failed).*?$", log, re.MULTILINE),
              "timingParserNote": "Each 3.1.1-3.1.4 table is bounded; 3.2 pulse-width rows excluded.",
              "violationCountNote": "Setup/Hold vendor endpoint totals include recovery/removal; no separate totals provided.",
              "hardwareValidated": False, "buildAccepted": False}
    try:
        current = summarize(snapshot / "full/impl/pnr")
        result["current"] = current
        baseline = read_json(Path(metadata["baselineReport"]))["current"]
        result["baseline"] = baseline
        result["change"] = {
            "slackDeltaNs": {kind: round(current["minimumSlackNs"][kind] - baseline["minimumSlackNs"][kind], 3)
                              for kind in ("setup", "hold", "recovery", "removal")},
            "resourceDelta": {kind: current["resources"][kind]["used"] - baseline["resources"][kind]["used"]
                              for kind in ("Logic", "Register", "BSRAM", "DSP")}}
        result["buildAccepted"] = (run["exitCode"] == 0 and not run["timedOut"] and
            result["timingPassMarker"] and current["timingPass"] and result["protectedImplUnchanged"] and
            result["snapshotInputsMatch"] and result["sourceInputsMatch"] and not result["errorLines"])
    except (ValueError, FileNotFoundError, KeyError) as error:
        result["analysisError"] = str(error)
    write_json(snapshot / "build-results.json", result)
    return result


def run_build(snapshot, timeout_seconds):
    snapshot = ensure_within(snapshot, PROJECT / "verification")
    metadata = read_json(snapshot / "snapshot-metadata.json")
    if metadata["project"] != str(PROJECT):
        raise ValueError("Snapshot belongs to another project")
    if (snapshot / "gowin-run.json").exists() or (snapshot / "full/impl").exists():
        raise ValueError("Snapshot has already been built; create a new snapshot instead")
    if file_inventory(PROJECT / "full/impl") != read_json(snapshot / "protected-impl-before.json"):
        raise ValueError("Original full/impl changed since preparation; create a new snapshot")
    source_root = ensure_within(Path(metadata.get("sourceRoot", str(PROJECT))), PROJECT)
    checks = input_check(snapshot, read_json(snapshot / "snapshot-inputs.json"), source_root)
    if not all(entry["sourceMatches"] and entry["snapshotMatches"] for entry in checks):
        raise ValueError("Current sources or staged inputs changed since preparation; create a fresh snapshot")
    gowin = Path(metadata["gowin"])
    if not gowin.is_file():
        raise FileNotFoundError(gowin)
    command = [str(gowin), str(snapshot / "scripts/build-contest-full.tcl")]
    start, clock = now(), time.monotonic()
    metadata["preparedOnly"] = False
    metadata["buildStartedAt"] = start
    write_json(snapshot / "snapshot-metadata.json", metadata)
    timed_out = False
    write_json(snapshot / "build-started.json", {"startedAt": start, "command": command})
    with (snapshot / "gowin-build.log").open("wb") as log_file:
        worker = subprocess.Popen(command, cwd=snapshot, stdout=log_file, stderr=subprocess.STDOUT)
        try:
            exit_code = worker.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            # Terminate only this invocation's process tree. Never target GUI or
            # arbitrary Gowin processes by name.
            subprocess.run(["taskkill", "/PID", str(worker.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            exit_code = worker.wait(timeout=30)
    run = {"startedAt": start, "endedAt": now(), "durationSeconds": round(time.monotonic() - clock, 3),
           "exitCode": exit_code, "timedOut": timed_out, "timeoutSeconds": timeout_seconds,
           "command": command, "pid": worker.pid}
    write_json(snapshot / "gowin-run.json", run)
    (snapshot / "gowin-build.exit.txt").write_text(str(exit_code) + "\n", encoding="ascii")
    log = (snapshot / "gowin-build.log").read_text(encoding="utf-8-sig", errors="replace")
    return analyze(snapshot, run, log)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", default="timing", help="Lowercase letters/digits/hyphens; labels a new build")
    parser.add_argument("--output-root", type=Path, default=PROJECT / "verification/timing-margin-20261014")
    parser.add_argument("--gowin", type=Path, default=GOWIN_DEFAULT)
    parser.add_argument("--baseline", type=Path, default=BASELINE_DEFAULT)
    parser.add_argument("--source-root", type=Path, default=PROJECT,
                        help="Explicit source origin within this project; original main full/impl always protected")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--run-snapshot", type=Path)
    parser.add_argument("--timeout-seconds", type=int, default=2400)
    parser.add_argument("--parse-pnr", type=Path, help="Read-only parser validation against an existing PnR directory")
    args = parser.parse_args()
    if args.parse_pnr:
        print(json.dumps(summarize(args.parse_pnr), ensure_ascii=False, indent=2))
        return 0
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,47}", args.variant):
        parser.error("--variant must contain only lowercase letters/digits/hyphens")
    if args.timeout_seconds < 60:
        parser.error("--timeout-seconds must be at least 60")
    if args.prepare_only and args.run_snapshot:
        parser.error("--prepare-only cannot be combined with --run-snapshot")
    snapshot = args.run_snapshot or prepare(args.variant, args.output_root, args.gowin, args.baseline, args.source_root)
    print(json.dumps({"snapshot": str(snapshot), "preparedOnly": args.prepare_only}, ensure_ascii=False), flush=True)
    if args.prepare_only:
        return 0
    result = run_build(snapshot, args.timeout_seconds)
    print(json.dumps({key: result.get(key) for key in (
        "snapshot", "variant", "run", "current", "change", "protectedImplUnchanged", "buildAccepted", "analysisError")},
        ensure_ascii=False, indent=2))
    return 0 if result["buildAccepted"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
