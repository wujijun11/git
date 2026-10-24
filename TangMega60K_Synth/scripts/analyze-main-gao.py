"""Analyze the main-project GAO CSV sampled once per LRCLK frame.

Export CSV with hexadecimal bus values (or pass --radix explicitly). Export
timestamps are user configured, not clock measurements. Frequency estimates
assume --sample-rate, normally 48000 Hz. No result is a hardware PASS verdict.
NumPy is required only for spectrum/autocorrelation and the synthetic self-test.
"""

import argparse
import csv
import hashlib
import io
import json
import math
from pathlib import Path
import statistics


BUSES = {"debug_pcm": 16, "debug_note": 7, "debug_touch": 25,
         "voices": 7, "sensor_fault": 3}
SCALARS = ("debug_underrun", "playing")
BASES = {"hex": 16, "decimal": 10, "binary": 2, "octal": 8}


def number(token, base, width):
    token = token.strip().replace("_", "")
    if not token or any(c in token.lower() for c in "xz?"):
        return None
    value = int(token, base)
    # Some decimal exports can use signed display; normalize to the wire bits.
    if value < 0:
        if value < -(1 << (width - 1)):
            raise ValueError("signed value outside signal width")
        value += 1 << width
    if not 0 <= value < (1 << width):
        raise ValueError("value outside signal width")
    return value


def load_capture(path, radix):
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
    errors, mismatch, crosscheck = [], [], {}
    for bus, width in BUSES.items():
        name = f"{bus}[{width - 1}:0]"
        if name not in index and not all(f"{bus}[{bit}]" in index
                                        for bit in range(width)):
            raise ValueError(f"missing bus or complete bit columns: {name}")
        crosscheck[bus] = {"complete_bit_columns": all(
            f"{bus}[{bit}]" in index for bit in range(width)),
            "aggregate_present": name in index, "compared_rows": 0,
            "partial_bit_rows": 0, "mismatches": 0}
    if not all(name in index for name in SCALARS):
        raise ValueError("missing scalar columns: " + ", ".join(
            name for name in SCALARS if name not in index))
    rows = []
    for cells in records[1:]:
        if not cells or not any(cell.strip() for cell in cells):
            continue
        row_id = len(rows)
        if len(cells) != len(header):
            # A missing final comma is harmless; a shifted nonempty field is not.
            if len(cells) == len(header) - 1 and header[-1] == "":
                cells.append("")
            else:
                raise ValueError(f"row {row_id}: {len(cells)} fields, expected {len(header)}")
        def read(name, base, width):
            try:
                return number(cells[index[name]], base, width)
            except ValueError as exc:
                errors.append({"row": row_id, "signal": name,
                               "token": cells[index[name]], "error": str(exc)})
                return None
        try:
            timestamp = float(cells[0].strip())
            if not math.isfinite(timestamp):
                timestamp = None
        except ValueError:
            timestamp = None
        row = {"row": row_id, "export_time": timestamp}
        for bus, width in BUSES.items():
            aggregate = f"{bus}[{width - 1}:0]"
            value = read(aggregate, BASES[radix], width) if aggregate in index else None
            check = crosscheck[bus]
            if check["complete_bit_columns"]:
                bits = [read(f"{bus}[{bit}]", 2, 1) for bit in range(width)]
                if all(bit is not None for bit in bits):
                    reconstructed = sum(bit << position for position, bit in enumerate(bits))
                    if aggregate not in index:
                        value = reconstructed
                    elif value is not None:
                        check["compared_rows"] += 1
                        if reconstructed != value:
                            check["mismatches"] += 1
                            mismatch.append({"row": row_id, "bus": bus,
                                             "aggregate": value, "from_bits": reconstructed})
                            value = None  # Never analyze a contradictory PCM word.
                else:
                    check["partial_bit_rows"] += 1
            row[bus] = value
        for scalar in SCALARS:
            row[scalar] = read(scalar, 2, 1)
        pcm = row["debug_pcm"]
        row["pcm_signed"] = pcm - 65536 if pcm is not None and pcm >= 32768 else pcm
        rows.append(row)
    if not rows:
        raise ValueError("no sample rows")
    return rows, {"sha256": hashlib.sha256(raw).hexdigest(),
                  "header_line_1based": header_line + 1,
                  "export_time_column": header[0], "columns": named,
                  "bus_bit_crosschecks": crosscheck,
                  "bus_bit_mismatches": mismatch, "parse_errors": errors}


def timeline(rows, fs):
    times = [row["export_time"] for row in rows]
    deltas = [b - a for a, b in zip(times, times[1:])
              if a is not None and b is not None and b > a]
    step = statistics.median(deltas) if deltas else None
    usable = bool(step) and all(t is not None for t in times)
    steps = [1]
    if usable:
        for a, b in zip(times, times[1:]):
            multiple = round((b - a) / step)
            if multiple < 1 or abs((b - a) - multiple * step) > step * 0.02:
                usable = False
                break
            steps.append(multiple)
    gaps = []
    position = 0
    for i, row in enumerate(rows):
        if i:
            advance = steps[i] if usable else 1
            if advance > 1:
                gaps.append({"after_row": i - 1, "before_row": i,
                             "first_missing_sample": position + 1,
                             "missing_samples": advance - 1})
            position += advance
        row["sample_index"] = position
        row["time_seconds_assuming_sample_rate"] = position / fs
    return {"method": "export_time_spacing_normalized_to_median_step" if usable else "CSV_row_order_only",
            "export_timestamp_is_clock_measurement": False,
            "median_export_step": step, "inferred_missing_ranges": gaps,
            "inferred_missing_samples": sum(g["missing_samples"] for g in gaps),
            "positions_including_gaps": position + 1,
            "duration_seconds_assuming_sample_rate": (position + 1) / fs,
            "warning": None if usable else "Timestamp grid unusable: omitted rows cannot be located; spectral analysis disabled."}


def scalar_summary(rows, key):
    hist, changes = {}, []
    previous = object()
    for row in rows:
        value = row[key]
        label = "unknown" if value is None else str(value)
        hist[label] = hist.get(label, 0) + 1
        if value != previous:
            changes.append({"sample_index": row["sample_index"], "value": value})
        previous = value
    return {"histogram_decimal": hist, "unknown_rows": hist.get("unknown", 0),
            "transition_count": max(0, len(changes) - 1),
            "runs": changes}


def contiguous_pcm(rows):
    runs, current = [], []
    for row in rows:
        if row["pcm_signed"] is None:
            if current:
                runs.append(current)
                current = []
        else:
            if current and row["sample_index"] != current[-1]["sample_index"] + 1:
                runs.append(current)
                current = []
            current.append(row)
    if current:
        runs.append(current)
    return runs


def spectral(values, fs):
    import numpy as np
    x = np.asarray(values, dtype=float)
    count = len(x)
    if count < 128 or float(np.ptp(x)) == 0:
        return {"available": False, "reason": "fewer than 128 continuous samples or constant PCM"}
    x = x - np.mean(x)
    fft_size = 1 << (count * 8 - 1).bit_length()
    power = np.abs(np.fft.rfft(x * np.hanning(count), n=fft_size)) ** 2
    frequencies = np.fft.rfftfreq(fft_size, 1 / fs)
    low, high = 50.0, min(8000.0, fs * 0.45)
    candidates = np.flatnonzero((power[1:-1] > power[:-2]) &
                                (power[1:-1] >= power[2:])) + 1
    candidates = [int(i) for i in candidates if low <= frequencies[i] <= high]
    candidates.sort(key=lambda i: power[i], reverse=True)
    peaks = []
    for k in candidates:
        frequency = float(frequencies[k])
        if any(abs(frequency - peak["frequency_hz"]) < fs / count for peak in peaks):
            continue
        logs = np.log(np.maximum(power[k - 1:k + 2], 1e-300))
        denominator = logs[0] - 2 * logs[1] + logs[2]
        correction = 0.5 * (logs[0] - logs[2]) / denominator if denominator else 0.0
        peaks.append({"frequency_hz": float((k + correction) * fs / fft_size),
                      "relative_db": float(10 * np.log10(power[k] / max(power[candidates[0]], 1e-300)))})
        if len(peaks) == 6:
            break
    # Linear autocorrelation, normalized by overlapping signal energies.
    ac_size = 1 << (2 * count - 1).bit_length()
    spectrum = np.fft.rfft(x, n=ac_size)
    correlation = np.fft.irfft(spectrum * np.conj(spectrum), n=ac_size)[:count]
    prefix = np.concatenate(([0.0], np.cumsum(x * x)))
    max_lag = min(count // 2, int(fs / low))
    min_lag = max(2, int(fs / high))
    lags = np.arange(max_lag + 1)
    energy = np.sqrt(np.maximum(prefix[count - lags] * (prefix[count] - prefix[lags]), 1e-300))
    normalized = correlation[:max_lag + 1] / energy
    local = [i for i in range(min_lag, max_lag)
             if normalized[i] > normalized[i - 1] and normalized[i] >= normalized[i + 1]]
    best = max((float(normalized[i]) for i in local), default=0.0)
    eligible = [i for i in local if normalized[i] >= max(0.35, best * 0.95)]
    selected = eligible[0] if eligible else None
    ac = {"available": selected is not None, "search_hz": [low, high],
          "selection": "first local peak >= 0.35 and >=95% of maximum local correlation"}
    if selected is not None:
        a, b, c = normalized[selected - 1:selected + 2]
        denominator = a - 2 * b + c
        offset = float(0.5 * (a - c) / denominator) if denominator else 0.0
        ac.update({"lag_samples": selected + offset,
                   "frequency_hz": fs / (selected + offset),
                   "correlation": float(b)})
    return {"available": True, "sample_count": count, "fft_size": fft_size,
            "native_bin_width_hz": fs / count, "window": "Hann, DC removed",
            "fft_peaks": peaks, "autocorrelation": ac,
            "caution": "FFT strongest peak can be a harmonic; autocorrelation can select an octave/subharmonic. Neither alone proves MIDI note."}


def analyze(path, fs=48000.0, radix="hex", synthetic=False):
    rows, metadata = load_capture(path, radix)
    timing = timeline(rows, fs)
    known = [row["pcm_signed"] for row in rows if row["pcm_signed"] is not None]
    pcm = {"known_rows": len(known), "unknown_or_contradictory_rows": len(rows) - len(known)}
    if known:
        rms = math.sqrt(sum(value * value for value in known) / len(known))
        pcm.update({"minimum": min(known), "maximum": max(known),
                    "mean": statistics.mean(known), "rms": rms,
                    "rms_dbfs": 20 * math.log10(rms / 32768) if rms else None,
                    "unique_values": len(set(known)), "nonzero_rows": sum(value != 0 for value in known),
                    "negative_rows": sum(value < 0 for value in known),
                    "endpoint_rows": sum(value in (-32768, 32767) for value in known)})
    runs = contiguous_pcm(rows)
    pcm["continuous_ranges"] = [{"start_sample": run[0]["sample_index"],
                                  "sample_count": len(run)} for run in runs]
    longest = max(runs, key=len, default=[])
    frequency = {"available": False, "reason": "no continuous known PCM or invalid timestamp grid"}
    if longest and timing["warning"] is None:
        try:
            frequency = spectral([r["pcm_signed"] for r in longest], fs)
            frequency["start_sample"] = longest[0]["sample_index"]
        except ImportError:
            frequency = {"available": False, "reason": "NumPy unavailable; run with the bundled NumPy Python runtime"}
    dynamic = []
    for run in runs:
        for start in range(0, len(run), 256):
            window = run[start:start + 256]
            values = [r["pcm_signed"] for r in window]
            rms = math.sqrt(sum(v * v for v in values) / len(values))
            dynamic.append({"start_sample": window[0]["sample_index"], "sample_count": len(window),
                            "rms": rms, "peak": max(map(abs, values)),
                            "mean": statistics.mean(values),
                            "zero_crossings": sum((a < 0 <= b) or (a >= 0 > b)
                                                  for a, b in zip(values, values[1:]))})
    summaries = {key: scalar_summary(rows, key)
                 for key in ("debug_note", "debug_touch", "voices", "sensor_fault", *SCALARS)}
    touch_values = [row["debug_touch"] for row in rows if row["debug_touch"] is not None]
    summaries["debug_touch"]["bit_set_rows"] = {str(bit): sum(bool(value & (1 << bit))
        for value in touch_values) for bit in range(25)}
    warnings = ["48 kHz is an assumption from the selected LRCLK capture clock, not a frequency measurement.",
                "debug_note holds the last accepted note-on; note-off does not clear it.",
                "debug_underrun is sticky since reset, not a per-frame underrun pulse.",
                "This capture alone does not verify DAC pins, analog sound, or the downloaded bitstream identity."]
    if timing["warning"]:
        warnings.append(timing["warning"])
    if metadata["bus_bit_mismatches"]:
        warnings.append("Bus/bit contradictions found; contradictory signal values treated as unknown.")
    return {"format_version": 1, "hardware_verdict": "NOT_ASSESSED",
            "data_origin": "synthetic_fixture" if synthetic else "unverified_GAO_export",
            "source": {"path": str(path.resolve()), **metadata},
            "assumptions": {"sample_clock": "i2s_lrclk rising edge", "sample_rate_hz": fs,
                            "bus_radix": radix, "pcm": "signed 16-bit two's complement, transmitted left[23:8]"},
            "sample_rows": len(rows), "timeline": timing, "pcm": pcm,
            "signals": summaries, "longest_continuous_segment_spectrum": frequency,
            "dynamic_blocks_256_samples": dynamic,
            "unknown_pcm_sample_indices": [r["sample_index"] for r in rows if r["pcm_signed"] is None],
            "warnings": warnings}


def write_fixture(path, values, missing=(), unknown=(), mismatch=(), bits_only=False):
    """Synthetic fixture: deliberately reverse field order to test name lookup."""
    fields = []
    for bus, width in BUSES.items():
        if not bits_only:
            fields.append(f"{bus}[{width - 1}:0]")
        fields.extend(f"{bus}[{bit}]" for bit in range(width))
    fields.extend(SCALARS)
    fields.reverse()
    stream = io.StringIO(newline="")
    stream.write("Groups:\nSynthetic test only, not a hardware capture\n\nData:\n")
    writer = csv.writer(stream)
    writer.writerow(["time unit: us", *fields, ""])
    for i, value in enumerate(values):
        if i in missing:
            continue
        signals = {"debug_pcm": int(value) & 65535, "debug_note": 60 if i < len(values) // 2 else 84,
                   "debug_touch": 1 if i < len(values) // 2 else 1 << 24,
                   "voices": 1, "sensor_fault": 0, "debug_underrun": 0, "playing": 0}
        cells = {}
        for bus, width in BUSES.items():
            cells[f"{bus}[{width - 1}:0]"] = f"{signals[bus]:X}"
            for bit in range(width):
                cells[f"{bus}[{bit}]"] = str((signals[bus] >> bit) & 1)
        cells.update({key: str(signals[key]) for key in SCALARS})
        if i in unknown:
            cells["debug_pcm[15:0]"] = "X"
            cells["debug_pcm[15]"] = "Z"
        if i in mismatch:
            cells["debug_pcm[0]"] = str(1 - (signals["debug_pcm"] & 1))
        writer.writerow([i, *(cells[field] for field in fields), ""])
    path.write_text(stream.getvalue(), encoding="utf-8-sig")


def self_test(directory):
    import numpy as np
    directory.mkdir(parents=True, exist_ok=True)
    signed = directory / "synthetic-signed.csv"
    expected = [0, 1, 32767, -32768, -1, -32767, 256, -256]
    write_fixture(signed, expected)
    rows, meta = load_capture(signed, "hex")
    assert [r["pcm_signed"] for r in rows] == expected
    assert not meta["bus_bit_mismatches"]
    assert rows[0]["debug_touch"] == 1 and rows[-1]["debug_touch"] == 1 << 24
    bits = directory / "synthetic-bits-only.csv"
    write_fixture(bits, expected, bits_only=True)
    assert [r["pcm_signed"] for r in load_capture(bits, "hex")[0]] == expected
    n = np.arange(4096)
    values = np.rint(12000 * np.sin(2 * np.pi * 1000 * n / 48000)).astype(int)
    tone = directory / "synthetic-1000Hz.csv"
    write_fixture(tone, values)
    result = analyze(tone, synthetic=True)
    frequency = result["longest_continuous_segment_spectrum"]
    assert abs(frequency["fft_peaks"][0]["frequency_hz"] - 1000) < 0.5
    assert abs(frequency["autocorrelation"]["frequency_hz"] - 1000) < 0.5
    assert result["pcm"]["minimum"] == -12000 and result["pcm"]["maximum"] == 12000
    assert result["hardware_verdict"] == "NOT_ASSESSED"
    errors = directory / "synthetic-gaps-XZ-mismatch.csv"
    write_fixture(errors, values, missing=(777,), unknown=(500,), mismatch=(1000,))
    damaged = analyze(errors, synthetic=True)
    assert damaged["sample_rows"] == 4095
    assert damaged["timeline"]["positions_including_gaps"] == 4096
    assert damaged["timeline"]["inferred_missing_samples"] == 1
    assert damaged["unknown_pcm_sample_indices"] == [500, 1000]
    assert damaged["source"]["bus_bit_crosschecks"]["debug_pcm"]["mismatches"] == 1
    assert damaged["pcm"]["continuous_ranges"] == [
        {"start_sample": 0, "sample_count": 500},
        {"start_sample": 501, "sample_count": 276},
        {"start_sample": 778, "sample_count": 222},
        {"start_sample": 1001, "sample_count": 3095}]
    for name, data in (("synthetic-tone-analysis.json", result),
                       ("synthetic-damaged-analysis.json", damaged)):
        (directory / name).write_text(json.dumps(data, indent=2, allow_nan=False), encoding="utf-8")
    summary = {"result": "SYNTHETIC_TESTS_PASS", "hardware_verdict": "NOT_ASSESSED",
               "checks": ["signed PCM including -32768 and -1", "bit names irrespective of column order",
                          "complete bit-only bus reconstruction", "touch bit0 versus bit24",
                          "1000Hz FFT and autocorrelation", "X/Z retained at original sample",
                          "omitted CSV row retained as time gap", "bus/bit mismatch invalidated"],
               "fft_hz": frequency["fft_peaks"][0]["frequency_hz"],
               "autocorrelation_hz": frequency["autocorrelation"]["frequency_hz"]}
    (directory / "self-test-result.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", nargs="?", type=Path)
    parser.add_argument("--output", type=Path, help="JSON output; default stdout")
    parser.add_argument("--sample-rate", type=float, default=48000.0)
    parser.add_argument("--radix", choices=BASES, default="hex")
    parser.add_argument("--synthetic", action="store_true", help="label input as a synthetic fixture")
    parser.add_argument("--self-test", type=Path, metavar="DIRECTORY")
    args = parser.parse_args()
    if args.sample_rate <= 0 or not math.isfinite(args.sample_rate):
        parser.error("sample rate must be finite and positive")
    if args.self_test:
        result = self_test(args.self_test)
    else:
        if not args.capture:
            parser.error("capture path or --self-test DIRECTORY required")
        result = analyze(args.capture, args.sample_rate, args.radix, args.synthetic)
    output = json.dumps(result, indent=2, allow_nan=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output + "\n", encoding="utf-8")
        print(str(args.output.resolve()))
    else:
        print(output)


if __name__ == "__main__":
    main()
