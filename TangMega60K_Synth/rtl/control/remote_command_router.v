// Command transactions commit only at ready/valid boundaries. The UART is
// deliberately kept alive during audio panic so the ACK can reach the phone.
module remote_command_router (
    input wire clk, rst_n,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_seq, cmd_opcode, input wire [79:0] cmd_payload,
    output reg rsp_valid, input wire rsp_ready,
    output reg [7:0] rsp_seq, rsp_opcode, output reg [79:0] rsp_payload,
    output wire event_valid, input wire event_ready,
    output wire event_on, output wire [5:0] event_source,
    output wire [6:0] event_note, event_velocity, output wire [1:0] event_timbre,
    output wire expr_valid, input wire expr_ready, output wire [2:0] expr_mask,
    output wire [11:0] expr_gain, output wire signed [12:0] expr_bend,
    output wire [7:0] expr_vibrato,
    output wire performance_valid, output wire performance_pending, input wire performance_ready,
    output wire [7:0] performance_opcode, output wire [79:0] performance_payload,
    input wire [7:0] performance_status,
    output reg [174:0] key_map_flat, output reg [1:0] current_timbre, effect_mode,
    output reg panic_pulse,
    input wire [6:0] active_count, input wire playing, recording, guide_active,
    input wire overflow_sticky, input wire [15:0] record_count, score_position,
    input wire [31:0] underrun_count,
    output wire [15:0] record_read_index,
    input wire record_read_valid, input wire [79:0] record_read_payload
);
    localparam IDLE=0, DECODE=1, NOTE_WAIT=2, EXPR_WAIT=3, PERF_WAIT=4, READ_WAIT=5;
    reg [2:0] state;
    reg [7:0] seq_q, op_q;
    reg [79:0] p;
    reg last_valid;
    reg [7:0] last_seq, last_op, last_status;
    reg [79:0] last_payload;
    reg extra_pending, last_extra;
    reg [7:0] extra_opcode, last_extra_opcode;
    reg [79:0] extra_payload, last_extra_payload;
    integer i;
    assign cmd_ready=rst_n && state==IDLE && !rsp_valid;
    assign event_valid=rst_n && state==NOTE_WAIT;
    assign event_source=6'd63; // phone namespace; allocator distinguishes note too
    assign event_note=p[14:8];
    assign event_velocity=p[22:16];
    assign event_timbre=p[25:24];
    assign event_on=p[32];
    assign expr_valid=rst_n && state==EXPR_WAIT;
    assign expr_mask=p[2:0];
    assign expr_gain=p[19:8];
    assign expr_bend=p[36:24];
    assign expr_vibrato=p[47:40];
    assign performance_pending=state==PERF_WAIT;
    assign performance_valid=rst_n && performance_pending;
    assign performance_opcode=op_q;
    assign performance_payload=p;
    assign record_read_index=p[23:8];

    task acknowledge;
        input [7:0] status;
        begin
            rsp_valid<=1; rsp_seq<=seq_q; rsp_opcode<=8'h80;
            rsp_payload<={64'd0,status,op_q};
            last_valid<=1; last_seq<=seq_q; last_op<=op_q;
            last_payload<=p; last_status<=status;
            last_extra<=0; state<=IDLE;
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; seq_q<=0; op_q<=0; p<=0;
            rsp_valid<=0; rsp_seq<=0; rsp_opcode<=0; rsp_payload<=0;
            current_timbre<=2; effect_mode<=0; panic_pulse<=0;
            last_valid<=0; last_seq<=0; last_op<=0; last_payload<=0; last_status<=0;
            extra_pending<=0; last_extra<=0; extra_opcode<=0; extra_payload<=0;
            last_extra_opcode<=0; last_extra_payload<=0;
            for(i=0;i<25;i=i+1) key_map_flat[i*7+:7]<=60+i;
        end else begin
            panic_pulse<=0;
            if(rsp_valid && rsp_ready) begin
                if(extra_pending) begin
                    rsp_opcode<=extra_opcode; rsp_payload<=extra_payload;
                    extra_pending<=0;
                end else rsp_valid<=0;
            end
            case(state)
                IDLE: if(cmd_valid && cmd_ready) begin
                    seq_q<=cmd_seq; op_q<=cmd_opcode; p<=cmd_payload; state<=DECODE;
                end
                DECODE: begin
                    if(last_valid && seq_q==last_seq) begin
                        rsp_valid<=1; rsp_seq<=seq_q; rsp_opcode<=8'h80;
                        if(op_q==last_op && p==last_payload) begin
                            rsp_payload<={64'd0,last_status,op_q};
                            extra_pending<=last_extra;
                            extra_opcode<=last_extra_opcode; extra_payload<=last_extra_payload;
                        end else rsp_payload<={64'd0,8'd1,op_q};
                        state<=IDLE;
                    end else case(op_q)
                        8'h01: if(p[7:6]!=0 || p[15] || p[23] || p[31:26]!=0 ||
                                      p[39:33]!=0 || p[79:40]!=0)
                            acknowledge(1);
                            else state<=NOTE_WAIT;
                        8'h02: if(p[7:3]!=0 || p[2:0]==0 || p[23:20]!=0 ||
                                      $signed(p[39:24])>16'sd2400 || $signed(p[39:24])< -16'sd2400 ||
                                      p[47:40]>100 || p[79:48]!=0)
                            acknowledge(1);
                            else state<=EXPR_WAIT;
                        8'h03: begin
                            if(p[79:16]!=0 || p[7:0]>1 || p[15:8]>3) acknowledge(1);
                            else begin
                                if(p[7:0]==0) current_timbre<=p[9:8];
                                else effect_mode<=p[9:8];
                                acknowledge(0);
                            end
                        end
                        8'h04,8'h06,8'h07: state<=PERF_WAIT;
                        8'h05: begin
                            if(p[7:0]>=25 || p[15] || p[79:16]!=0) acknowledge(1);
                            else begin key_map_flat[p[7:0]*7+:7]<=p[14:8]; acknowledge(0); end
                        end
                        8'h08: begin
                            if(p[79:24]!=0 || p[7:0]>1)
                                acknowledge(1);
                            else if(p[7:0]==1) state<=READ_WAIT;
                            else begin
                                acknowledge(0);
                                extra_pending<=1; last_extra<=1;
                                if(p[7:0]==0) begin
                                    extra_opcode<=8'h81; last_extra_opcode<=8'h81;
                                    extra_payload<={score_position,underrun_count,record_count,
                                        4'd0,overflow_sticky,guide_active,recording,playing,1'b0,active_count};
                                    last_extra_payload<={score_position,underrun_count,record_count,
                                        4'd0,overflow_sticky,guide_active,recording,playing,1'b0,active_count};
                                end else begin
                                    extra_opcode<=8'h82; last_extra_opcode<=8'h82;
                                    extra_payload<=record_read_payload; last_extra_payload<=record_read_payload;
                                end
                            end
                        end
                        default: acknowledge(3);
                    endcase
                end
                NOTE_WAIT: if(event_ready) acknowledge(0);
                EXPR_WAIT: if(expr_ready) acknowledge(0);
                PERF_WAIT: if(performance_ready) begin
                    acknowledge(performance_status);
                    if(op_q==4 && p[7:0]==5 && performance_status==0) panic_pulse<=1;
                end
                READ_WAIT: begin
                    // Indexed recorder RAM is synchronous. DECODE gives it a
                    // complete read cycle after the new address was latched.
                    if(!record_read_valid)acknowledge(1);
                    else begin
                        acknowledge(0);extra_pending<=1;last_extra<=1;
                        extra_opcode<=8'h82;last_extra_opcode<=8'h82;
                        extra_payload<=record_read_payload;last_extra_payload<=record_read_payload;
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
