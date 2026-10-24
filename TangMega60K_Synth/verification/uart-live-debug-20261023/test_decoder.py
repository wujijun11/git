from pathlib import Path
import csv
import importlib.util
import random
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("decoder", HERE / "decode_uart_gao.py")
decoder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(decoder)


def packed(**values):
    result = 0
    for name, value in values.items():
        offset, width = decoder.FIELDS[name]
        assert 0 <= value < 1 << width
        result |= value << offset
    return result


def capture(path, words, times=None, contradictions=None, unknown_bits=None):
    with path.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(["Groups:"])
        writer.writerow(["debug_status[47:0] =", "debug_status[47]"])
        writer.writerow([])
        writer.writerow(["Data:"])
        writer.writerow(["time unit: ns", "debug_status[47:0]"] + [f"debug_status[{i}]" for i in range(47, -1, -1)] + [""])
        for index, word in enumerate(words):
            time = times[index] if times else index * 20
            if word is None:
                cells = [time, "X"] + ["X"] * 48 + [""]
            else:
                bits = [(word >> bit) & 1 for bit in range(47, -1, -1)]
                if contradictions and index in contradictions:
                    bits[47 - contradictions[index]] ^= 1
                if unknown_bits and index in unknown_bits:
                    bits[47 - unknown_bits[index]] = "X"
                cells = [time, f"{word:012X}"] + bits + [""]
            writer.writerow(cells)


class DecoderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="uart-gao-decoder-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def csv(self, filename, words, **kwargs):
        path = self.directory / filename
        capture(path, words, **kwargs)
        return path

    def test_unknown_first_sample_retains_position(self):
        report = decoder.parse_csv(self.csv("unknown.csv", [None] + [0x3F]*4))
        self.assertEqual(report["sampleCount"], 5)
        self.assertEqual(report["unknownOrInvalidSampleIndices"], [0])
        self.assertEqual(report["samples"][1]["sample_index"], 1)
        self.assertEqual(report["terminalStableRun"]["firstSample"], 1)

    def test_aggregate_bit_contradiction_rejected(self):
        report = decoder.parse_csv(self.csv("conflict.csv", [0x3F]*6, contradictions={1: 4}))
        self.assertEqual(report["contradictoryRowCount"], 1)
        self.assertEqual(report["unknownOrInvalidSampleIndices"], [1])
        self.assertEqual(report["source"]["bus_bit_mismatches"][0]["mismatched_bits"], [4])

    def test_unknown_exported_bit_rejects_known_bus(self):
        report = decoder.parse_csv(self.csv("unknownbit.csv", [0x3F]*5, unknown_bits={0: 0}))
        self.assertEqual(report["unknownOrInvalidSampleCount"], 1)
        self.assertEqual(report["source"]["partial_bit_rows"], 1)

    def test_omitted_timestamp_sample_is_not_compressed(self):
        report = decoder.parse_csv(self.csv("gap.csv", [0x3F]*5, times=[0, 20, 40, 80, 100]))
        self.assertEqual(report["inferredMissingSampleCount"], 1)
        self.assertEqual([s["sample_index"] for s in report["samples"]], [0, 1, 2, 4, 5])
        self.assertIsNone(report["terminalStableRun"])

    def test_no_longest_run_substitution_for_unknown_end(self):
        report = decoder.parse_csv(self.csv("tail.csv", [0x3F]*10 + [None]))
        self.assertIsNone(report["terminalStableRun"])

    def test_reset_observed_blocks_delta(self):
        before = self.csv("before.csv", [0x3F]*5)
        after = self.csv("after.csv", [0x37] + [0x3F]*5)
        report = decoder.compare_captures(before, after)
        self.assertIsNone(report["terminalStableModuloDelta"])
        self.assertEqual(report["after"]["observedResetSampleIndices"], [0])

    def test_counter_decrease_is_explicit(self):
        high = 0x3F | packed(rx_valid_bytes=255)
        report = decoder.parse_csv(self.csv("decrease.csv", [high]*4 + [0x3F]*4))
        self.assertEqual(report["observedCounterDecreases"][0]["field"], "rx_valid_bytes")
        self.assertIn("wrap, reset", report["observedCounterDecreases"][0]["interpretation"])
        candidate = decoder.delta(decoder.decode(high), decoder.decode(0x3F))
        self.assertEqual(candidate["rx_valid_bytes"]["moduloDelta"], 1)
        self.assertTrue(candidate["rx_valid_bytes"]["counterDecreased"])
        self.assertIn("reset", candidate["rx_valid_bytes"]["warning"])

    def test_single_readback_expected_modulo_deltas(self):
        afterword = 0x3F | packed(rx_falling_edges=41, rx_valid_bytes=16,
            last_rx_byte=0xE7, commands_accepted=1, responses_accepted=2, tx_started_bytes=32)
        report = decoder.compare_captures(self.csv("before.csv", [0x3F]*5),
            self.csv("after.csv", [afterword]*5))
        self.assertEqual(report["hardwareVerdict"], "NOT_ASSESSED")
        values = report["terminalStableModuloDelta"]
        self.assertEqual({key: values[key]["moduloDelta"] for key in values},
            {"rx_falling_edges": 41, "rx_valid_bytes": 16, "commands_accepted": 1,
             "responses_accepted": 2, "tx_started_bytes": 32})

    def test_entire_48_bit_mapping_has_no_holes(self):
        rng = random.Random(20261023)
        for _ in range(200):
            word = rng.randrange(1 << 48)
            fields = decoder.decode(word)
            self.assertEqual(packed(**{name: fields[name] for name in decoder.FIELDS}), word)

    def test_actual_export_preserves_unknown_and_compares_bits(self):
        path = HERE / "main_status_core0.csv"
        if not path.exists():
            self.skipTest("Root agent's raw baseline capture is not present.")
        report = decoder.parse_csv(path)
        self.assertEqual(report["sampleCount"], 2049)
        self.assertEqual(report["knownSampleCount"], 2048)
        self.assertEqual(report["unknownOrInvalidSampleIndices"], [0])
        self.assertEqual(report["source"]["compared_rows"], 2048)
        self.assertEqual(report["contradictoryRowCount"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
