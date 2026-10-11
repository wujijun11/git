`timescale 1ns/1ps
module tb_remote_uart_transport;
    localparam integer DIV=427;
    reg clk=0; always #10 clk=~clk;
    reg reset=1, rx=1, cmd_ready=0, rsp_valid=0;
    wire tx, cmd_valid, rsp_ready, overflow_pulse;
    wire [7:0] cmd_seq,cmd_opcode;
    wire [79:0] cmd_payload;
    reg [7:0] rsp_seq=0,rsp_opcode=0;
    reg [79:0] rsp_payload=0;
    wire [31:0] crc_error_count,framing_error_count,overflow_count,timeout_count;
    remote_uart_transport #(.CMD_FIFO_DEPTH(2)) dut(.*);
    wire [7:0] monitor_data; wire monitor_valid,monitor_framing;
    remote_uart_rx monitor(.clk(clk),.reset(reset),.rx(tx),.data(monitor_data),.valid(monitor_valid),.framing_error(monitor_framing));
    reg [7:0] captured[0:63]; integer captured_count=0;
    always @(posedge clk) if (!reset && monitor_valid) begin
        captured[captured_count]=monitor_data; captured_count=captured_count+1;
    end
    function automatic [7:0] crcbyte(input [7:0] c0,input [7:0] b);
        reg [7:0] c; integer i;
        begin c=c0^b; for(i=0;i<8;i=i+1)c=c[7]?(c<<1)^8'h07:c<<1; crcbyte=c; end
    endfunction
    task cycles(input integer n); begin repeat(n) @(posedge clk); #1; end endtask
    task byte_in(input [7:0] value,input bit goodstop);
        integer b;
        begin @(negedge clk); rx=0; cycles(DIV);
            for(b=0;b<8;b=b+1)begin rx=value[b];cycles(DIV);end
            rx=goodstop;cycles(DIV);rx=1;cycles(4);
        end
    endtask
    task jitter_byte(input [7:0] value,input integer bitdiv);
        integer b;
        begin @(negedge clk);rx=0;cycles(bitdiv);
            for(b=0;b<8;b=b+1)begin rx=value[b];cycles(bitdiv);end
            rx=1;cycles(bitdiv);cycles(4);
        end
    endtask
    task packet(input [7:0] seq,input [7:0] op,input [79:0] payload,input bit corrupt);
        reg [7:0] c; integer b;
        begin byte_in(8'ha5,1);byte_in(8'h5a,1);byte_in(1,1);c=crcbyte(0,1);
            byte_in(seq,1);c=crcbyte(c,seq);byte_in(op,1);c=crcbyte(c,op);
            for(b=0;b<10;b=b+1)begin byte_in(payload[b*8+:8],1);c=crcbyte(c,payload[b*8+:8]);end
            byte_in(c ^ (corrupt?8'h80:8'h00),1);cycles(20);
        end
    endtask
    task expect_cmd(input [7:0] seq,input [7:0] op,input [79:0] payload);
        begin if(!cmd_valid || cmd_seq!==seq || cmd_opcode!==op || cmd_payload!==payload)
            $fatal(1,"command mismatch seq=%h op=%h payload=%h",cmd_seq,cmd_opcode,cmd_payload);
        end
    endtask
    task pop;begin @(negedge clk);cmd_ready=1;cycles(1);@(negedge clk);cmd_ready=0;cycles(1);end endtask
    reg [7:0] c; integer i; reg [95:0] held;
    initial begin
        cycles(8);reset=0;cycles(8);
        if(tx!==1 || cmd_valid || crc_error_count || overflow_count)$fatal(1,"reset state");
        // Noise, overlapping sync, little endian payload, FIFO stability.
        byte_in(8'h43,1);byte_in(8'ha5,1);
        packet(8'h35,8'h02,80'h09080706050403020100,0);
        expect_cmd(8'h35,2,80'h09080706050403020100);
        held={cmd_payload,cmd_opcode,cmd_seq};cycles(500);
        if({cmd_payload,cmd_opcode,cmd_seq}!==held)$fatal(1,"stalled command changed");
        // The transport MUST forward repeated seq/op packets for router ACK replay.
        packet(8'h35,8'h02,80'h09080706050403020100,0);
        packet(8'h36,1,0,0);
        if(overflow_count!=1)$fatal(1,"overflow not exposed");
        expect_cmd(8'h35,2,80'h09080706050403020100);pop();
        expect_cmd(8'h35,2,80'h09080706050403020100);pop();
        if(cmd_valid)$fatal(1,"extra command after overflow");
        // A full FIFO can accept a new packet in the same cycle its head pops.
        packet(8'h37,1,0,0);packet(8'h38,1,0,0);
        fork
            packet(8'h39,1,0,0);
            begin
                wait(dut.rx_valid && dut.index==15);
                @(negedge clk);cmd_ready=1;cycles(1);
                @(negedge clk);cmd_ready=0;
            end
        join
        if(overflow_count!=1)$fatal(1,"simultaneous FIFO pop/push counted as overflow");
        expect_cmd(8'h38,1,0);pop();expect_cmd(8'h39,1,0);pop();
        packet(8'h40,1,0,1);
        if(cmd_valid || crc_error_count!=1)$fatal(1,"CRC invalid command admitted");
        byte_in(8'ha5,1);byte_in(8'h5a,1);byte_in(2,1);
        if(cmd_valid || framing_error_count!=1)$fatal(1,"version invalid admitted");
        byte_in(8'ha5,1);byte_in(8'h5a,1);byte_in(1,0);cycles(DIV*2);
        if(cmd_valid || framing_error_count!=2)$fatal(1,"bad stop not discarded");
        byte_in(8'ha5,1);byte_in(8'h5a,1);byte_in(1,1);cycles(DIV*34);
        if(timeout_count!=1)$fatal(1,"timeout not counted");
        packet(8'h41,4,80'h08,0);expect_cmd(8'h41,4,80'h08);pop();
        // False start below half a bit must not report an error.
        @(negedge clk);rx=0;cycles(30);rx=1;cycles(DIV*2);
        if(framing_error_count!=2)$fatal(1,"short glitch became framing error");
        // Sender baud +/- ~1.6% and per-byte timing changes stay inside the
        // receiver sampling margin; payload ordering and CRC remain correct.
        jitter_byte(8'ha5,420);jitter_byte(8'h5a,434);jitter_byte(1,420);c=crcbyte(0,1);
        jitter_byte(8'h42,434);c=crcbyte(c,8'h42);jitter_byte(8'h03,420);c=crcbyte(c,8'h03);
        for(i=0;i<10;i=i+1)begin jitter_byte(i,(i%2)?420:434);c=crcbyte(c,i);end
        jitter_byte(c,420);cycles(20);expect_cmd(8'h42,3,80'h09080706050403020100);pop();
        // Check TX payload and CRC, and hold a second response during TX stalls.
        @(negedge clk);rsp_seq=8'hab;rsp_opcode=8'h81;rsp_payload=80'hffeeddccbbaa99887766;rsp_valid=1;
        cycles(1);@(negedge clk);rsp_valid=0;cycles(2);
        if(rsp_ready)$fatal(1,"TX did not exert backpressure");
        @(negedge clk);rsp_seq=8'hac;rsp_opcode=8'h80;rsp_payload=80'h000004;rsp_valid=1;
        while(!rsp_ready)cycles(1);
        cycles(1);@(negedge clk);rsp_valid=0;
        while(captured_count<32)cycles(1);
        if(captured[0]!=8'ha5 || captured[1]!=8'h5a || captured[2]!=1 || captured[3]!=8'hab || captured[4]!=8'h81)
            $fatal(1,"TX header mismatch");
        c=0;for(i=2;i<15;i=i+1)c=crcbyte(c,captured[i]);
        if(captured[15]!=c || captured[5]!=8'h66 || captured[14]!=8'hff)$fatal(1,"TX data or CRC mismatch");
        if(captured[19]!=8'hac || captured[20]!=8'h80 || captured[21]!=4 || captured[22]!=0)$fatal(1,"stalled response lost");
        if(monitor_framing)$fatal(1,"TX framing");
        // Reset aborts an unfinished packet, empties FIFO and clears counters.
        byte_in(8'ha5,1);reset=1;cycles(3);reset=0;cycles(3);
        if(cmd_valid || crc_error_count || framing_error_count || overflow_count || timeout_count)$fatal(1,"reset counters");
        packet(8'h55,5,80'h7f18,0);expect_cmd(8'h55,5,80'h7f18);pop();
        $display("ALL REMOTE UART TESTS PASSED (default 49.152MHz/115200, DIV=427)");$finish;
    end
    initial begin #100000000; $fatal(1,"test timeout");end
endmodule
