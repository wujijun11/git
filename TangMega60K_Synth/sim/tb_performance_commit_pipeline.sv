`timescale 1ns/1ps
// Consecutive command handshakes stress the score upload epoch boundary.
module tb_performance_commit_pipeline;
    reg clk=0;
    always #5 clk=!clk;
    reg rst_n=0, command_valid=0;
    reg [7:0] command_opcode=0;
    reg [79:0] command_payload=0;
    wire command_ready;
    wire [7:0] command_status;
    reg record_valid=0;
    wire playing, recording;
    wire [15:0] record_count;
    performance_controller #(.CLK_HZ(1000000),.SCORE_CAPACITY(256),.RECORD_CAPACITY(2)) dut(
        .clk(clk),.rst_n(rst_n),.command_valid(command_valid),.command_ready(command_ready),
        .command_opcode(command_opcode),.command_payload(command_payload),.command_status(command_status),
        .record_valid(record_valid),.record_on(1'b1),.record_source(6'd25),.record_note(7'd60),
        .record_velocity(7'd100),.record_timbre(2'd0),.event_valid(),.event_ready(1'b1),
        .event_on(),.event_source(),.event_note(),.event_velocity(),.event_timbre(),
        .key_map_flat(175'd0),.current_timbre(2'd0),.guide_mask(),.playing(playing),
        .recording(recording),.guide_active(),.overflow_sticky(),.record_count(record_count),
        .score_position(),.record_read_index(16'd0),.record_read_valid(),.row_payload()
    );
    task issue;
        input [7:0] opcode;
        input [79:0] payload;
        input [7:0] status;
        begin
            @(negedge clk);
            command_valid=1;command_opcode=opcode;command_payload=payload;
            #1;
            if (!command_ready || command_status!==status)
                $fatal(1,"consecutive command %h payload %h expected %0d got %0d",
                    opcode,payload,status,command_status);
            @(posedge clk);#1;
        end
    endtask
    integer i;
    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        // A write immediately after selecting the built-in score must survive
        // the previous upload's deferred clear, including the top address.
        issue(7,80'h10000,0);
        issue(6,80'd255,0);
        issue(7,80'd256,1);
        for(i=0;i<255;i=i+1) issue(6,i,0);
        issue(7,80'd256,0);
        // Reusing the just-committed bitmap must be rejected on the next edge.
        issue(7,80'd256,1);
        issue(6,80'd0,0);
        issue(7,80'd1,0);
        // Start another upload on the edge directly after the successful
        // commit. Row zero from its prior epoch must not satisfy this commit.
        issue(6,80'd1,0);
        issue(7,80'd2,1);
        issue(6,80'd0,0);
        issue(7,80'd2,0);
        issue(4,80'd1,0);
        if(!playing) $fatal(1,"start immediately after commit was delayed");
        issue(7,80'h10000,2);
        issue(4,80'd0,0);
        @(negedge clk);command_valid=0;
        wait(dut.idle);
        // Stop recording and Panic suppress capture on the command edge.
        issue(4,80'd2,0);record_valid=1;
        issue(4,80'd3,0);record_valid=0;
        if(recording || record_count!=0) $fatal(1,"Stop captured its command-edge event");
        issue(4,80'd2,0);record_valid=1;
        issue(4,80'd5,0);record_valid=0;
        if(recording || record_count!=0) $fatal(1,"Panic captured its command-edge event");
        @(negedge clk);command_valid=0;
        $display("PASS performance consecutive commands: 256-row commit, missing rows, upload epochs, immediate start, capture Stop/Panic");
        $finish;
    end
    initial begin #100000;$fatal(1,"consecutive command watchdog");end
endmodule
