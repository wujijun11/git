// Event-only offline score, guide and recorder. Payload byte 0 is bits 7:0.
module performance_controller #(
    parameter integer CLK_HZ = 49152000,
    // 上传曲谱容量：1024条按下/松开事件；原16位索引和提交格式不变。
    parameter integer SCORE_CAPACITY = 1024,
    parameter integer RECORD_CAPACITY = 1024,
    parameter integer SCORE_SOURCE_BASE = 0,
    parameter integer RECORD_SOURCE_BASE = 25,
    // 直接曲谱使用MIDI 0..127，不改实体25键映射。完整主工程显式开启。
    parameter integer DIRECT_SCORE_ENABLE = 0,
    parameter integer LEARNING_ENABLE = 0,
    parameter [5:0] DIRECT_SCORE_SOURCE = 6'd62
) (
    input wire clk, input wire rst_n,
    input wire command_valid, output wire command_ready,
    input wire [7:0] command_opcode, input wire [79:0] command_payload,
    output reg [7:0] command_status, output wire action_busy,
    // 本地菜单只处理TRANSPORT，不能经过包含1024行完整性归约的上传状态多路器。
    output wire [7:0] local_action_status,
    input wire record_valid, input wire record_on,
    input wire [5:0] record_source, input wire [6:0] record_note,
    input wire [6:0] record_velocity, input wire [1:0] record_timbre,
    output reg event_valid, input wire event_ready, output reg event_on,
    output reg [5:0] event_source, output reg [6:0] event_note,
    output reg [6:0] event_velocity, output reg [1:0] event_timbre,
    input wire [174:0] key_map_flat, input wire [1:0] current_timbre,
    input wire [24:0] learning_touch_mask, input wire learning_touch_ready,
    output wire [79:0] learning_status_payload,
    output wire [24:0] guide_mask, output reg playing, output reg recording,
    output wire guide_active, output reg overflow_sticky,
    output reg [15:0] record_count, output reg [15:0] score_position,
    input wire [15:0] record_read_index, output wire record_read_valid,
    output wire [79:0] row_payload
);
    localparam MODE_SCORE=0, MODE_GUIDE=1, MODE_REPLAY=2, MODE_LEARN=3;
    reg [24:0] timed_guide_mask;
    reg timed_guide_active;
    wire learn_active, learn_release, learn_press, learn_finished, learn_row_ready;
    wire [24:0] learn_target;
    wire [15:0] learn_completed;
    assign guide_active=timed_guide_active || learn_active;
    assign guide_mask=learn_active ? learn_target : timed_guide_mask;
    localparam integer BUILTIN_ROWS=32;
    localparam [5:0] SCORE_BASE=SCORE_SOURCE_BASE;
    localparam [7:0] RECORD_BASE=RECORD_SOURCE_BASE;
    localparam integer SCORE_AW=(SCORE_CAPACITY>1) ? $clog2(SCORE_CAPACITY) : 1;
    localparam integer RECORD_AW=(RECORD_CAPACITY>1) ? $clog2(RECORD_CAPACITY) : 1;
    // 时间32 + 音高/键位7 + 力度7 + 开关1 = 47位，1024行仍落在原3组18位BSRAM内。
    reg [46:0] score_ram [0:SCORE_CAPACITY-1];
    wire [SCORE_CAPACITY-1:0] row_written;
    reg clear_written;
    reg [63:0] record_ram [0:RECORD_CAPACITY-1];
    reg [46:0] score_row_q;
    reg [63:0] record_play_q, record_read_q;
    reg [15:0] playback_q_index, record_read_q_index;
    reg playback_q_valid, record_read_q_valid;
    reg selected_builtin;
    reg selected_direct, upload_has_rows, upload_direct;
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
    reg event_is_direct;
    reg [127:0] direct_held;
    // 停止逐音扫描释放；不用128路长优先编码器，避免扩大关键组合路径。
    reg [6:0] direct_release_cursor;
    integer i, n, first_held;
    wire all_written;
    reg [7:0] action_status, score_write_status, score_commit_status;
    wire replay_supported=(record_count!=0) && !unsupported_record_source;
    wire [15:0] arg_count = command_payload[15:0];
    wire [7:0] action = command_payload[7:0];
    wire idle = !playing && !guide_active && !stopping && !event_valid;
    // TRANSPORT有效编号只有0..8/9。并行检查高76位和低4位，避免把8位范围
    // 比较、80位格式校验和逐项busy判断串成深路径。错误优先级仍为格式1、
    // 忙2、内容1；不新增等待拍，也不改变命令执行与ACK时刻。
    wire [3:0] action_code=command_payload[3:0];
    wire action_format_error=(|command_payload[79:4]) ||
        action_code>(LEARNING_ENABLE ? 4'd9 : 4'd8);
    wire action_needs_idle=action_code==1 || action_code==2 || action_code==4 ||
        action_code==6 || action_code==8 || action_code==9;
    wire action_idle_error=action_needs_idle && (!idle || recording);
    wire action_needs_score=action_code==1 || action_code==6 || action_code==9;
    wire action_content_error=(action_needs_score && committed_count==0) ||
        ((action_code==6 || action_code==9) && selected_direct) ||
        (action_code==8 && !replay_supported);
    assign command_ready = 1'b1;
    assign record_read_valid = record_read_q_valid;
    assign row_payload = record_read_valid ? {record_read_q,record_read_q_index} : 80'd0;
    // Keep each command's acceptance cone local to its affected state. In
    // particular, the score commit's full row-valid reduction must not gate
    // ordinary start/stop commands, playback, guide bits or recorder capture.
    wire action_command=command_valid && command_opcode==8'h04 && action_status==0;
    // A board action has no dependency on score upload/commit validation.
    // Expose its busy status before the opcode-selected response mux so the
    // local source's ready path cannot inherit the full row-valid reduction.
    assign action_busy=action_status==2;
    assign local_action_status=action_status;
    wire suppress_record=action_command && (action==3 || action==5);
    wire record_capture=recording && record_valid && !suppress_record && record_count<RECORD_CAPACITY;
    wire score_write=command_valid && command_opcode==8'h06 && score_write_status==0;
    wire score_commit=command_valid && command_opcode==8'h07 && score_commit_status==0;

    // 每16行保存一个完成标志，用额外寄存器缩短提交命令的1024位组合路径。
    // 位图仍可处理乱序上传、重复覆盖和清批次；不改变提交的同拍校验语义。
    score_upload_tracker #(.CAPACITY(SCORE_CAPACITY)) upload_tracker(
        .clk(clk), .rst_n(rst_n), .clear(clear_written),
        .write_valid(score_write), .write_index(arg_count), .query_count(arg_count),
        .complete(all_written), .row_written(row_written));

    // Synchronous RAM ports: score has one write and one read port; recorder
    // has one write/playback-read port and one independent readback port.
    // RAM contents and read data have no reset, allowing block RAM inference.
    always @(posedge clk) begin
        if (score_write) score_ram[arg_count[SCORE_AW-1:0]]<=
            {command_payload[64],command_payload[62:56],command_payload[54:48],command_payload[47:16]};
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

    // 内置曲谱与上传RAM共用一拍行缓存/索引。先译码行，再处理音符所有权，
    // 避免16位位置比较、键位映射及held选择挤在同一条组合路径里。
    // 索引匹配才允许消费，新位置最多多等一拍；音符、力度及毫秒节奏不变。
    reg [79:0] builtin_row_q;
    always @(posedge clk) builtin_row_q <= builtin_row(score_position);

    // 录音RAM输出到寄存行之间再切一拍，同时预译码录音来源减25的键号。
    // 旧路径把BSRAM时钟到输出、来源减法、25键映射及held判断串到event_*，
    // 实际Setup为0.000ns。保留索引/模式标签，换行或切模式期间禁止读旧行。
    // 只调整MODE_REPLAY；上传曲谱/学习逐行握手保持原来拍次和吞吐量。
    reg [63:0] replay_row_q;
    reg [7:0] playback_key_q;
    reg [15:0] playback_meta_index;
    reg [1:0] playback_meta_mode;
    reg playback_meta_valid;
    always @(posedge clk) begin
        playback_meta_index<=playback_q_index;
        playback_meta_mode<=mode;
        replay_row_q<=record_play_q;
        playback_key_q<=record_play_q[39:32]-RECORD_BASE;
        if(!rst_n)playback_meta_valid<=0;
        else playback_meta_valid<=playback_q_valid;
    end
    reg [79:0] active_row;
    wire cached_row_ready=mode==MODE_REPLAY ?
        (playback_meta_valid && playback_meta_index==score_position && playback_meta_mode==mode) :
        (playback_q_valid && playback_q_index==score_position);
    wire active_row_ready=cached_row_ready;
    reg [7:0] active_key;
    wire [6:0] active_velocity=mode==MODE_REPLAY ? active_row[70:64] : active_row[62:56];
    // Match the allocator's MIDI semantics before updating held ownership or
    // guide state. A velocity-zero NoteOn releases the currently held note.
    wire active_on=(mode==MODE_REPLAY ? active_row[72] : active_row[64]) && active_velocity!=0;
    wire active_direct=DIRECT_SCORE_ENABLE && selected_direct && !selected_builtin && mode!=MODE_REPLAY;
    // 25个固定键位并行译码后按位或，避免“键号*7”可变位选推断宽桶形
    // 移位器，再串接held数组选择。上传合法键号始终0..24；直接音高走旁路。
    reg [6:0] active_mapped_note,active_held_note;
    reg [1:0] active_held_timbre;
    reg active_key_held;
    integer select_key;
    wire [6:0] active_note=mode==MODE_REPLAY ? active_row[62:56] :
        active_direct ? active_key[6:0] : active_mapped_note;
    wire [1:0] active_timbre=mode==MODE_REPLAY ? active_row[74:73] : current_timbre;
    // 学习器与原定时播放器共享RAM读口；只有学习器握手时才推进读地址。
    wire learn_row_valid=LEARNING_ENABLE && mode==MODE_LEARN && active_row_ready &&
        score_position<run_count && !action_command && !event_valid;
    generate if (LEARNING_ENABLE) begin: learning
        learning_stepper stepper(
            .clk(clk),.rst_n(rst_n),.start(action_command && action==9),
            .stop(action_command && (action==0 || action==5 || action==7)),
            .row_valid(learn_row_valid),.row_ready(learn_row_ready),
            .row_key(active_key[4:0]),.row_on(active_on),.row_delta_ms(active_row[47:16]),
            .row_last(score_position+16'd1>=run_count),
            .touch_mask(learning_touch_mask),.touch_ready(learning_touch_ready),
            .active(learn_active),.target_mask(learn_target),.waiting_release(learn_release),
            .waiting_press(learn_press),.completed_steps(learn_completed),.finished(learn_finished));
        // READBACK(4)/0x85，固定10字节：版本、标志、完成步数、目标25位、事件位置。
        assign learning_status_payload={score_position,7'd0,learn_target,learn_completed,
            2'd0,learning_touch_ready,learn_finished,learn_press,learn_release,learn_active,1'b1,8'd1};
    end else begin: no_learning
        assign learn_active=0; assign learn_release=0; assign learn_press=0;
        assign learn_finished=0; assign learn_row_ready=0;
        assign learn_target=0; assign learn_completed=0; assign learning_status_payload=0;
    end endgenerate
    always @* begin
        if(mode==MODE_REPLAY) begin
            active_row={replay_row_q,playback_meta_index};
            active_key=playback_key_q;
        end else begin
            active_row=selected_builtin ? builtin_row_q :
                {8'd0,7'd0,score_row_q[46],1'b0,score_row_q[45:39],
                 1'b0,score_row_q[38:32],score_row_q[31:0],playback_q_index};
            active_key=active_row[55:48];
        end
        active_mapped_note=0;
        active_held_note=0;
        active_held_timbre=0;
        active_key_held=0;
        for(select_key=0;select_key<25;select_key=select_key+1) begin
            active_mapped_note=active_mapped_note |
                (key_map_flat[select_key*7 +:7] & {7{active_key==select_key}});
            active_held_note=active_held_note |
                (held_note[select_key] & {7{active_key==select_key}});
            active_held_timbre=active_held_timbre |
                (held_timbre[select_key] & {2{active_key==select_key}});
            active_key_held=active_key_held || (held[select_key] && active_key==select_key);
        end
        first_held=0;
        for (n=24;n>=0;n=n-1) if (held[n]) first_held=n;
        action_status={6'd0,!action_format_error && action_idle_error,
            action_format_error || (!action_idle_error && action_content_error)};
        score_write_status=0;
        if (!idle || recording) score_write_status=2;
        else if (arg_count>=SCORE_CAPACITY || command_payload[79:73]!=0 ||
            (command_payload[72] && !DIRECT_SCORE_ENABLE) ||
            command_payload[55:48]>(command_payload[72] ? 127 : 24) ||
            (upload_has_rows && upload_direct!=command_payload[72]) || command_payload[63:56]>127 ||
            command_payload[71:64]>1) score_write_status=1;
        score_commit_status=0;
        if (!idle || recording) score_commit_status=2;
        else if (command_payload[79:24]!=0 || command_payload[23:16]>(DIRECT_SCORE_ENABLE ? 2 : 1))
            score_commit_status=1;
        else if (command_payload[23:16]==1) begin
            if (arg_count!=0 && arg_count!=BUILTIN_ROWS) score_commit_status=1;
        end else if (arg_count==0 || arg_count>SCORE_CAPACITY || !all_written ||
            (upload_has_rows && upload_direct!=(command_payload[23:16]==2)))
            score_commit_status=1;
        case (command_opcode)
            8'h04: command_status=action_status;
            8'h06: command_status=score_write_status;
            8'h07: command_status=score_commit_status;
            default: command_status=3;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            clear_written<=0; selected_builtin<=1; committed_count<=BUILTIN_ROWS;
            selected_direct<=0;upload_has_rows<=0;upload_direct<=0;
            direct_held<=0;direct_release_cursor<=0;event_is_direct<=0;
            run_count<=0; mode<=MODE_SCORE; tick_accumulator<=0; time_ms<=0;
            due_ms<=0; last_record_ms<=0; stopping<=0; held<=0;
            unsupported_record_source<=0;
            timed_guide_mask<=0; playing<=0; recording<=0; timed_guide_active<=0;
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
                if (event_is_direct) direct_held[event_note]<=event_on;
                else begin
                    held[event_key]<=event_on;
                    if (event_on) begin held_note[event_key]<=event_note; held_timbre[event_key]<=event_timbre; end
                end
                if (!event_release && !stopping) begin
                    score_position<=score_position+16'd1;
                    if (score_position+1>=run_count) begin
                        playing<=0; timed_guide_active<=0; timed_guide_mask<=0; stopping<=1;
                    end else due_ms<=due_ms+active_row[47:16];
                end
            end
            // Register the commit's bulk bitmap clear so the row-valid
            // reduction drives only local metadata registers. all_written
            // treats the pending clear as empty immediately, and a write on
            // the following cycle overrides its own bit after the clear.
            clear_written<=score_commit;
            // Upload/commit are accepted only while idle, so they cannot
            // overlap an event transaction or the playback scheduler.
            if (score_write) begin
                committed_count<=0;
                upload_has_rows<=1;upload_direct<=command_payload[72];
            end else if (score_commit) begin
                selected_builtin<=command_payload[23:16]==1;
                selected_direct<=command_payload[23:16]==2;
                upload_has_rows<=0;
                committed_count<=command_payload[23:16]==1 ? BUILTIN_ROWS : arg_count;
            end
            if (action_command) begin
                case (action)
                        0,5: begin
                            playing<=0; timed_guide_active<=0; timed_guide_mask<=0; stopping<=1;direct_release_cursor<=0;
                            if (action==5) recording<=0;
                        end
                        1,6: begin
                            mode<=(action==6) ? MODE_GUIDE : MODE_SCORE;
                            playing<=action==1; timed_guide_active<=!selected_direct; timed_guide_mask<=0;
                            direct_release_cursor<=0;
                            run_count<=committed_count; score_position<=0;
                            due_ms<=time_ms;
                        end
                        2: begin recording<=1; record_count<=0; overflow_sticky<=0;
                            unsupported_record_source<=0; last_record_ms<=time_ms; end
                        3: recording<=0;
                        4: begin record_count<=0; overflow_sticky<=0; unsupported_record_source<=0; end
                        7: begin timed_guide_active<=0; timed_guide_mask<=0; end
                        9: begin
                            mode<=MODE_LEARN; playing<=0; timed_guide_active<=0; timed_guide_mask<=0;
                            run_count<=committed_count; score_position<=0;
                        end
                        8: begin
                            mode<=MODE_REPLAY; playing<=1; timed_guide_active<=1; timed_guide_mask<=0;
                            run_count<=record_count; score_position<=0;
                            due_ms<=time_ms;
                        end
                        default: ;
                endcase
            end else if (!event_valid) begin
                if (stopping) begin
                    if (held==0 && direct_held==0) stopping<=0;
                    else if (held!=0) begin
                        event_valid<=1; event_on<=0; event_source<=SCORE_BASE+first_held[5:0];
                        event_note<=held_note[first_held]; event_velocity<=0;
                        event_timbre<=held_timbre[first_held]; event_key<=first_held[4:0];
                        event_release<=1;event_is_direct<=0;
                    end else begin
                        direct_release_cursor<=direct_release_cursor+7'd1;
                        if (direct_held[direct_release_cursor]) begin
                            event_valid<=1;event_on<=0;event_source<=DIRECT_SCORE_SOURCE;
                            event_note<=direct_release_cursor;event_velocity<=0;event_timbre<=current_timbre;
                            event_release<=1;event_is_direct<=1;
                        end
                    end
                end else if (mode==MODE_LEARN) begin
                    if (learn_row_valid && learn_row_ready) score_position<=score_position+16'd1;
                end else if ((playing || guide_active) && score_position<run_count && active_row_ready &&
                    (time_ms-due_ms)>=active_row[47:16]) begin
                    if (guide_active && !active_direct) timed_guide_mask[active_key]<=active_on;
                    if (mode==MODE_GUIDE) begin
                        score_position<=score_position+16'd1;
                        if (score_position+1>=run_count) begin timed_guide_active<=0; timed_guide_mask<=0; end
                        else due_ms<=due_ms+active_row[47:16];
                    end else if (active_direct) begin
                        // 独立来源62与实体键25..49、远程演奏63互不释放对方的音符。
                        // 音色取板上实时选择；不保存或播放PCM，不绕过原声部分配器。
                        event_valid<=1;event_on<=active_on;event_source<=DIRECT_SCORE_SOURCE;
                        event_note<=active_note;event_velocity<=active_on ? active_velocity : 0;
                        event_timbre<=current_timbre;event_release<=0;event_is_direct<=1;
                    end else begin
                        event_is_direct<=0;
                        event_valid<=1; event_key<=active_key[4:0];
                        event_source<=SCORE_BASE+active_key[5:0];
                        if (active_key_held && active_on && active_held_note!=active_note) begin
                            // A key may be remapped between repeated NoteOns.
                            // Release its old pitch before replacing ownership;
                            // event_release keeps this score row pending until
                            // the release is accepted. Stop/Panic can still
                            // drain this transaction without starting the row.
                            event_release<=1; event_on<=0;
                            event_note<=active_held_note; event_velocity<=0;
                            event_timbre<=active_held_timbre;
                        end else begin
                            // Same-pitch retriggers reuse the allocator's held
                            // voice, including when every voice slot is busy.
                            event_release<=0; event_on<=active_on;
                            event_note<=active_key_held && !active_on ? active_held_note : active_note;
                            event_velocity<=active_on ? active_velocity : 0;
                            event_timbre<=active_key_held && !active_on ? active_held_timbre : active_timbre;
                        end
                    end
                end
            end
        end
    end
endmodule
