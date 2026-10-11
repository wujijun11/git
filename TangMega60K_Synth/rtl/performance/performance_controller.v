// Event-only offline score, guide and recorder. Payload byte 0 is bits 7:0.
module performance_controller #(
    parameter integer CLK_HZ = 49152000,
    parameter integer SCORE_CAPACITY = 256,
    parameter integer RECORD_CAPACITY = 1024,
    parameter integer SCORE_SOURCE_BASE = 0,
    parameter integer RECORD_SOURCE_BASE = 25
) (
    input wire clk, input wire rst_n,
    input wire command_valid, output wire command_ready,
    input wire [7:0] command_opcode, input wire [79:0] command_payload,
    output reg [7:0] command_status,
    input wire record_valid, input wire record_on,
    input wire [5:0] record_source, input wire [6:0] record_note,
    input wire [6:0] record_velocity, input wire [1:0] record_timbre,
    output reg event_valid, input wire event_ready, output reg event_on,
    output reg [5:0] event_source, output reg [6:0] event_note,
    output reg [6:0] event_velocity, output reg [1:0] event_timbre,
    input wire [174:0] key_map_flat, input wire [1:0] current_timbre,
    output reg [24:0] guide_mask, output reg playing, output reg recording,
    output reg guide_active, output reg overflow_sticky,
    output reg [15:0] record_count, output reg [15:0] score_position,
    input wire [15:0] record_read_index, output wire record_read_valid,
    output wire [79:0] row_payload
);
    localparam MODE_SCORE=0, MODE_GUIDE=1, MODE_REPLAY=2;
    localparam integer BUILTIN_ROWS=32;
    localparam [5:0] SCORE_BASE=SCORE_SOURCE_BASE;
    localparam [7:0] RECORD_BASE=RECORD_SOURCE_BASE;
    localparam integer SCORE_AW=(SCORE_CAPACITY>1) ? $clog2(SCORE_CAPACITY) : 1;
    localparam integer RECORD_AW=(RECORD_CAPACITY>1) ? $clog2(RECORD_CAPACITY) : 1;
    reg [44:0] score_ram [0:SCORE_CAPACITY-1];
    reg [SCORE_CAPACITY-1:0] row_written;
    reg [63:0] record_ram [0:RECORD_CAPACITY-1];
    reg [44:0] score_row_q;
    reg [63:0] record_play_q, record_read_q;
    reg [15:0] playback_q_index, record_read_q_index;
    reg playback_q_valid, record_read_q_valid;
    reg selected_builtin;
    reg [15:0] committed_count, run_count;
    reg [1:0] mode;
    reg [31:0] tick_accumulator, time_ms, due_ms, last_record_ms;
    wire [32:0] tick_sum = {1'b0,tick_accumulator} + 33'd1000;
    wire [32:0] tick_remainder=tick_sum-CLK_HZ;
    wire tick_ms = tick_sum >= CLK_HZ;
    reg stopping;
    reg unsupported_record_source;
    reg [24:0] held;
    reg [6:0] held_note [0:24];
    reg [1:0] held_timbre [0:24];
    reg [4:0] event_key;
    reg event_release;
    integer i, n, first_held;
    reg all_written;
    wire replay_supported=(record_count!=0) && !unsupported_record_source;
    wire [15:0] arg_count = command_payload[15:0];
    wire [7:0] action = command_payload[7:0];
    wire idle = !playing && !guide_active && !stopping && !event_valid;
    assign command_ready = 1'b1;
    assign record_read_valid = record_read_q_valid;
    assign row_payload = record_read_valid ? {record_read_q,record_read_q_index} : 80'd0;
    wire suppress_record=command_valid && command_opcode==8'h04 && command_status==0 &&
        (action==3 || action==5);
    wire record_capture=recording && record_valid && !suppress_record && record_count<RECORD_CAPACITY;
    wire score_write=command_valid && command_ready && command_status==0 && command_opcode==8'h06;

    // Synchronous RAM ports: score has one write and one read port; recorder
    // has one write/playback-read port and one independent readback port.
    // RAM contents and read data have no reset, allowing block RAM inference.
    always @(posedge clk) begin
        if (score_write) score_ram[arg_count[SCORE_AW-1:0]]<=
            {command_payload[64],command_payload[62:56],command_payload[52:48],command_payload[47:16]};
        score_row_q<=score_ram[score_position[SCORE_AW-1:0]];
        if (record_capture)
            record_ram[record_count[RECORD_AW-1:0]]<=
                {5'd0,record_timbre,record_on,1'b0,record_velocity,
                 1'b0,record_note,2'd0,record_source,(time_ms-last_record_ms)};
        else record_play_q<=record_ram[score_position[RECORD_AW-1:0]];
        record_read_q<=record_ram[record_read_index[RECORD_AW-1:0]];
        record_read_q_index<=record_read_index;
        playback_q_index<=score_position;
        if (!rst_n) begin playback_q_valid<=0; record_read_q_valid<=0; end
        else begin
            playback_q_valid<=!record_capture;
            record_read_q_valid<=record_read_index<record_count;
        end
    end

    function [79:0] builtin_row;
        input [15:0] index;
        reg [7:0] key;
        reg [31:0] delta;
        begin
            // Beethoven's public-domain Ode to Joy melody, sixteen notes.
            case (index >> 1)
                0,1,6,11,12: key=4;
                2,5: key=5;
                3,4: key=7;
                7,10,13,14: key=2;
                default: key=0;
            endcase
            delta = index[0] ? ((index==31) ? 800 : 400) : ((index==0) ? 0 : 100);
            builtin_row = {8'd0, {7'd0,!index[0]}, 8'd100, key, delta, index};
        end
    endfunction

    reg [79:0] active_row;
    wire cached_row_ready=playback_q_valid && playback_q_index==score_position;
    wire active_row_ready=(mode!=MODE_REPLAY && selected_builtin) || cached_row_ready;
    reg [7:0] active_key;
    wire [6:0] active_velocity=mode==MODE_REPLAY ? active_row[70:64] : active_row[62:56];
    // Match the allocator's MIDI semantics before updating held ownership or
    // guide state. A velocity-zero NoteOn releases the currently held note.
    wire active_on=(mode==MODE_REPLAY ? active_row[72] : active_row[64]) && active_velocity!=0;
    wire [6:0] active_note=mode==MODE_REPLAY ? active_row[62:56] : key_map_flat[active_key*7 +: 7];
    wire [1:0] active_timbre=mode==MODE_REPLAY ? active_row[74:73] : current_timbre;
    always @* begin
        if (mode==MODE_REPLAY) begin
            active_row = {record_play_q,playback_q_index};
            active_key = active_row[55:48]-RECORD_BASE;
        end else begin
            active_row=selected_builtin ? builtin_row(score_position) :
                {8'd0,7'd0,score_row_q[44],1'b0,score_row_q[43:37],
                 3'd0,score_row_q[36:32],score_row_q[31:0],playback_q_index};
            active_key=active_row[55:48];
        end
        all_written=1;
        for (n=0;n<SCORE_CAPACITY;n=n+1)
            if (n<arg_count && !row_written[n]) all_written=0;
        first_held=0;
        for (n=24;n>=0;n=n-1) if (held[n]) first_held=n;
        command_status=0;
        case (command_opcode)
            8'h04: begin
                if (command_payload[79:8]!=0 || action>8) command_status=1;
                else case (action)
                    1,6: if (!idle || recording) command_status=2;
                         else if (committed_count==0) command_status=1;
                    2: if (!idle || recording) command_status=2;
                    4: if (!idle || recording) command_status=2;
                    8: if (!idle || recording) command_status=2;
                       else if (!replay_supported) command_status=1;
                    default: command_status=0;
                endcase
            end
            8'h06: begin
                if (!idle || recording) command_status=2;
                else if (arg_count>=SCORE_CAPACITY || command_payload[79:72]!=0 ||
                    command_payload[55:48]>24 || command_payload[63:56]>127 ||
                    command_payload[71:64]>1) command_status=1;
            end
            8'h07: begin
                if (!idle || recording) command_status=2;
                else if (command_payload[79:24]!=0 || command_payload[23:16]>1)
                    command_status=1;
                else if (command_payload[23:16]==1) begin
                    if (arg_count!=0 && arg_count!=BUILTIN_ROWS) command_status=1;
                end else if (arg_count==0 || arg_count>SCORE_CAPACITY || !all_written)
                    command_status=1;
            end
            default: command_status=3;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            row_written<=0; selected_builtin<=1; committed_count<=BUILTIN_ROWS;
            run_count<=0; mode<=MODE_SCORE; tick_accumulator<=0; time_ms<=0;
            due_ms<=0; last_record_ms<=0; stopping<=0; held<=0;
            unsupported_record_source<=0;
            guide_mask<=0; playing<=0; recording<=0; guide_active<=0;
            overflow_sticky<=0; record_count<=0; score_position<=0;
            event_valid<=0; event_on<=0; event_source<=0; event_note<=0;
            event_velocity<=0; event_timbre<=0; event_key<=0; event_release<=0;
            for (i=0;i<25;i=i+1) begin held_note[i]<=0; held_timbre[i]<=0; end
        end else begin
            if (tick_ms) begin tick_accumulator<=tick_remainder[31:0]; time_ms<=time_ms+32'd1; end
            else tick_accumulator<=tick_sum[31:0];
            // Passive monitor: no ready signal and no influence on live events.
            if (recording && record_valid && !suppress_record) begin
                if (record_count<RECORD_CAPACITY) begin
                    record_count<=record_count+16'd1;
                    last_record_ms<=time_ms;
                    if (record_source<RECORD_SOURCE_BASE || record_source>=RECORD_SOURCE_BASE+25)
                        unsupported_record_source<=1;
                end else begin recording<=0; overflow_sticky<=1; end
            end
            if (event_valid && event_ready) begin
                event_valid<=0;
                held[event_key]<=event_on;
                if (event_on) begin held_note[event_key]<=event_note; held_timbre[event_key]<=event_timbre; end
                if (!event_release && !stopping) begin
                    score_position<=score_position+16'd1;
                    if (score_position+1>=run_count) begin
                        playing<=0; guide_active<=0; guide_mask<=0; stopping<=1;
                    end else due_ms<=due_ms+active_row[47:16];
                end
            end
            if (command_valid && command_ready && command_status==0) begin
                case (command_opcode)
                    8'h06: begin
                        row_written[arg_count]<=1;
                        committed_count<=0;
                    end
                    8'h07: begin
                        selected_builtin<=command_payload[16];
                        committed_count<=command_payload[16] ? BUILTIN_ROWS : arg_count;
                        row_written<=0;
                    end
                    8'h04: case (action)
                        0,5: begin
                            playing<=0; guide_active<=0; guide_mask<=0; stopping<=1;
                            if (action==5) recording<=0;
                        end
                        1,6: begin
                            mode<=(action==6) ? MODE_GUIDE : MODE_SCORE;
                            playing<=action==1; guide_active<=1; guide_mask<=0;
                            run_count<=committed_count; score_position<=0;
                            due_ms<=time_ms;
                        end
                        2: begin recording<=1; record_count<=0; overflow_sticky<=0;
                            unsupported_record_source<=0; last_record_ms<=time_ms; end
                        3: recording<=0;
                        4: begin record_count<=0; overflow_sticky<=0; unsupported_record_source<=0; end
                        7: begin guide_active<=0; guide_mask<=0; end
                        8: begin
                            mode<=MODE_REPLAY; playing<=1; guide_active<=1; guide_mask<=0;
                            run_count<=record_count; score_position<=0;
                            due_ms<=time_ms;
                        end
                        default: ;
                    endcase
                    default: ;
                endcase
            end else if (!event_valid) begin
                if (stopping) begin
                    if (held==0) stopping<=0;
                    else begin
                        event_valid<=1; event_on<=0; event_source<=SCORE_BASE+first_held[5:0];
                        event_note<=held_note[first_held]; event_velocity<=0;
                        event_timbre<=held_timbre[first_held]; event_key<=first_held[4:0];
                        event_release<=1;
                    end
                end else if ((playing || guide_active) && score_position<run_count && active_row_ready &&
                    (time_ms-due_ms)>=active_row[47:16]) begin
                    if (guide_active) guide_mask[active_key]<=active_on;
                    if (mode==MODE_GUIDE) begin
                        score_position<=score_position+16'd1;
                        if (score_position+1>=run_count) begin guide_active<=0; guide_mask<=0; end
                        else due_ms<=due_ms+active_row[47:16];
                    end else begin
                        event_valid<=1; event_key<=active_key[4:0];
                        event_source<=SCORE_BASE+active_key[5:0];
                        if (held[active_key] && active_on && held_note[active_key]!=active_note) begin
                            // A key may be remapped between repeated NoteOns.
                            // Release its old pitch before replacing ownership;
                            // event_release keeps this score row pending until
                            // the release is accepted. Stop/Panic can still
                            // drain this transaction without starting the row.
                            event_release<=1; event_on<=0;
                            event_note<=held_note[active_key]; event_velocity<=0;
                            event_timbre<=held_timbre[active_key];
                        end else begin
                            // Same-pitch retriggers reuse the allocator's held
                            // voice, including when every voice slot is busy.
                            event_release<=0; event_on<=active_on;
                            event_note<=held[active_key] && !active_on ? held_note[active_key] : active_note;
                            event_velocity<=active_on ? active_velocity : 0;
                            event_timbre<=held[active_key] && !active_on ? held_timbre[active_key] : active_timbre;
                        end
                    end
                end
            end
        end
    end
endmodule
