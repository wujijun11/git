"""Prepare an isolated, passive 48-bit UART GAO full-main observation source.

This script neither invokes Gowin nor accesses a device. It refuses to replace
an existing source copy. Production source files and old snapshots stay intact.
"""
from pathlib import Path
import difflib
import hashlib
import importlib.util
import json
import shutil
import sys
import xml.etree.ElementTree as ET

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
SOURCE = HERE / "observation-source"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def dump(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def replace_once(text, before, after):
    assert text.count(before) == 1, repr(before)
    return text.replace(before, after, 1)


assert not SOURCE.exists(), "Refuse to overwrite an existing observation source."
driver = PROJECT / "scripts/build-contest-isolated.py"
spec = importlib.util.spec_from_file_location("isolated_driver", driver)
module = importlib.util.module_from_spec(spec)
sys.dont_write_bytecode = True
spec.loader.exec_module(module)
gprj = PROJECT / "full/ContestFull.gprj"
files = {gprj, PROJECT / "scripts/build-contest-full.tcl"}
for entry in ET.parse(gprj).getroot().findall("./FileList/File"):
    if entry.get("enable", "1") == "1":
        dependency = (gprj.parent / entry.attrib["path"]).resolve()
        assert dependency.is_relative_to(PROJECT.resolve())
        files.add(dependency)
files.update(PROJECT / "rtl/audio/rom" / name for name in module.ROMS)
files.add(PROJECT / "rtl/visual/goertzel_1024_64.hex")
assert len(files) == 81, len(files)
baseline = []
for origin in sorted(files):
    relative = origin.relative_to(PROJECT)
    target = SOURCE / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(origin, target)
    baseline.append({"path": relative.as_posix(), "size": origin.stat().st_size,
                     "sha256": sha(origin)})
dump(HERE / "baseline-inputs.json", baseline)

uart = SOURCE / "rtl/remote/remote_uart_transport.sv"
text = uart.read_text(encoding="utf-8")
text = replace_once(text,
    "    output reg [7:0] data, output reg valid, output reg framing_error\n",
    "    output reg [7:0] data, output reg valid, output reg framing_error,\n"
    "    output wire debug_rx_sync\n")
text = replace_once(text,
    "    reg rx_meta, rx_sync;\n",
    "    reg rx_meta, rx_sync;\n    assign debug_rx_sync = rx_sync;\n")
text = replace_once(text,
    "    output reg overflow_pulse\n",
    "    output reg overflow_pulse,\n    output wire [43:0] debug_uart_status\n")
text = replace_once(text,
    "    wire rx_valid, rx_framing;\n",
    "    wire rx_valid, rx_framing, debug_rx_sync;\n")
text = replace_once(text,
    ".data(rx_byte),.valid(rx_valid),.framing_error(rx_framing));",
    ".data(rx_byte),.valid(rx_valid),.framing_error(rx_framing),\n"
    "         .debug_rx_sync(debug_rx_sync));")
debug = """    // Passive-only full-main observation. These registers never feed any
    // command, response, reset, UART state machine or external output.
    // Event counters wrap modulo 256 (RX/TX) or 8 (commands/responses).
    // debug_rx_sync is the receiver's existing second synchronizer stage.
    reg debug_rx_previous;
    reg [7:0] debug_rx_edge_count, debug_rx_byte_count;
    reg [7:0] debug_tx_byte_count, debug_last_rx_byte;
    reg [2:0] debug_cmd_count, debug_rsp_count;
    wire [3:0] debug_errors = {timeout_count!=0,overflow_count!=0,
        framing_error_count!=0,crc_error_count!=0};
    assign debug_uart_status = {debug_errors,debug_tx_byte_count,
        debug_rsp_count,debug_cmd_count,debug_last_rx_byte,
        debug_rx_byte_count,debug_rx_edge_count,tx,rx};
    always @(posedge clk) begin
        if (reset) begin
            debug_rx_previous<=1; debug_rx_edge_count<=0;
            debug_rx_byte_count<=0; debug_tx_byte_count<=0;
            debug_last_rx_byte<=0; debug_cmd_count<=0; debug_rsp_count<=0;
        end else begin
            debug_rx_previous<=debug_rx_sync;
            if (debug_rx_previous && !debug_rx_sync)
                debug_rx_edge_count<=debug_rx_edge_count+1'b1;
            if (rx_valid) begin
                debug_rx_byte_count<=debug_rx_byte_count+1'b1;
                debug_last_rx_byte<=rx_byte;
            end
            if (cmd_valid && cmd_ready) debug_cmd_count<=debug_cmd_count+1'b1;
            if (rsp_valid && rsp_ready) debug_rsp_count<=debug_rsp_count+1'b1;
            if (tx_start && !tx_busy) debug_tx_byte_count<=debug_tx_byte_count+1'b1;
        end
    end
"""
text = replace_once(text, "    assign rsp_ready = !tx_active;\n",
    "    assign rsp_ready = !tx_active;\n" + debug)
uart.write_text(text, encoding="utf-8", newline="\n")

system = SOURCE / "rtl/instrument_full_system.v"
text = system.read_text(encoding="utf-8")
text = replace_once(text,
    "    output wire [3:0] debug_audio_reset_status\n",
    "    output wire [3:0] debug_audio_reset_status,\n"
    "    output wire [43:0] debug_uart_status\n")
text = replace_once(text,
    ".overflow_count(uart_overflows),.timeout_count(uart_timeouts),.overflow_pulse(uart_overflow));",
    ".overflow_count(uart_overflows),.timeout_count(uart_timeouts),.overflow_pulse(uart_overflow),\n"
    "        .debug_uart_status(debug_uart_status));")
system.write_text(text, encoding="utf-8", newline="\n")

top = SOURCE / "rtl/board/board_contest_full_top.v"
text = top.read_text(encoding="utf-8")
text = replace_once(text,
    "    wire [3:0] debug_audio_reset_status;\n",
    "    wire [3:0] debug_audio_reset_status;\n    wire [43:0] debug_uart_status;\n")
text = replace_once(text,
    """        debug_status_meta<={i2s_data,i2s_lrclk,i2s_bclk,debug_audio_heartbeat[8],
            debug_pll_status,debug_note,voices,sensor_fault,sensor_ready,
            guide,playing,pressed_sync,pressed_50,debug_audio_reset_status,
            rst_n,ready_sync,audio_locked,board_ready};""",
    """        // The existing two-stage sys_clk GAO sampler is unchanged.
        // Multi-bit observation fields are coherent only while stable.
        debug_status_meta<={debug_uart_status,rst_n,ready_sync,audio_locked,board_ready};""")
text = replace_once(text,
    ".debug_audio_reset_status(debug_audio_reset_status));",
    ".debug_audio_reset_status(debug_audio_reset_status),.debug_uart_status(debug_uart_status));")
top.write_text(text, encoding="utf-8", newline="\n")

# Same 48 capture wires, sample clock, memory, trigger and first-stage CDC
# constraints. A distinct analyzer ID avoids confusing the bus interpretation.
rao = SOURCE / "full/main_status.rao"
text = rao.read_text(encoding="utf-8")
text = replace_once(text, "<GAO_ID>0110110101010000</GAO_ID>",
    "<GAO_ID>0101010101000100</GAO_ID>")
rao.write_text(text, encoding="utf-8", newline="\n")

baseline_uart = (PROJECT / "rtl/remote/remote_uart_transport.sv").read_text(encoding="utf-8")
for name in ("remote_uart_transport", "remote_uart_rx", "remote_uart_tx"):
    baseline_uart = baseline_uart.replace(name, "baseline_" + name)
(HERE / "baseline_remote_uart_transport.sv").write_text(baseline_uart, encoding="utf-8", newline="\n")

diffs, inventory = [], []
for entry in baseline:
    original, target = PROJECT / entry["path"], SOURCE / entry["path"]
    assert sha(original) == entry["sha256"], "Production source changed during preparation."
    inventory.append({**entry, "sourceSha256": sha(target), "changed": sha(target) != entry["sha256"]})
    if inventory[-1]["changed"]:
        diffs.extend(difflib.unified_diff(original.read_text(encoding="utf-8").splitlines(True),
            target.read_text(encoding="utf-8").splitlines(True),
            fromfile="main/" + entry["path"], tofile="observation-source/" + entry["path"]))
assert [entry["path"] for entry in inventory if entry["changed"]] == [
    "full/main_status.rao", "rtl/board/board_contest_full_top.v",
    "rtl/instrument_full_system.v", "rtl/remote/remote_uart_transport.sv"]
dump(HERE / "source-inputs.json", inventory)
(HERE / "observation.diff").write_text("".join(diffs), encoding="utf-8")
print(json.dumps({"source": str(SOURCE), "files": len(inventory), "changed": 4,
    "gaoId": "5544", "driverSha256": sha(driver)}))
