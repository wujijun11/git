"""Synthetic algorithm checks only; no measured hardware results in this file."""
import csv
import contextlib
import io
import hashlib
import json
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
import calibrate_touch25 as cal


def make_capture():
    samples = {}
    for key in cal.load_mapping():
        channel = (int(key["mpr121_board"]), int(key["mpr121_electrode"][3:]))
        rows = []
        for env in cal.ENVIRONMENTS:
            for phase in cal.PHASES:
                for i in range(30):
                    delta = 40 + i % 3 if phase == "held" else i % 3 - 2
                    rows.append({"sample_id": len(rows), "time_ms": len(rows) * 4,
                                 "environment": env, "phase": phase, "module": channel[0],
                                 "electrode": channel[1], "filtered": 800 - delta,
                                 "baseline_raw8": 200, "delta_est": delta,
                                 "ack_ok": 1, "ovcf": 0, "oor": 0, "acff": 0, "arff": 0})
        samples[channel] = rows
    return samples


class CalibrationChecks(unittest.TestCase):
    def setUp(self):
        self.mapping = cal.load_mapping()
        self.samples = make_capture()

    def test_all_25_keys_and_ele8_register(self):
        report = cal.analyze(self.mapping, self.samples)
        self.assertEqual(report["status"], "CANDIDATES_REQUIRE_HARDWARE_RETEST")
        self.assertEqual(report["keys"][-1]["candidate"]["touch_register"], "0x51")
        for key in report["keys"]:
            candidate = key["candidate"]
            self.assertLess(key["noise_ceiling_with_3_count_uncertainty"], candidate["release_threshold"])
            self.assertLess(candidate["release_threshold"], candidate["touch_threshold"])
            self.assertLess(candidate["touch_threshold"], key["held_delta_lower_bound"])

    def test_missing_key_and_missing_loud_condition_block_candidates(self):
        del self.samples[(3, 8)]
        self.samples[(1, 0)] = [r for r in self.samples[(1, 0)] if r["environment"] != "amp_on_loud"]
        report = cal.analyze(self.mapping, self.samples)
        self.assertIsNone(report["keys"][0]["candidate"])
        self.assertIsNone(report["keys"][24]["candidate"])
        self.assertEqual(report["status"], "INCOMPLETE_OR_UNSAFE")

    def test_noise_touch_overlap_blocks_candidate(self):
        self.samples[(2, 0)][0]["delta_est"] = 45
        key = cal.analyze(self.mapping, self.samples)["keys"][8]
        self.assertEqual(key["reasons"], ["no_safe_threshold_gap"])
        self.assertIsNone(key["candidate"])

    def test_faults_block_and_other_modules_remain_reviewable(self):
        for flag in ("ack_ok",) + cal.FAULTS:
            capture = make_capture()
            capture[(2, 7)][0][flag] = 0 if flag == "ack_ok" else 1
            report = cal.analyze(self.mapping, capture)
            self.assertIsNone(report["keys"][15]["candidate"])
            self.assertIn("capture_contains_sensor_or_ack_fault", report["keys"][15]["reasons"])
            self.assertIsNotNone(report["keys"][16]["candidate"])

    def test_eight_bit_threshold_limit(self):
        for row in self.samples[(3, 8)]:
            row["delta_est"] = 900 if row["phase"] == "held" else 251
        key = cal.analyze(self.mapping, self.samples)["keys"][24]
        self.assertIsNone(key["candidate"])

    def read_rows(self, rows):
        with tempfile.TemporaryDirectory(dir=cal.ROOT / "verification", prefix="calibration_test_") as directory:
            self.assertTrue(Path(directory).resolve().is_relative_to(cal.ROOT / "verification"))
            path = Path(directory) / "capture.csv"
            with path.open("w", encoding="utf-8", newline="") as target:
                writer = csv.DictWriter(target, fieldnames=cal.COLUMNS)
                writer.writeheader()
                writer.writerows([{k: r[k] for k in cal.COLUMNS} for r in rows])
            return cal.read_samples(path, self.mapping)

    def test_baseline_shift_and_signed_delta(self):
        row = self.samples[(1, 0)][0].copy()
        row["filtered"] = 805
        self.assertEqual(self.read_rows([row])[(1, 0)][0]["delta_est"], -5)

    def test_duplicate_unused_channel_and_invalid_width_rejected(self):
        row = self.samples[(1, 0)][0].copy()
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.read_rows([row, row])
        for name, value in (("electrode", 8), ("baseline_raw8", 256), ("filtered", 1024), ("ack_ok", 2)):
            bad = row.copy()
            bad[name] = value
            with self.assertRaises(ValueError):
                self.read_rows([bad])

    def test_nonincreasing_timestamp_is_rejected(self):
        first = self.samples[(1, 0)][0].copy()
        second = self.samples[(1, 0)][1].copy()
        second["time_ms"] = first["time_ms"]
        with self.assertRaisesRegex(ValueError, "increase strictly"):
            self.read_rows([first, second])

    def test_cli_empty_capture_blocks_and_existing_report_is_preserved(self):
        with tempfile.TemporaryDirectory(dir=cal.ROOT / "verification", prefix="calibration_test_") as directory:
            self.assertTrue(Path(directory).resolve().is_relative_to(cal.ROOT / "verification"))
            capture = Path(directory) / "empty.csv"
            output = Path(directory) / "report.json"
            capture.write_text(",".join(cal.COLUMNS) + "\n", encoding="utf-8")
            args = ["calibrate_touch25.py", str(capture), "--out", str(output)]
            with patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cal.main(), 2)
            saved = output.read_bytes()
            self.assertIn(b'"candidate": null', saved)
            with patch.object(sys, "argv", args), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(cal.main(), 1)
            self.assertEqual(output.read_bytes(), saved)

    def test_cli_hashes_same_snapshots_without_rereading(self):
        with tempfile.TemporaryDirectory(dir=cal.ROOT / "verification", prefix="calibration_test_") as directory:
            self.assertTrue(Path(directory).resolve().is_relative_to(cal.ROOT / "verification"))
            capture = Path(directory) / "empty.csv"
            output = Path(directory) / "report.json"
            capture_bytes = (",".join(cal.COLUMNS) + "\n").encode()
            mapping_bytes = (cal.ROOT / "mapping.csv").read_bytes()
            snapshots = {capture: capture_bytes, cal.ROOT / "mapping.csv": mapping_bytes}
            reads = []
            def read_once(path):
                if path in reads:
                    raise AssertionError("input was reread; hashes may not match analyzed bytes")
                reads.append(path)
                return snapshots[path]
            args = ["calibrate_touch25.py", str(capture), "--out", str(output)]
            with patch.object(sys, "argv", args), patch.object(Path, "read_bytes", read_once), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(cal.main(), 2)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["capture_sha256"], hashlib.sha256(capture_bytes).hexdigest())
            self.assertEqual(report["mapping_sha256"], hashlib.sha256(mapping_bytes).hexdigest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
