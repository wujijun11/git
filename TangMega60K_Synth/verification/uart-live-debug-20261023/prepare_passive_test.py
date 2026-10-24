"""Create a test outside the frozen 81-input source; never run Gowin."""
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
target = HERE / "tb_uart_gao_passive.sv"
assert not target.exists(), "Refuse to overwrite a test."
text = (PROJECT / "verification/c3-diagnostic-20261022/uart-observation-tests/tb_remote_uart_transport.sv").read_text(encoding="utf-8")
text = text.replace("wire [42:0] debug_uart_status;", "wire [43:0] debug_uart_status;")
start = text.index("    reg [7:0] expected_rx=")
end = text.index("    wire [7:0] monitor_data;", start)
text = text[:start] + """    reg [7:0] expected_edge=0,expected_rx=0,expected_tx=0,expected_last=0;
    reg [2:0] expected_cmd=0,expected_rsp=0;
    reg expected_rx_previous=1;
    reg [43:0] expected_status;
    always @(posedge clk) begin
        if(reset) begin
            expected_edge=0;expected_rx=0;expected_cmd=0;
            expected_rsp=0;expected_tx=0;expected_last=0;expected_rx_previous=1;
        end else begin
            if(expected_rx_previous && !dut.debug_rx_sync)expected_edge=expected_edge+1'b1;
            expected_rx_previous=dut.debug_rx_sync;
            if(dut.rx_valid)begin expected_rx=expected_rx+1'b1;expected_last=dut.rx_byte;end
            if(cmd_valid && cmd_ready)expected_cmd=expected_cmd+1'b1;
            if(rsp_valid && rsp_ready)expected_rsp=expected_rsp+1'b1;
            if(dut.tx_start && !dut.tx_busy)expected_tx=expected_tx+1'b1;
        end
        #2;
        expected_status={timeout_count!=0,overflow_count!=0,
            framing_error_count!=0,crc_error_count!=0,
            expected_tx,expected_rsp,expected_cmd,expected_last,
            expected_rx,expected_edge,tx,rx};
        if(debug_uart_status!==expected_status)
            $fatal(1,"debug status mismatch got=%h expected=%h",debug_uart_status,expected_status);
        if({tx,cmd_valid,rsp_ready,overflow_pulse,cmd_seq,cmd_opcode,cmd_payload,
            crc_error_count,framing_error_count,overflow_count,timeout_count} !==
            {baseline_tx,baseline_cmd_valid,baseline_rsp_ready,baseline_overflow_pulse,
            baseline_cmd_seq,baseline_cmd_opcode,baseline_cmd_payload,
            baseline_crc,baseline_framing,baseline_overflow,baseline_timeout})
            $fatal(1,"passive transport differs from untouched original");
    end
""" + text[end:]
text = text.replace("if(debug_uart_status[42:35]!==8'd60 || debug_uart_status[10:3]!==8'h43)",
    "if(debug_uart_status[17:10]!==8'd60 || debug_uart_status[25:18]!==8'h43)")
text = text.replace("// Exercise modulo-256 observation totals with actual serial bytes.",
    "// Exercise modulo-256 RX byte and physical-edge totals with actual serial bytes.")
text = text.replace("PASS: default parameter is cycle-equivalent to untouched original; observation events/reset/wrap correct",
    "PASS: passive observation is cycle-equivalent to untouched current main; RX edges/bytes, cmd/rsp, TX bytes, errors/reset/wrap correct")
target.write_text(text, encoding="utf-8", newline="\n")
print(target)
