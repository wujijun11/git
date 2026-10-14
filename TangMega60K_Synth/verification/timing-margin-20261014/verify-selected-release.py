"""Read-only release evidence audit; never promotes sources or programs hardware.

Only selected-release.json is written. Run after the chosen candidate has been
copied to the primary project and both its build and Core regression finish.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


# Fixed whole Core suite, independent of a possibly edited result manifest.
CORE = [
    ("full_system", "tb_instrument_full_system", "FULL SYSTEM PASS", ""),
    ("global_panic", "tb_global_panic", "GLOBAL PANIC PASS", ""),
    ("control_router", "tb_full_control", "FULL CONTROL ROUTER PASS", ""),
    ("expression_merge", "tb_expression_merge", "EXPRESSION MERGE PASS", ""),
    ("note_arbiter", "tb_note_arbiter", "NOTE ARBITER PASS", ""),
    ("runtime_fx", "tb_runtime_audio_fx", "RUNTIME AUDIO FX PASS", ""),
    ("runtime_fx_storage", "tb_runtime_audio_fx_storage", "RUNTIME AUDIO FX STORAGE PASS bit-exact shared/separate histories", ""),
    ("remote_note_watchdog", "tb_remote_note_watchdog", "REMOTE NOTE WATCHDOG PASS", ""),
    ("audio_visualizer", "tb_audio_visualizer", "AUDIO VISUALIZER PASS", ""),
    ("audio_monitor_cdc", "tb_audio_monitor_cdc", "AUDIO MONITOR CDC PASS", ""),
    ("watchdog_arbiter", "tb_watchdog_arbiter_integration", "PASS watchdog/arbiter integration:", ""),
    ("mpr121_i2c", "tb_mpr121_i2c", "PASS tb_mpr121_i2c", ""),
    ("mpr121_frontend", "tb_mpr121_frontend", "PASS tb_mpr121_frontend", ""),
    ("mpr121_backpressure", "tb_mpr121_backpressure", "PASS tb_mpr121_backpressure", ""),
    ("mpr121_timing", "tb_mpr121_timing", "PASS tb_mpr121_timing", ""),
    ("mpr121_capacity", "tb_mpr121_eventizer_capacity", "PASS tb_mpr121_eventizer_capacity", ""),
    ("performance", "tb_performance_controller", "PASS performance:", ""),
    ("performance_retrigger", "tb_performance_retrigger", "PASS performance retrigger:", ""),
    ("performance_commit", "tb_performance_commit_pipeline", "PASS performance consecutive commands:", ""),
    ("board_local_actions", "tb_board_local_actions", "BOARD LOCAL ACTIONS PASS", ""),
    ("ws2812_waveform", "tb_performance_ws2812", "ALL WS2812 WAVEFORM TESTS PASSED", ""),
    ("ws2812_matrix", "tb_ws2812_matrix", "ALL WS2812 MATRIX TESTS PASSED", ""),
    ("remote_uart", "tb_remote_uart_transport", "ALL REMOTE UART TESTS PASSED", ""),
    ("video_encoder", "tb_video_encoder", "ALL VIDEO TMDS ENCODER TESTS PASSED", ""),
    ("video_timing", "tb_video_timing", "ALL VIDEO TIMING TESTS PASSED", ""),
    ("video_vendor", "tb_video_vendor", "ALL VIDEO VENDOR TESTS PASSED", ""),
    ("audio_units", "tb_audio_units", "AUDIO DSP UNITS PASSED", ""),
    ("audio_engine_n4", "tb_audio_engine", "AUDIO ENGINE PASSED N=4", ""),
    ("audio_i2s", "tb_audio_i2s", "AUDIO I2S INTEGRATION PASSED", ""),
    ("ws2812_reject_zero", "tb_ws2812_invalid_zero_count", "", "WS2812 LED_COUNT must be 1..25"),
    ("ws2812_reject_large", "tb_ws2812_invalid_large_count", "", "WS2812 LED_COUNT must be 1..25"),
    ("ws2812_reject_map", "tb_ws2812_invalid_key_map", "", "WS2812 map key out of range"),
    ("ws2812_reject_duplicate", "tb_ws2812_duplicate_key_map", "", "WS2812 map must be a permutation of 0..24"),
]
EXPECTED_BENCHES = {
    "sim/tb_instrument_full_system.sv", "sim/tb_global_panic.sv", "sim/tb_full_control.sv",
    "sim/tb_runtime_audio_fx.sv", "sim/tb_runtime_audio_fx_storage.sv", "sim/tb_remote_note_watchdog.sv",
    "sim/tb_audio_visualizer.sv", "sim/tb_audio_monitor_cdc.sv", "sim/tb_watchdog_arbiter_integration.sv",
    "sim/tb_mpr121_i2c.sv", "sim/tb_mpr121_frontend.sv", "sim/tb_mpr121_backpressure.sv",
    "sim/tb_mpr121_timing.sv", "sim/tb_mpr121_eventizer_capacity.sv", "sim/tb_performance_controller.sv",
    "sim/tb_performance_retrigger.sv", "sim/tb_performance_commit_pipeline.sv", "sim/tb_board_local_actions.sv",
    "sim/tb_performance_ws2812.sv", "sim/tb_ws2812_matrix.sv", "sim/tb_remote_uart_transport.sv",
    "sim/tb_video_encoder.sv", "sim/tb_video_timing.sv", "sim/tb_video_vendor.sv", "sim/tb_audio_units.sv",
    "sim/tb_audio_engine.sv", "sim/tb_audio_i2s.sv", "sim/tb_mpr121_model.sv", "sim/runtime_audio_fx_reference.sv",
}
EXPECTED_ROMS = {"rtl/audio/rom/" + name + ".hex" for name in
    ("midi", "piano", "polar_lane0", "polar_lane1", "polar_ratios", "ratio", "sine", "velocity", "waves")}
EXPECTED_ROMS.add("rtl/visual/goertzel_1024_64.hex")
ERROR = re.compile(r"^\s*#?\s*\*\*\s+Error(?:\s|:)", re.M | re.I)
FATAL = re.compile(r"^\s*#?\s*\*\*\s+Fatal:\s*([^\r\n]+)", re.M | re.I)
ERROR_COUNT = re.compile(r"^\s*#?\s*Errors:\s*(\d+)", re.M | re.I)


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def read_text(path):
    data = Path(path).read_bytes()
    # WinPS5 redirects native compiler output to UTF-16; ModelSim's own -l
    # transcripts are UTF-8/ASCII. Preserve both actual formats faithfully.
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    return data.decode(encoding, errors="replace")


def relative_path(value):
    path = Path(str(value).replace("\\", "/"))
    if path.is_absolute() or ".." in path.parts:
        raise ValueError(f"Unsafe evidence-relative path: {value}")
    return path


class Audit:
    def __init__(self, root, build, modelsim, additional=None):
        self.root, self.build, self.modelsim = root, build, modelsim
        self.checks, self.details = [], {}
        self.additional = additional or []
        self.primary_fingerprints = None

    def check(self, name, passed, details=None):
        self.checks.append({"Check": name, "Passed": bool(passed), "Details": details})

    def safe(self, name, work):
        try:
            work()
        except Exception as exc:
            self.check(name + " completed", False, f"{type(exc).__name__}: {exc}")

    @staticmethod
    def marker_present(body, marker):
        return bool(re.search(r"^\s*#?\s*" + re.escape(marker) + r"(?:\s|:|$)", body, re.M))

    def core(self):
        core_by_name = {item[0]: item for item in CORE}
        names = [item[0] for item in CORE]
        evidence, history = [], []
        for run_index, directory in enumerate([self.modelsim] + self.additional):
            manifest = read_json(directory / "manifest.json")
            rows = read_json(directory / "test-summary.json")
            selected = manifest.get("SelectedCaseNames", [])
            interrupted = run_index == 0 and manifest.get("Status") == "Running"
            prefix = "ModelSim " + directory.name + " "
            selected_is_subset = (bool(selected) and len(set(selected)) == len(selected) and
                selected == [name for name in names if name in selected])
            self.check(prefix + "fixed Core selection", manifest.get("Suite") == "Core" and selected_is_subset and
                (selected == names if run_index == 0 else True) and manifest.get("SourceCount") == 66 and
                manifest.get("SuiteCaseCount") == 33 and manifest.get("FullCaseCount") == 34)
            if interrupted:
                # This is an audit annotation, never a rewrite of raw Running.
                # The known interrupted primary completed exactly the first 28.
                valid_status = [row.get("Name") for row in rows] == names[:28] and len(rows) == 28
            else:
                valid_status = (manifest.get("Status") == "Passed" and manifest.get("Passed") is True and
                    manifest.get("Compiled") is True and manifest.get("InputsUnchanged") is True and
                    manifest.get("ExpectedCases") == len(selected) and manifest.get("PassedCases") == len(selected) and
                    manifest.get("FailedCases") == 0 and manifest.get("Cases") == rows and
                    [row.get("Name") for row in rows] == selected and not manifest.get("InfrastructureError"))
            self.check(prefix + "completed or explicitly interrupted evidence", valid_status)
            compilation = []
            for filename in ("vlib.log", "vendor.compile.log", "rtl.compile.log", "testbenches.compile.log"):
                log = directory / "logs" / filename
                body = read_text(log)
                counts = [int(value) for value in ERROR_COUNT.findall(body)]
                compiled = (not ERROR.search(body) and not FATAL.search(body) and
                    (all(value == 0 for value in counts) and (bool(counts) or filename == "vlib.log")))
                self.check(prefix + "raw compilation " + filename, compiled)
                compilation.append({"Log": str(log), "SHA256": sha(log), "Accepted": compiled})
            run_evidence = []
            for row in rows:
                name = row.get("Name")
                self.check(prefix + "summary name in selected Core " + str(name), name in selected and name in core_by_name)
                if name not in core_by_name:
                    continue
                _, top, marker, expected_fatal = core_by_name[name]
                log = directory / relative_path(row["Log"])
                body = read_text(log)
                fatal_lines = FATAL.findall(body)
                counts = [int(n) for n in ERROR_COUNT.findall(body)]
                structure = (row.get("Top") == top and row.get("ExpectedMarker") == marker and
                    row.get("ExpectedFatal") == expected_fatal and row.get("ExpectedRejection") == bool(expected_fatal))
                ordinary = (self.marker_present(body, marker) and not ERROR.search(body) and not fatal_lines and
                    bool(counts) and all(n == 0 for n in counts) and row.get("ExitCode") == 0)
                rejection = (fatal_lines == [expected_fatal] and not ERROR.search(body) and
                    bool(re.search(r"Time:\s*0\s+(?:ps|ns)\b", body)) and f"Instance: /{top}/dut" in body and
                    bool(counts) and all(n == 1 for n in counts))
                passed = (structure and row.get("Passed") is True and row.get("TimedOut") is False and
                    not row.get("Failure") and (rejection if expected_fatal else ordinary))
                self.check(prefix + "Core raw log " + name, passed)
                record = {"Name": name, "Top": top, "SourceRun": str(directory), "Log": str(log), "LogSHA256": sha(log),
                    "ExpectedFatal": expected_fatal, "RawAccepted": passed, "TimedOut": row.get("TimedOut"),
                    "ElapsedSeconds": row.get("ElapsedSeconds")}
                evidence.append(record)
                run_evidence.append(record)
            if run_index == 0:
                self.details["SourceOriginCandidate"] = manifest.get("Project")
            self.check(prefix + "same candidate source origin", Path(manifest["Project"]).resolve() ==
                Path(self.details["SourceOriginCandidate"]).resolve())
            inputs_report = self.core_inputs(manifest, directory, interrupted, run_index == 0)
            uncompleted = []
            for name in selected:
                if name in [row.get("Name") for row in rows]:
                    continue
                log = directory / "logs" / (name + ".log")
                uncompleted.append({"Name": name, "CountsAsPass": False, "LogExists": log.exists(),
                    "LogSHA256": sha(log) if log.exists() else None,
                    "ExitCodeFileExists": (directory / "logs" / (name + ".exitcode")).exists()})
            history.append({"SourceRun": str(directory), "RawManifestStatus": manifest.get("Status"),
                "AuditClassification": "IncompleteInterrupted" if interrupted else "CompletedFiltered" if len(selected) < 33 else "CompletedCore",
                "RawWholeRunPassed": manifest.get("Passed"), "SyntheticWholeRunPassed": None,
                "ManifestSHA256": sha(directory / "manifest.json"), "SummarySHA256": sha(directory / "test-summary.json"),
                "RecordedSummaryCases": len(rows), "SelectedCaseNames": selected, "Cases": run_evidence,
                "Compilation": compilation, "UncompletedCasesNotCounted": uncompleted, **inputs_report})
        chosen = []
        for name in names:
            candidates = [item for item in evidence if item["Name"] == name and item["RawAccepted"]]
            self.check("Core independent aggregate coverage " + name, bool(candidates))
            if candidates:
                chosen.append(candidates[-1])
        self.check("Core all fixed 33 cases independently proven", len(chosen) == 33)
        self.details["CoreCases"], self.details["ModelSimHistory"] = chosen, history
        self.details["CoreCoverageAcrossRuns"] = {"AcceptedCaseCount": len(chosen), "ExpectedCaseCount": 33,
            "SyntheticWholeRunPassed": None, "Description": "Independent case evidence across unchanged-input runs; no raw manifest status rewritten."}

    def core_inputs(self, manifest, directory, interrupted, primary):
        prefix = "ModelSim " + directory.name + " "
        inputs = read_json(directory / "inputs.json")
        self.check(prefix + "manifest and standalone inputs agree", manifest.get("Inputs") == inputs)
        counts = dict(Counter(item["Kind"] for item in inputs))
        self.check(prefix + "complete 107 semantic inputs + 3 tooling inputs", counts ==
                   {"Project": 1, "RTL": 66, "Testbench": 29, "ROM": 10, "Vendor": 1, "Runner": 2, "Viewer": 1}
                   and len({item["StagedPath"] for item in inputs}) == 110 and len(inputs) == 110)
        self.check(prefix + "exact 29 bench and 10 ROM paths", {item["StagedPath"] for item in inputs if item["Kind"] == "Testbench"} == EXPECTED_BENCHES and
                   {item["StagedPath"] for item in inputs if item["Kind"] == "ROM"} == EXPECTED_ROMS)
        self.check(prefix + "exact runner/viewer paths", {item["StagedPath"] for item in inputs if item["Kind"] in ("Runner", "Viewer")} ==
                   {"scripts/test-modelsim-full.ps1", "scripts/test-modelsim-full.cmd", "sim/view_full_modelsim.do"})
        semantic, tooling = [], []
        source_root = Path(manifest["Project"]).resolve()
        for item in inputs:
            relative = relative_path(item["StagedPath"])
            snapshot = directory / relative
            original_source = Path(item["Source"]).resolve()
            current = original_source if item["Kind"] == "Vendor" else self.root / relative
            expected = item["Sha256Before"].lower()
            snapshot_hash, source_hash, current_hash = sha(snapshot), sha(original_source), sha(current)
            source_location = original_source == (Path(manifest["VendorModel"]).resolve()
                if item["Kind"] == "Vendor" else source_root / relative)
            is_tooling = item["Kind"] in ("Runner", "Viewer")
            recorded_after = item.get("Sha256After")
            original_after_valid = ((recorded_after is None and item.get("Unchanged") is None) if interrupted else
                item.get("Unchanged") is True and (recorded_after or "").lower() == expected)
            matched = (source_location and original_after_valid and snapshot_hash == source_hash == expected and
                (is_tooling or current_hash == expected))
            self.check(prefix + "input " + item["StagedPath"], matched)
            record = {"Kind": item["Kind"], "Path": item["StagedPath"], "SourceOriginCandidate": str(original_source),
                      "Snapshot": str(snapshot), "CurrentMainRootFile": str(current), "ExpectedSHA256": expected,
                      "SourceSHA256": source_hash, "SnapshotSHA256": snapshot_hash, "CurrentMainRootSHA256": current_hash,
                      "RecordedSha256After": recorded_after, "RecordedUnchanged": item.get("Unchanged"),
                      "IndependentAfterAudit": True, "CurrentMainRootMatches": current_hash == expected, "Matched": matched}
            (tooling if is_tooling else semantic).append(record)
        xml = ET.parse(self.root / "full/ContestFull.gprj")
        declared_rtl = set()
        for node in xml.findall(".//FileList/File"):
            if node.attrib.get("type") == "file.verilog" and node.attrib.get("enable") == "1":
                resolved = (self.root / "full" / node.attrib["path"]).resolve()
                declared_rtl.add(resolved.relative_to(self.root).as_posix())
        self.check(prefix + "GPRJ enabled 66 RTL sources equal staged RTL", len(declared_rtl) == 66 and declared_rtl ==
                   {item["StagedPath"] for item in inputs if item["Kind"] == "RTL"})
        fingerprints = {item["Path"]: item["SnapshotSHA256"] for item in semantic}
        if primary:
            self.primary_fingerprints = fingerprints
        else:
            self.check(prefix + "all 107 semantic fingerprints equal primary", fingerprints == self.primary_fingerprints)
        return {"ModelSimSemanticInputs107": semantic, "ModelSimToolingInputs3": tooling}

    def build_evidence(self):
        results = read_json(self.build / "build-results.json")
        metadata = read_json(self.build / "snapshot-metadata.json")
        self.details["BuildSourceOriginCandidate"] = metadata.get("sourceRoot")
        self.check("Build and ModelSim source origins identify same candidate", Path(metadata["sourceRoot"]).resolve() ==
                   Path(self.details.get("SourceOriginCandidate", "__missing_candidate__")).resolve())
        self.details["BuildResultsSHA256"] = sha(self.build / "build-results.json")
        self.check("Gowin finished accepted build", results.get("buildAccepted") is True and
                   results["run"].get("exitCode") == 0 and results["run"].get("timedOut") is False and
                   results.get("sourceInputsMatch") is True and results.get("snapshotInputsMatch") is True and
                   results.get("sourceInputFileCount") == 80 and not results.get("errorLines"))
        items = read_json(self.build / "snapshot-inputs.json")
        self.check("Gowin complete unique 80 inputs", len(items) == 80 and len({item["path"] for item in items}) == 80)
        hashes = []
        origin = Path(metadata["sourceRoot"]).resolve()
        for item in items:
            relative = relative_path(item["path"])
            snapshot, source, current = self.build / relative, origin / relative, self.root / relative
            snapshot_hash, source_hash, current_hash = sha(snapshot), sha(source), sha(current)
            expected = item["sha256"].lower()
            matched = snapshot_hash == source_hash == current_hash == expected and snapshot.stat().st_size == item["size"]
            self.check("Gowin input " + relative.as_posix(), matched)
            hashes.append({"Path": relative.as_posix(), "SourceOriginCandidate": str(source),
                           "Snapshot": str(snapshot), "CurrentMainRootFile": str(current), "ExpectedSHA256": expected,
                           "SourceSHA256": source_hash, "SnapshotSHA256": snapshot_hash,
                           "CurrentMainRootSHA256": current_hash, "Matched": matched})
        self.details["BuildInputs80"] = hashes
        artifacts = []
        report_artifacts = {Path(item["path"]).name: item for item in results["current"]["artifacts"]}
        for filename in ("ContestFull.fs", "ContestFull.tr", "ContestFull.rpt.txt"):
            path = self.build / "full/impl/pnr" / filename
            reported = report_artifacts[filename]
            actual = sha(path)
            matched = actual == reported["sha256"].lower() and path.stat().st_size == reported["size"] and path.stat().st_size > 0
            self.check("Gowin artifact " + filename, matched)
            artifacts.append({"Path": str(path), "SHA256": actual, "Bytes": path.stat().st_size, "Matched": matched})
        self.details["Artifacts"] = artifacts
        body = read_text(self.build / "full/impl/pnr/ContestFull.tr")
        endpoints = {}
        for kind in ("Setup", "Hold"):
            match = re.search(r"<Numbers of " + kind + r" Violated Endpoints>:\s*(\d+)", body)
            endpoints[kind.lower()] = int(match.group(1)) if match else None
        slack = {}
        for index, kind in enumerate(("Setup", "Hold", "Recovery", "Removal"), 1):
            # Bound the table to the next 3.x section, excluding the TOC and the
            # minimum-pulse-width table that follows the removal paths table.
            match = re.search(r"^3\.1\." + str(index) + " " + kind + r" Paths Table\r?\n(.*?)(?=^3\.)", body, re.M | re.S)
            values = re.findall(r"^\s*\d+\s+(-?\d+\.\d+)\s+", match.group(1), re.M) if match else []
            slack[kind.lower()] = min(map(float, values)) if values else None
        self.check("Raw STA 0 Setup/Hold violated endpoints", endpoints == {"setup": 0, "hold": 0} and
                   endpoints == results["current"]["violations"])
        self.check("Raw STA four nonnegative minimum slacks agree with report", all(value is not None and value >= 0 for value in slack.values()) and
                   all(abs(value - results["current"]["minimumSlackNs"].get(key, float("inf"))) < 1e-9 for key, value in slack.items()))
        build_log = read_text(self.build / "gowin-build.log")
        self.check("Raw Gowin build pass marker and no ERROR", "FULL BUILD TIMING PASS: zero setup/recovery and hold/removal violations" in build_log and
                   not re.search(r"^\s*(?:ERROR|Error|FATAL)\b", build_log, re.M))
        self.details["Timing"] = {"RawViolatedEndpoints": endpoints, "RawMinimumSlackNs": slack,
                                  "Resources": results["current"].get("resources"), "HardwareValidated": False}
        self.protected_impl(results)

    def protected_impl(self, results):
        before = read_json(self.build / "protected-impl-before.json")
        actual_dir = self.root / "full/impl"
        actual = {path.relative_to(actual_dir).as_posix(): sha(path) for path in actual_dir.rglob("*") if path.is_file()}
        expected = {relative_path(item["path"]).as_posix(): item["sha256"].lower() for item in before}
        matched = len(expected) == len(actual) == 25 and actual == expected and results.get("protectedImplUnchanged") is True
        self.check("Primary full/impl exact original 25-file set and SHA unchanged", matched)
        self.details["ProtectedPrimaryImpl25"] = [{"Path": name, "BeforeSHA256": expected[name],
            "CurrentSHA256": actual.get(name), "Matched": actual.get(name) == expected[name]} for name in sorted(expected)]
        self.details["ProtectedPrimaryImplAddedFiles"] = sorted(set(actual) - set(expected))

    def equivalence(self, name, directory, current_rtl, marker, fatal, seeds):
        summary = read_json(directory / "summary.json")
        self.check(name + " summary passed", summary.get("Passed") is True and summary.get("InputsUnchanged") is True)
        effective_key = "EffectiveDutSHA256" if name == "Watchdog" else "EffectiveRouterSHA256"
        self.check(name + " effective RTL matches current primary", summary[effective_key].lower() == sha(self.root / current_rtl))
        cases = summary["Cases"]
        self.check(name + " fixed oracle and 3 seed set", [case["Name"] for case in cases] == ["oracle_negative"] + [f"seed_{seed}" for seed in seeds])
        for case in cases:
            body = read_text(case["Log"])
            lines = FATAL.findall(body)
            positive = self.marker_present(body, marker) and not ERROR.search(body) and not lines and case["ExitCode"] == 0
            top = "tb_remote_watchdog_equivalence" if name == "Watchdog" else "tb_router_performance_equivalence"
            negative = (len(lines) == 1 and lines[0].startswith(fatal) and "Time: 96 ns" in body and
                f"Instance: /{top}" in body and not ERROR.search(body) and not self.marker_present(body, marker))
            self.check(name + " actual raw log " + case["Name"], case.get("Matched") is True and (negative if case.get("ExpectedFatal") else positive))
        inputs = []
        for item in summary["Inputs"]:
            source = Path(item.get("Source") or self.root / item["Path"])
            snapshot = Path(item.get("SnapshotPath") or directory / source.name)
            before = (item.get("Before") or item["CurrentBefore"]).lower()
            after = (item.get("After") or item["CurrentAfter"]).lower()
            snapshot_record = item["Snapshot"].lower()
            matched = before == after == snapshot_record == sha(source) == sha(snapshot)
            self.check(name + " input " + source.name, matched)
            inputs.append({"Source": str(source), "Snapshot": str(snapshot), "SHA256": before, "Matched": matched})
        self.details[name + "Equivalence"] = {"Summary": str(directory / "summary.json"), "SummarySHA256": sha(directory / "summary.json"),
            "EffectiveSourceSHA256": summary[effective_key].lower(), "Inputs": inputs, "Cases": cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--BuildDirectory", required=True, type=Path)
    parser.add_argument("--ModelSimDirectory", required=True, type=Path)
    parser.add_argument("--AdditionalModelSimDirectory", action="append", type=Path, default=[],
                        help="Completed filtered runs with identical 107 semantic fingerprints; repeat as needed")
    parser.add_argument("--CurrentMainRoot", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--Output", type=Path)
    args = parser.parse_args()
    root, build, modelsim = args.CurrentMainRoot.resolve(), args.BuildDirectory.resolve(), args.ModelSimDirectory.resolve()
    additional = [directory.resolve() for directory in args.AdditionalModelSimDirectory]
    if len(set([modelsim] + additional)) != 1 + len(additional):
        parser.error("ModelSim evidence directories must be unique")
    audit = Audit(root, build, modelsim, additional)
    audit.safe("Core regression", audit.core)
    audit.safe("Gowin build", audit.build_evidence)
    audit.safe("Watchdog equivalence", lambda: audit.equivalence("Watchdog", root / "verification/timing-20261014/watchdog_equivalence_20261014_194715_03d4ed52",
        "rtl/control/remote_note_watchdog.v", "WATCHDOG EQUIVALENCE PASS", "output mismatch cycle=10", [734921, 94177, 123456789]))
    audit.safe("Router/performance equivalence", lambda: audit.equivalence("RouterPerformance", root / "verification/timing-20261014/router_performance_equivalence_20261014_200638_461a1134",
        "rtl/control/remote_command_router.v", "ROUTER PERFORMANCE EQUIVALENCE PASS", "router/performance output mismatch cycle=10", [471833, 94177, 123456789]))
    accepted = bool(audit.checks) and all(check["Passed"] for check in audit.checks)
    output = args.Output or Path(__file__).resolve().parent / "selected-release.json"
    result = {"ReleaseAccepted": accepted, "AuditedAtUtc": datetime.now(timezone.utc).isoformat(),
              "AuditorSHA256": sha(__file__), "CurrentMainRoot": str(root), "BuildDirectory": str(build), "ModelSimDirectory": str(modelsim),
              "AdditionalModelSimDirectories": [str(directory) for directory in additional],
              "HardwareProgrammedOrValidated": False, "FixedCoreCaseCount": 33, "Checks": audit.checks, **audit.details}
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    failures = [check for check in audit.checks if not check["Passed"]]
    print(f"ReleaseAccepted={accepted}; checks={len(audit.checks)}; failed={len(failures)}; output={output}")
    for failure in failures[:12]:
        print(f"FAILED: {failure['Check']}: {failure['Details']}")
    return 0 if accepted else 1


if __name__ == "__main__":
    sys.exit(main())
