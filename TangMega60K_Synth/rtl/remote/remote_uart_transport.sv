`timescale 1ns/1ps
// V1 fixed 16-byte control transport. No duplicate filtering: the router must
// replay the prior ACK for a retransmitted request without applying it twice.
module remote_uart_rx #(
    parameter integer CLK_HZ = 49152000,
    parameter integer BAUD = 115200
)(
    input wire clk, input wire reset, input wire rx,
    output reg [7:0] data, output reg valid, output reg framing_error
);
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    reg rx_meta, rx_sync;
    reg [2:0] state, bit_index;
    reg [31:0] timer;
    reg [7:0] shift;
    always @(posedge clk) begin
        if (reset) begin
            rx_meta <= 1; rx_sync <= 1; state <= 0; timer <= 0;
            bit_index <= 0; shift <= 0; data <= 0; valid <= 0;
            framing_error <= 0;
        end else begin
            rx_meta <= rx; rx_sync <= rx_meta;
            valid <= 0; framing_error <= 0;
            case (state)
                0: if (!rx_sync) begin timer <= DIV/2-1; state <= 1; end
                1: if (timer != 0) timer <= timer-1;
                   else if (!rx_sync) begin timer <= DIV-1; bit_index <= 0; state <= 2; end
                   else state <= 0;
                2: if (timer != 0) timer <= timer-1;
                   else begin
                       shift[bit_index] <= rx_sync; timer <= DIV-1;
                       if (bit_index == 7) state <= 3;
                       else bit_index <= bit_index+1;
                   end
                3: if (timer != 0) timer <= timer-1;
                   else begin
                       if (rx_sync) begin data <= shift; valid <= 1; state <= 0; end
                       else begin framing_error <= 1; state <= 4; end
                   end
                // A break generates one error, then requires idle before retry.
                4: if (rx_sync) state <= 0;
                default: state <= 0;
            endcase
        end
    end
endmodule

module remote_uart_tx #(
    parameter integer CLK_HZ = 49152000,
    parameter integer BAUD = 115200
)(
    input wire clk, input wire reset, input wire [7:0] data,
    input wire start, output wire busy, output wire tx
);
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    reg [9:0] shift;
    reg [3:0] remaining;
    reg [31:0] timer;
    assign busy = remaining != 0;
    assign tx = busy ? shift[0] : 1'b1;
    always @(posedge clk) begin
        if (reset) begin shift <= 10'h3ff; remaining <= 0; timer <= 0; end
        else if (!busy) begin
            if (start) begin shift <= {1'b1,data,1'b0}; remaining <= 10; timer <= DIV-1; end
        end else if (timer != 0) timer <= timer-1;
        else begin
            shift <= {1'b1,shift[9:1]}; remaining <= remaining-1;
            timer <= DIV-1;
        end
    end
endmodule

module remote_uart_transport #(
    parameter integer CLK_HZ = 49152000,
    parameter integer BAUD = 115200,
    parameter integer CMD_FIFO_DEPTH = 4,
    parameter integer RX_TIMEOUT_BITS = 32
)(
    input wire clk, input wire reset, input wire rx, output wire tx,
    output wire cmd_valid, input wire cmd_ready,
    output wire [7:0] cmd_seq, output wire [7:0] cmd_opcode,
    output wire [79:0] cmd_payload,
    input wire rsp_valid, output wire rsp_ready,
    input wire [7:0] rsp_seq, input wire [7:0] rsp_opcode,
    input wire [79:0] rsp_payload,
    output reg [31:0] crc_error_count,
    output reg [31:0] framing_error_count,
    output reg [31:0] overflow_count,
    output reg [31:0] timeout_count,
    output reg overflow_pulse
);
    localparam integer DIV = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer TIMEOUT_CYCLES = DIV * RX_TIMEOUT_BITS;
    localparam integer PTR_BITS = CMD_FIFO_DEPTH <= 1 ? 1 : $clog2(CMD_FIFO_DEPTH);
    function automatic [7:0] crc8_byte(input [7:0] crc, input [7:0] value);
        reg [7:0] c; integer b;
        begin c = crc ^ value;
            for (b=0;b<8;b=b+1) c = c[7] ? (c << 1) ^ 8'h07 : c << 1;
            crc8_byte = c;
        end
    endfunction
    function automatic [7:0] response_crc(input [7:0] seq, input [7:0] op, input [79:0] payload);
        reg [7:0] c; integer b;
        begin
            c=crc8_byte(0,1); c=crc8_byte(c,seq); c=crc8_byte(c,op);
            for (b=0;b<10;b=b+1) c=crc8_byte(c,payload[b*8+:8]);
            response_crc=c;
        end
    endfunction
    wire [7:0] rx_byte;
    wire rx_valid, rx_framing;
    remote_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) receiver
        (.clk(clk),.reset(reset),.rx(rx),.data(rx_byte),.valid(rx_valid),.framing_error(rx_framing));
    reg [4:0] index;
    reg [31:0] timeout_timer;
    reg [7:0] packet_seq, packet_opcode, crc;
    reg [79:0] packet_payload;
    reg [95:0] fifo [0:CMD_FIFO_DEPTH-1];
    reg [PTR_BITS-1:0] head, tail;
    reg [PTR_BITS:0] count;
    wire pop = cmd_valid && cmd_ready;
    wire complete = rx_valid && index == 15 && rx_byte == crc && !rx_framing;
    wire push = complete && (count < CMD_FIFO_DEPTH || pop);
    assign cmd_valid = count != 0;
    assign {cmd_payload,cmd_opcode,cmd_seq} = fifo[head];
    always @(posedge clk) begin
        if (reset) begin
            index<=0; timeout_timer<=0; packet_seq<=0; packet_opcode<=0;
            packet_payload<=0; crc<=0; head<=0; tail<=0; count<=0;
            crc_error_count<=0; framing_error_count<=0;
            overflow_count<=0; timeout_count<=0; overflow_pulse<=0;
        end else begin
            overflow_pulse<=0;
            case ({push,pop})
                2'b10: count<=count+1;
                2'b01: count<=count-1;
                default: count<=count;
            endcase
            if (pop) head <= head == CMD_FIFO_DEPTH-1 ? 0 : head+1;
            if (push) begin
                fifo[tail]<={packet_payload,packet_opcode,packet_seq};
                tail <= tail == CMD_FIFO_DEPTH-1 ? 0 : tail+1;
            end
            if (complete && !push) begin overflow_count<=overflow_count+1; overflow_pulse<=1; end
            if (rx_framing) begin
                framing_error_count<=framing_error_count+1; index<=0; timeout_timer<=0;
            end else if (rx_valid) begin
                timeout_timer<=0;
                case (index)
                    0: if (rx_byte == 8'ha5) index<=1;
                    1: if (rx_byte == 8'h5a) index<=2;
                       else if (rx_byte != 8'ha5) index<=0;
                    2: if (rx_byte == 1) begin crc<=crc8_byte(0,rx_byte); index<=3; end
                       else begin framing_error_count<=framing_error_count+1; index<=0; end
                    3: begin packet_seq<=rx_byte; crc<=crc8_byte(crc,rx_byte); index<=4; end
                    4: begin packet_opcode<=rx_byte; crc<=crc8_byte(crc,rx_byte); index<=5; end
                    15: begin
                        if (rx_byte != crc) crc_error_count<=crc_error_count+1;
                        index<=0;
                    end
                    default: begin
                        packet_payload[(index-5)*8+:8]<=rx_byte;
                        crc<=crc8_byte(crc,rx_byte); index<=index+1;
                    end
                endcase
            end else if (index != 0) begin
                if (timeout_timer == TIMEOUT_CYCLES-1) begin
                    timeout_count<=timeout_count+1; timeout_timer<=0; index<=0;
                end else timeout_timer<=timeout_timer+1;
            end
        end
    end
    // One response slot plus the active UART byte. Inputs are only sampled on
    // rsp_valid && rsp_ready; their owner must hold them stable while stalled.
    reg [127:0] tx_packet;
    reg [4:0] tx_index;
    reg tx_active, tx_start;
    reg [7:0] tx_byte;
    wire tx_busy;
    assign rsp_ready = !tx_active;
    remote_uart_tx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) transmitter
        (.clk(clk),.reset(reset),.data(tx_byte),.start(tx_start),.busy(tx_busy),.tx(tx));
    always @(posedge clk) begin
        if (reset) begin tx_packet<=0; tx_index<=0; tx_active<=0; tx_start<=0; tx_byte<=0; end
        else begin
            tx_start<=0;
            if (rsp_valid && rsp_ready) begin
                tx_packet<={response_crc(rsp_seq,rsp_opcode,rsp_payload),rsp_payload,rsp_opcode,rsp_seq,8'h01,8'h5a,8'ha5};
                tx_index<=0; tx_active<=1;
            end
            if (tx_active && !tx_busy && !tx_start) begin
                tx_byte<=tx_packet[tx_index*8+:8]; tx_start<=1;
                if (tx_index == 15) tx_active<=0;
                else tx_index<=tx_index+1;
            end
        end
    end
endmodule
