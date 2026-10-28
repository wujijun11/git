// Full contest integration. Pure FPGA audio; Bluetooth carries events only.
// clk is the existing 49.152MHz audio domain. video_clk is 25MHz, independent.
module instrument_full_system #(
    parameter CLK_HZ=49152000, UART_BAUD=115200,
    parameter SENSOR_SETTLE_CYCLES=CLK_HZ/20,
    parameter MENU_ENABLE=1,
    parameter MENU_DEBOUNCE_CYCLES=CLK_HZ/50,
    parameter MENU_LONG_PRESS_CYCLES=CLK_HZ,
    parameter MENU_ROOT_IDLE_CYCLES=CLK_HZ*5,
    parameter SLIDER_VOLUME_ENABLE=0,
    // 分层菜单仅由新板级入口开启；保留旧接口/回归入口的默认行为。
    parameter HIERARCHICAL_MENU_ENABLE=0,
    parameter MENU_WAVE_IDLE_CYCLES=CLK_HZ*10,
    parameter STABLE_CHORD_MIX_ENABLE=0,
    parameter EARLY_KEY_ENABLE=0,
    parameter ROM_DIR="rtl/audio/rom/",
    parameter [7:0] GUIDE_BRIGHTNESS=8'd32, GUIDE_TOUCH_BRIGHTNESS=8'd16,
    parameter [124:0] GUIDE_PIXEL_KEY_MAP={5'd24,5'd23,5'd22,5'd21,5'd20,
        5'd19,5'd18,5'd17,5'd16,5'd15,5'd14,5'd13,5'd12,5'd11,5'd10,
        5'd9,5'd8,5'd7,5'd6,5'd5,5'd4,5'd3,5'd2,5'd1,5'd0}
) (
    input wire clk,rst_n,input wire uart_rx,output wire uart_tx,
    inout wire [2:0] mpr_scl,mpr_sda,input wire [2:0] mpr_irq_n,
    input wire local_action_valid,output wire local_action_ready,input wire [7:0] local_action,
    output wire i2s_bclk,i2s_lrclk,i2s_data,guide_led_data,
    output wire [6:0] active_count,output wire [24:0] touch_mask,guide_mask,
    output wire [2:0] sensor_ready,sensor_fault,
    output wire [31:0] underrun_count,output wire overflow_sticky,
    output wire playing,recording,guide_active,
    input wire video_clk,input wire [9:0] video_x,video_y,input wire video_de,
    output wire [23:0] video_rgb,
    output wire signed [23:0] monitor_left,monitor_right,output wire monitor_valid,
    // Main-project hardware observation, read through the on-chip analyzer.
    output reg [6:0] debug_last_note,
    output wire signed [23:0] debug_transmit_left,
    output wire [3:0] debug_audio_reset_status,
    // 仅给板级OLED包装层使用；不增加event/cmd/done/sample公共V2端口。
    output wire menu_main,
    output wire [1:0] menu_page,menu_zone,menu_timbre,
    output wire signed [6:0] menu_transpose,
    output wire menu_busy,
    output wire [7:0] menu_error,
    output wire [15:0] menu_record_count,
    output wire menu_prompt_valid,
    output wire [1:0] menu_prompt_code,
    output wire menu_volume_mode,
    output wire [7:0] menu_volume_percent,
    // 显示观察接口：原始滑条触摸状态，不改变event/cmd/done/sample公共V2端口。
    output wire menu_touch_active,
    output wire [3:0] menu_view,
    output wire [1:0] menu_expression_mode,
    output wire menu_waveform_view,
    output wire [11:0] menu_control_value,
    output wire menu_control_negative,
    output wire [7:0] menu_control_percent
);
    wire cv,cr,router_cr,rv,rr;wire [7:0] cs,co,rs,ro;wire [79:0] cp,rp;
    wire [31:0] crc_errors,framing_errors,uart_overflows,uart_timeouts;
    wire uart_overflow;
    remote_uart_transport #(.CLK_HZ(CLK_HZ),.BAUD(UART_BAUD)) uart(
        .clk(clk),.reset(!rst_n),.rx(uart_rx),.tx(uart_tx),
        .cmd_valid(cv),.cmd_ready(cr),.cmd_seq(cs),.cmd_opcode(co),.cmd_payload(cp),
        .rsp_valid(rv),.rsp_ready(rr),.rsp_seq(rs),.rsp_opcode(ro),.rsp_payload(rp),
        .crc_error_count(crc_errors),.framing_error_count(framing_errors),
        .overflow_count(uart_overflows),.timeout_count(uart_timeouts),.overflow_pulse(uart_overflow));
    wire remote_ev,remote_er,remote_on;wire [5:0] remote_source;
    wire [6:0] remote_note,remote_velocity;wire [1:0] remote_timbre;
    wire phone_xv,phone_xr;wire [2:0] phone_xm;wire [11:0] phone_gain;
    wire signed [12:0] phone_bend;wire [7:0] phone_vib;
    wire perf_cv,perf_cr,perf_pending;wire [7:0] perf_co,perf_status;wire [79:0] perf_cp;
    wire [7:0] perf_local_action_status;
    wire [174:0] mapping,base_mapping;wire [1:0] timbre,router_timbre,fx,router_fx;wire panic;
    wire router_timbre_written;
    // 只读扩展0x83：版本、状态旗标、页面、区域、实际音色、有符号半音、效果、错误。
    // 与OLED共用实际状态；不读取router内部可能已被滑条覆盖的旧音色。
    wire [79:0] learning_status_payload;
    wire [79:0] mode_status_payload = {16'd0,menu_error,6'd0,fx,
        menu_transpose[6],menu_transpose,6'd0,timbre,6'd0,menu_zone,6'd0,menu_page,
        2'd0,(MENU_ENABLE!=0),guide_active,recording,playing,menu_busy,menu_main,8'd1};
    wire [15:0] record_count,score_position,read_index;wire read_valid;wire [79:0] read_row;
    wire phone_releasing,local_panic,panic_request,panic_discard;
    reg panic_quiescing;
    reg [5:0] panic_idle;
    reg [24:0] panic_blocked_keys;
    wire accept_commands=!phone_releasing && !panic_discard;
    // Stop new transactions during watchdog release without ever retracting
    // an already presented note event from a stalled arbiter grant.
    assign cr=router_cr && accept_commands;
    remote_command_router #(.ENABLE_MODE_STATUS(1),.ENABLE_DIRECT_SCORE(1),.ENABLE_LEARNING(1)) router(.clk(clk),.rst_n(rst_n),.cmd_valid(cv && accept_commands),.cmd_ready(router_cr),
        .cmd_seq(cs),.cmd_opcode(co),.cmd_payload(cp),.rsp_valid(rv),.rsp_ready(rr),
        .rsp_seq(rs),.rsp_opcode(ro),.rsp_payload(rp),
        .event_valid(remote_ev),.event_ready(remote_er),.event_on(remote_on),.event_source(remote_source),
        .event_note(remote_note),.event_velocity(remote_velocity),.event_timbre(remote_timbre),
        .expr_valid(phone_xv),.expr_ready(phone_xr),.expr_mask(phone_xm),.expr_gain(phone_gain),
        .expr_bend(phone_bend),.expr_vibrato(phone_vib),
        .performance_valid(perf_cv),.performance_pending(perf_pending),.performance_ready(perf_cr),.performance_opcode(perf_co),
        .performance_payload(perf_cp),.performance_status(perf_status),
        .key_map_flat(base_mapping),.current_timbre(router_timbre),.effect_mode(router_fx),.panic_pulse(panic),
        .timbre_write_pulse(router_timbre_written),
        .active_count(active_count),.playing(playing),.recording(recording),.guide_active(guide_active),
        .overflow_sticky(overflow_sticky),.record_count(record_count),.score_position(score_position),
        .underrun_count(underrun_count),.mode_status_payload(mode_status_payload),.learning_status_payload(learning_status_payload),.record_read_index(read_index),
        .record_read_valid(read_valid),.record_read_payload(read_row));

    reg [2:0] irq_meta,irq_sync;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin irq_meta<=7;irq_sync<=7;end
        else begin irq_meta<=mpr_irq_n;irq_sync<=irq_meta;end
    end
    wire sensor_ev,sensor_er,sensor_on,sensor_overflow;
    wire [15:0] sensor_pending;
    wire [5:0] sensor_source;wire [6:0] sensor_note,sensor_velocity;wire [1:0] sensor_timbre;
    wire slider_xv,slider_xr;wire [2:0] slider_xm;wire [11:0] slider_gain;
    wire signed [12:0] slider_bend;wire [7:0] slider_vib;
    wire slider_active;wire [11:0] slider_position;
    assign menu_touch_active = slider_active;
    mpr121_input_frontend #(.CLK_HZ(CLK_HZ),.SETTLE_CYCLES(SENSOR_SETTLE_CYCLES),
        .EARLY_KEY_ENABLE(EARLY_KEY_ENABLE),
        .SOURCE_BASE(25),.SLIDER_BEND_ENABLE(!MENU_ENABLE)) sensors(
        .clk(clk),.resetn(rst_n),.irq_n(irq_sync),.scl(mpr_scl),.sda(mpr_sda),
        .key_map_flat(mapping),.current_timbre(timbre),.key_valid(sensor_ev),.key_ready(sensor_er),
        .key_on(sensor_on),.key_source(sensor_source),.key_note(sensor_note),
        .key_velocity(sensor_velocity),.key_timbre(sensor_timbre),
        .expr_update_valid(slider_xv),.expr_update_ready(slider_xr),.expr_update_mask(slider_xm),
        .expr_update_gain_q1_11(slider_gain),.expr_update_bend_cents(slider_bend),
        .expr_update_vibrato_depth_cents(slider_vib),.touch_mask(touch_mask),
        .fault(sensor_fault),.ready(sensor_ready),.event_overflow(sensor_overflow),.pending_events(sensor_pending),
        .slider_active(slider_active),.slider_position(slider_position));

    wire menu_request_valid,menu_request_ready;
    wire [1:0] menu_request_kind,menu_request_page,menu_request_zone;
    wire menu_timbre_valid;wire [1:0] local_timbre;
    wire [1:0] menu_preview_zone;
    wire menu_action_valid,menu_action_ready;wire [7:0] menu_action;
    wire volume_position_valid;
    wire [11:0] volume_position;
    wire local_fx_write,local_expression_reset;
    wire [1:0] local_fx_value;
    wire [7:0] dispatch_error,hierarchy_error;
    assign menu_error=HIERARCHICAL_MENU_ENABLE?hierarchy_error:dispatch_error;
    generate if(HIERARCHICAL_MENU_ENABLE)begin: hierarchical_menu
        menu_hierarchy #(.DEBOUNCE_CYCLES(MENU_DEBOUNCE_CYCLES),
            .LONG_PRESS_CYCLES(MENU_LONG_PRESS_CYCLES),.IDLE_CYCLES(MENU_WAVE_IDLE_CYCLES)) navigation(
            .clk(clk),.rst_n(rst_n),.touch_active(MENU_ENABLE && slider_active),
            .touch_fault(sensor_fault[0] || !sensor_ready[0]),.position(slider_position),
            .request_valid(menu_request_valid),.request_ready(menu_request_ready),
            .request_kind(menu_request_kind),.request_page(menu_request_page),.request_zone(menu_request_zone),
            .action_busy(menu_busy),.action_done(menu_prompt_valid),.action_error(dispatch_error),.display_error(hierarchy_error),
            .fx_write(local_fx_write),.fx_value(local_fx_value),.expression_reset(local_expression_reset),
            .view(menu_view),.expression_mode(menu_expression_mode),.waveform_view(menu_waveform_view),
            .preview_zone(menu_preview_zone),.position_valid(volume_position_valid),.control_position(volume_position));
        assign menu_main=menu_view==1;
        // 0x83保留既有页面编码；新层级视图不冒充新的公共协议版本。
        assign menu_page=menu_view==4?2'd1:menu_view==7?2'd2:menu_view==8?2'd3:2'd0;
        assign menu_volume_mode=menu_view==0;
    end else begin: legacy_menu
        assign menu_view=menu_volume_mode?4'd0:menu_main?4'd1:{2'd0,menu_page}+4'd3;
        assign menu_expression_mode=0;
        assign menu_waveform_view=0;
        assign local_fx_write=0;assign local_fx_value=0;assign local_expression_reset=0;
        assign hierarchy_error=0;
    slider_menu_controller #(.CLK_HZ(CLK_HZ),.DEBOUNCE_CYCLES(MENU_DEBOUNCE_CYCLES),
        .LONG_PRESS_CYCLES(MENU_LONG_PRESS_CYCLES),
        .PERFORMANCE_ENABLE(SLIDER_VOLUME_ENABLE),.ROOT_IDLE_CYCLES(MENU_ROOT_IDLE_CYCLES)) menu_input(
        .clk(clk),.rst_n(rst_n),.touch_active(MENU_ENABLE && slider_active),
        .touch_fault(sensor_fault[0] || !sensor_ready[0]),.position(slider_position),
        .request_valid(menu_request_valid),.request_ready(menu_request_ready),
        .request_kind(menu_request_kind),.request_page(menu_request_page),.request_zone(menu_request_zone),
        .main_menu(menu_main),.page(menu_page),.selected_zone(),.preview_zone(menu_preview_zone),
        .action_busy(menu_busy),.performance_mode(menu_volume_mode),
        .volume_position_valid(volume_position_valid),.volume_position(volume_position));
    end endgenerate
    menu_action_router #(.CLK_HZ(CLK_HZ),.LEARNING_MENU_ENABLE(HIERARCHICAL_MENU_ENABLE)) menu_actions(
        .clk(clk),.rst_n(rst_n),.request_valid(menu_request_valid),.request_ready(menu_request_ready),
        .request_kind(menu_request_kind),.request_page(menu_request_page),.request_zone(menu_request_zone),
        .recording(recording),.playing(playing),.guide_active(guide_active),
        .timbre_valid(menu_timbre_valid),.timbre(local_timbre),.transpose(menu_transpose),
        .action_valid(menu_action_valid),.action_ready(menu_action_ready),.action(menu_action),.action_status(perf_local_action_status),
        .prompt_valid(menu_prompt_valid),.prompt_code(menu_prompt_code),.last_error(dispatch_error),.busy(menu_busy));
    reg [1:0] selected_fx,previous_router_fx;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin selected_fx<=0;previous_router_fx<=0;end
        else begin
            previous_router_fx<=router_fx;
            if(local_fx_write)selected_fx<=local_fx_value;
            // 手机/电脑提交音效（即使值与路由器旧值相同）也可接回控制权。
            if(router_fx!=previous_router_fx ||
               (cv && cr && co==8'h03 && cp[7:0]==1 && cp[79:16]==0 && cp[15:8]<=3))
                selected_fx<=cv && cr && co==8'h03 ? cp[9:8] : router_fx;
        end
    end
    assign fx=HIERARCHICAL_MENU_ENABLE?selected_fx:router_fx;
    reg [1:0] selected_timbre;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)selected_timbre<=2;
        else begin
            if(menu_timbre_valid)selected_timbre<=local_timbre;
            // 同拍冲突时App提交优先；同值配置仍可收回菜单的音色选择权。
            if(router_timbre_written)selected_timbre<=router_timbre;
        end
    end
    assign timbre=selected_timbre;
    assign menu_timbre=selected_timbre;
    // 空闲时显示实际音色/音区，App修改音色后高亮也跟随，不沿用旧触摸位置。
    assign menu_zone=HIERARCHICAL_MENU_ENABLE?menu_preview_zone:(slider_active || menu_main)?menu_preview_zone:
        menu_page==0?(timbre==2?2'd0:timbre==1?2'd1:timbre==0?2'd2:2'd3):
        menu_page==1?(menu_transpose==-24?2'd0:menu_transpose==-12?2'd1:menu_transpose==0?2'd2:2'd3):
        menu_preview_zone;
    assign menu_record_count=record_count;
    key_map_transpose transpose_keys(.base_map(base_mapping),.semitones(menu_transpose),.mapped_notes(mapping));

    wire perf_ev,perf_er,perf_on;wire [5:0] perf_source;
    wire [6:0] perf_note,perf_velocity;wire [1:0] perf_timbre;
    wire record_overflow,perf_ready,perf_action_busy;
    wire [3:0] arb_ready;wire [1:0] arb_selected;wire push_valid,push_ready,arbiter_push_valid;
    wire [22:0] push_payload;
    wire staged_command_valid,staged_local_ready;
    wire [7:0] staged_opcode;
    wire [79:0] staged_payload;
    wire merged_action_valid,merged_action_ready,selected_menu_action;
    wire [7:0] merged_action;
    local_action_arbiter local_controls(.clk(clk),.rst_n(rst_n),
        .key_valid(local_action_valid),.key_ready(local_action_ready),.key_action(local_action),
        .menu_valid(menu_action_valid),.menu_ready(menu_action_ready),.menu_action(menu_action),
        .out_valid(merged_action_valid),.out_ready(merged_action_ready),.out_action(merged_action),
        .selected_menu(selected_menu_action));
    // 菜单接收busy结果后退避重试，按键保持旧的等待语义。
    assign merged_action_ready=rst_n && staged_local_ready &&
        (selected_menu_action || perf_local_action_status!=2) && !panic_quiescing && !panic;
    // 本地TRANSPORT=5(PANIC)无busy条件，合法负载固定由command_stage补零。
    // 单独用执行握手判定，避免80位命令格式归约经通用ready绕回FIFO写使能。
    // 其余按键/菜单ready与状态处理不变；源在ready前必须保持action稳定。
    assign local_panic=merged_action_valid && rst_n && staged_local_ready &&
        !panic_quiescing && !panic && merged_action==8'd5;
    assign panic_request=panic || local_panic;
    assign panic_discard=panic_quiescing || panic_request;
    performance_command_stage performance_commands(
        .clk(clk),.rst_n(rst_n),.remote_valid(perf_cv),.remote_ready(perf_cr),
        .remote_opcode(perf_co),.remote_payload(perf_cp),
        .local_valid(merged_action_valid && !panic_quiescing && !panic),
        .local_ready(staged_local_ready),.local_action(merged_action),.local_status(),
        .command_valid(staged_command_valid),.command_ready(perf_ready),
        .command_opcode(staged_opcode),.command_payload(staged_payload),.command_status(perf_status));
    performance_controller #(.CLK_HZ(CLK_HZ),.DIRECT_SCORE_ENABLE(1),.LEARNING_ENABLE(1)) performance(
        // Present local valid independently of ready/status. The controller
        // itself consumes only valid && ready with status==0. Feeding ready
        // back into valid created a long command-decode/record-enable path.
        .clk(clk),.rst_n(rst_n),.command_valid(staged_command_valid),.command_ready(perf_ready),
        .command_opcode(staged_opcode),
        .command_payload(staged_payload),.command_status(perf_status),
        .action_busy(perf_action_busy),
        // 本地动作固定为TRANSPORT，直接读取该类状态；不能把1024行上传完整性
        // 校验经通用command_status多路器引回菜单ready，形成跨模块长路径。
        .local_action_status(perf_local_action_status),
        .record_valid(push_valid && push_ready && arb_selected!=2),
        .record_on(push_payload[22]),.record_source(push_payload[21:16]),.record_note(push_payload[15:9]),
        .record_velocity(push_payload[8:2]),.record_timbre(push_payload[1:0]),
        .event_valid(perf_ev),.event_ready(perf_er),.event_on(perf_on),.event_source(perf_source),
        .event_note(perf_note),.event_velocity(perf_velocity),.event_timbre(perf_timbre),
        .learning_touch_mask(touch_mask),.learning_touch_ready((&sensor_ready) && !(|sensor_fault)),
        .learning_status_payload(learning_status_payload),
        .key_map_flat(mapping),.current_timbre(timbre),.guide_mask(guide_mask),.playing(playing),
        .recording(recording),.guide_active(guide_active),.overflow_sticky(record_overflow),
        .record_count(record_count),.score_position(score_position),.record_read_index(read_index),
        .record_read_valid(read_valid),.row_payload(read_row));
    ws2812_guide #(.CLK_HZ(CLK_HZ),.BRIGHTNESS(GUIDE_BRIGHTNESS),
        .TOUCH_BRIGHTNESS(GUIDE_TOUCH_BRIGHTNESS),.PIXEL_KEY_MAP(GUIDE_PIXEL_KEY_MAP)) guide(
        .clk(clk),.rst_n(rst_n),.guide_mask(guide_mask),.touch_mask(touch_mask),.led_data(guide_led_data));

    wire watchdog_ev,watchdog_er,watchdog_on;
    wire [5:0] watchdog_source;wire [6:0] watchdog_note,watchdog_velocity;wire [1:0] watchdog_timbre;
    remote_note_watchdog #(.CLK_HZ(CLK_HZ)) watchdog(.clk(clk),.rst_n(rst_n),
        .heartbeat(cv && cr),.expire(uart_overflow || panic_discard),.accepted(remote_ev && remote_er),
        .accepted_on(remote_on),.accepted_note(remote_note),.event_valid(watchdog_ev),.event_ready(watchdog_er),
        .event_on(watchdog_on),.event_source(watchdog_source),.event_note(watchdog_note),
        .event_velocity(watchdog_velocity),.event_timbre(watchdog_timbre),.releasing(phone_releasing));
    // Keep the audio path reset until every producer has finished its pending
    // transitions and releases. Consume those transactions normally into a
    // discard sink, without resetting UART, router ACKs, score RAM or sensors.
    // An MPR batch scans 25 keys; 32 quiet clocks cover its largest valid gap.
    // A key held through PANIC stays muted until a physical release is seen.
    wire panic_producers_idle=!sensor_ev && sensor_pending==0 && !remote_ev &&
        !perf_ev && !watchdog_ev && !phone_releasing && !playing && !guide_active;
    always @(posedge clk or negedge rst_n)begin
        if(!rst_n)begin panic_quiescing<=0;panic_idle<=0;panic_blocked_keys<=0;end
        else begin
            panic_blocked_keys<=panic_blocked_keys & touch_mask;
            if(panic_request)begin
                panic_quiescing<=1;panic_idle<=0;panic_blocked_keys<=touch_mask;
            end else if(panic_quiescing)begin
                panic_blocked_keys<=touch_mask;
                if(!panic_producers_idle)panic_idle<=0;
                else if(panic_idle==31)begin panic_quiescing<=0;panic_idle<=0;end
                else panic_idle<=panic_idle+1'b1;
            end
        end
    end
    // 高扇出音频复位由寄存器驱动；PANIC仍先在事件入口切到丢弃/排空。
    // 复位断言至多增加一拍(20.35ns)，避免动作解码组合路径驱动数千寄存器。
    reg audio_reset_released;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n)audio_reset_released<=0;
        else audio_reset_released<=!panic_discard && !sensor_overflow;
    end
    wire audio_rst_n=rst_n && audio_reset_released;
    // Passive observation; none of these debug outputs controls the system.
    assign debug_audio_reset_status={panic_quiescing,panic_request,sensor_overflow,audio_rst_n};
    // Decode fixed source IDs in parallel instead of subtracting a variable
    // source and selecting a bit through a wide mux on the event ready path.
    wire [24:0] blocked_source_match;
    genvar blocked_key;
    generate for(blocked_key=0;blocked_key<25;blocked_key=blocked_key+1)begin:blocked_source_decode
        assign blocked_source_match[blocked_key]=
            sensor_source==(blocked_key+25) && panic_blocked_keys[blocked_key];
    end endgenerate
    wire sensor_blocked=|blocked_source_match;
    assign overflow_sticky=sensor_overflow || record_overflow || uart_overflows!=0;
    note_arbiter arbiter(.clk(clk),.rst_n(audio_rst_n),
        .in_valid({watchdog_ev,perf_ev,remote_ev,sensor_ev && !sensor_blocked}),.in_ready(arb_ready),
        .in_payload({watchdog_on,watchdog_source,watchdog_note,watchdog_velocity,watchdog_timbre,
            perf_on,perf_source,perf_note,perf_velocity,perf_timbre,
            remote_on,remote_source,remote_note,remote_velocity,remote_timbre,
            sensor_on,sensor_source,sensor_note,sensor_velocity,sensor_timbre}),
        .out_valid(arbiter_push_valid),.out_ready(push_ready),.out_payload(push_payload),.selected(arb_selected));
    // 复位寄存器生效前的一拍也禁止FIFO/录音接收旧事件；来源仍握手到丢弃端。
    assign push_valid=arbiter_push_valid && !panic_discard;
    assign sensor_er=panic_discard || sensor_blocked || arb_ready[0];
    assign remote_er=panic_discard || arb_ready[1];
    assign perf_er=panic_discard || arb_ready[2];
    assign watchdog_er=panic_discard || arb_ready[3];
    wire ev,er,eon;wire [5:0] es;wire [6:0] en,evel;wire [1:0] et;
    event_fifo_v2 #(.DEPTH(64),.AWIDTH(6)) events(.clk(clk),.rst_n(audio_rst_n),
        .push_valid(push_valid),.push_ready(push_ready),.push_on(push_payload[22]),
        .push_source(push_payload[21:16]),.push_note(push_payload[15:9]),.push_velocity(push_payload[8:2]),
        .push_timbre(push_payload[1:0]),.pop_valid(ev),.pop_ready(er),.pop_on(eon),.pop_source(es),
        .pop_note(en),.pop_velocity(evel),.pop_timbre(et));
    wire xv,xr;wire [11:0] xg;wire signed [12:0] xb;wire [7:0] vib;
    wire volume_xv,volume_xr,expression_a_ready;
    wire [11:0] volume_gain;
    wire [2:0] local_expression_mask;
    wire signed [12:0] local_expression_bend;
    wire [7:0] local_expression_vibrato;
    wire local_expression_enabled=MENU_ENABLE && (SLIDER_VOLUME_ENABLE || HIERARCHICAL_MENU_ENABLE);
    generate if(HIERARCHICAL_MENU_ENABLE && MENU_ENABLE)begin: local_expression
        slider_expression_control parameters(.clk(clk),.rst_n(audio_rst_n),.mode(menu_expression_mode),
            .position_valid(volume_position_valid),.position(volume_position),
            .touch_active(slider_active),.touch_fault(sensor_fault[0] || !sensor_ready[0]),
            .reset_expression(local_expression_reset),.expr_valid(volume_xv),.expr_ready(volume_xr),
            .expr_mask(local_expression_mask),.expr_gain(volume_gain),
            .expr_bend(local_expression_bend),.expr_vibrato(local_expression_vibrato));
    end else begin: legacy_expression
        assign local_expression_mask=3'b001;
        assign local_expression_bend=slider_bend;assign local_expression_vibrato=slider_vib;
    if(SLIDER_VOLUME_ENABLE && MENU_ENABLE) begin: local_volume
        slider_volume_control volume(.clk(clk),.rst_n(audio_rst_n),
            .position_valid(volume_position_valid),.position(volume_position),
            .expr_valid(volume_xv),.expr_ready(volume_xr),.expr_gain(volume_gain));
    end else begin: no_local_volume
        assign volume_xv=1'b0;
        assign volume_gain=12'd2048;
    end
    end endgenerate
    assign volume_xr=expression_a_ready;
    assign slider_xr=local_expression_enabled ? 1'b1 : expression_a_ready;
    expression_merge expression(.clk(clk),.rst_n(audio_rst_n),
        .a_valid(local_expression_enabled ? volume_xv : slider_xv),
        .a_ready(expression_a_ready),
        .a_mask(local_expression_enabled ? local_expression_mask : slider_xm),
        .a_gain(local_expression_enabled ? volume_gain : slider_gain),
        .a_bend(local_expression_bend),.a_vibrato(local_expression_vibrato),
        .b_valid(phone_xv),.b_ready(phone_xr),.b_mask(phone_xm),.b_gain(phone_gain),.b_bend(phone_bend),.b_vibrato(phone_vib),
        .out_valid(xv),.out_ready(xr),.out_gain(xg),.out_bend(xb),.out_vibrato(vib));
    wire cmdv,cmdr,cmdon,dv,dr,sample_begin;
    wire [5:0] voice,done_voice;wire [6:0] note,velocity;wire [1:0] tone;
    wire [11:0] gain;wire signed [12:0] bend;wire [7:0] vibrato;
    gain_percent_meter volume_meter(.clk(clk),.rst_n(rst_n),.gain(gain),.percent(menu_volume_percent));
    wire [12:0] bend_magnitude=bend[12]?-bend:bend;
    wire signed [13:0] bend_bar=$signed({bend[12],bend})+14'sd200;
    assign menu_control_value=menu_expression_mode==1?bend_magnitude[11:0]:
        menu_expression_mode==2?{4'd0,vibrato}:{4'd0,menu_volume_percent};
    assign menu_control_negative=menu_expression_mode==1 && bend[12];
    assign menu_control_percent=menu_expression_mode==1?
        ($signed(bend)<-200?8'd0:$signed(bend)>200?8'd100:bend_bar[9:2]):
        menu_expression_mode==2?vibrato:menu_volume_percent;
    always @(posedge clk or negedge audio_rst_n)begin
        if(!audio_rst_n)debug_last_note<=0;
        else if(cmdv && cmdr && cmdon)debug_last_note<=note;
    end
    captain_control_top_v2 control(.clk(clk),.rst_n(audio_rst_n),
        .event_valid(ev),.event_ready(er),.event_on(eon),.event_source(es),.event_note(en),.event_velocity(evel),.event_timbre(et),
        .expr_valid(xv),.expr_ready(xr),.expr_gain(xg),.expr_bend_cents(xb),.expr_vibrato_cents(vib),
        .engine_sample_begin(sample_begin),.active_gain(gain),.active_bend_cents(bend),.active_vibrato_cents(vibrato),
        .cmd_valid(cmdv),.cmd_ready(cmdr),.cmd_on(cmdon),.cmd_voice(voice),.cmd_note(note),.cmd_velocity(velocity),.cmd_timbre(tone),
        .done_valid(dv),.done_ready(dr),.done_voice(done_voice),.active_count(active_count));
    wire pcm_valid,pcm_ready;wire signed [23:0] pcm_l,pcm_r;
    voice_engine #(.FM_ENABLE(1),.FX_ENABLE(0),.AUTO_HEADROOM(1),.HEADROOM_SMOOTH(1),
        .STABLE_CHORD_GAIN(STABLE_CHORD_MIX_ENABLE),.ROM_DIR(ROM_DIR)) synth(.clk(clk),.rst_n(audio_rst_n),
        .cmd_valid(cmdv),.cmd_ready(cmdr),.cmd_on(cmdon),.cmd_voice(voice),.cmd_note(note),.cmd_velocity(velocity),.cmd_timbre(tone),
        .done_valid(dv),.done_ready(dr),.done_voice(done_voice),.sample_valid(pcm_valid),.sample_ready(pcm_ready),
        .sample_left(pcm_l),.sample_right(pcm_r),.engine_sample_begin(sample_begin),
        .active_gain(gain),.active_bend_cents(bend),.active_vibrato_cents(vibrato));
    wire fx_valid,fx_ready;wire signed [23:0] fx_l,fx_r;
    runtime_audio_fx effects(.clk(clk),.rst_n(audio_rst_n),.mode(fx),.in_valid(pcm_valid),.in_ready(pcm_ready),
        .in_left(pcm_l),.in_right(pcm_r),.out_valid(fx_valid),.out_ready(fx_ready),.out_left(fx_l),.out_right(fx_r));
    wire post_valid,post_ready;wire signed [23:0] post_l,post_r;
    ui_tone_overlay #(.SINE_FILE({ROM_DIR,"sine.hex"})) ui_prompt(
        .clk(clk),.rst_n(audio_rst_n),.prompt_valid(menu_prompt_valid),.prompt_code(menu_prompt_code),
        .in_valid(fx_valid),.in_ready(fx_ready),.in_left(fx_l),.in_right(fx_r),
        .out_valid(post_valid),.out_ready(post_ready),.out_left(post_l),.out_right(post_r));
    i2s_tx #(.BCLK_HALF_DIV(8)) audio(.clk(clk),.rst_n(audio_rst_n),.sample_valid(post_valid),.sample_ready(post_ready),
        .sample_left(post_l),.sample_right(post_r),.i2s_bclk(i2s_bclk),.i2s_lrclk(i2s_lrclk),.i2s_data(i2s_data),.underrun_count(underrun_count),
        .debug_frame_left(debug_transmit_left));
    assign monitor_left=post_l;assign monitor_right=post_r;assign monitor_valid=post_valid && post_ready;
    reg [1:0] video_reset;
    always @(posedge video_clk or negedge audio_rst_n)begin
        if(!audio_rst_n)video_reset<=0;else video_reset<={video_reset[0],1'b1};
    end
    wire vsample;wire signed [23:0] vl,vr;wire [31:0] cdc_drops;
    audio_monitor_cdc monitor(.src_clk(clk),.src_rst_n(audio_rst_n),.src_valid(monitor_valid),
        .src_left(post_l),.src_right(post_r),.drop_count(cdc_drops),.dst_clk(video_clk),.dst_rst_n(video_reset[1]),
        .dst_valid(vsample),.dst_left(vl),.dst_right(vr));
    wire [511:0] levels;wire [7:0] wave_index;wire signed [7:0] wave;wire [13:0] xy_addr;wire xy,xyvalid;
    audio_visualizer visual(.clk(video_clk),.rst_n(video_reset[1]),.sample_valid(vsample),.sample_left(vl),.sample_right(vr),
        .spectrum_levels(levels),.wave_read_index(wave_index),.wave_data(wave),.xy_read_addr(xy_addr),.xy_pixel(xy),.xy_valid(xyvalid));
    scope_renderer renderer(.clk(video_clk),.rst_n(video_reset[1]),.x(video_x),.y(video_y),.de(video_de),
        .wave_data(wave),.xy_pixel(xy),.xy_valid(xyvalid),.spectrum_levels(levels),
        .wave_read_index(wave_index),.xy_read_addr(xy_addr),.rgb(video_rgb));
endmodule
