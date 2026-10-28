// Three electrically independent I2C buses: 8+8+9 keys, module 0 ELE8..11 slider.
// Board owns IRQ synchronization, voltage checks and actual pin constraints.
module mpr121_input_frontend #(
    parameter integer CLK_HZ=49152000,I2C_HZ=400000,
    parameter integer TIMEOUT_CYCLES=CLK_HZ/200,POLL_CYCLES=CLK_HZ/2000,
    parameter integer RESET_CYCLES=CLK_HZ/1000,SETTLE_CYCLES=CLK_HZ/20,
    parameter integer RETRY_CYCLES=CLK_HZ/10,CALIBRATION_SNAPSHOTS=3,MAX_RETRIES=2,
    parameter [6:0] ADDR0=7'h5a,ADDR1=7'h5a,ADDR2=7'h5a,
    parameter integer SOURCE_BASE=25,EVENT_FIFO_DEPTH=64,
    parameter integer EARLY_KEY_ENABLE=0,
    parameter [7:0] TOUCH_THRESHOLD=12,RELEASE_THRESHOLD=6,
    parameter [7:0] FILTER_CDC=8'h10,FILTER_CDT=8'h20,
    parameter integer SLIDER_NOISE0=4,SLIDER_NOISE1=4,SLIDER_NOISE2=4,SLIDER_NOISE3=4,
    parameter integer SLIDER_GAIN0=256,SLIDER_GAIN1=256,SLIDER_GAIN2=256,SLIDER_GAIN3=256,
    parameter integer SLIDER_MIN_WEIGHT=12,SLIDER_POSITION_MIN=0,SLIDER_POSITION_MAX=3072,
    parameter integer SLIDER_BEND_MAX=200, SLIDER_BEND_ENABLE=1
)(
    input wire clk,resetn,input wire [2:0] irq_n,
    inout wire [2:0] scl,sda,
    input wire [174:0] key_map_flat,input wire [1:0] current_timbre,
    output wire key_valid,input wire key_ready,
    output wire key_on,output wire [5:0] key_source,
    output wire [6:0] key_note,key_velocity,output wire [1:0] key_timbre,
    output wire expr_update_valid,input wire expr_update_ready,
    output wire [2:0] expr_update_mask,
    output wire [11:0] expr_update_gain_q1_11,
    output wire signed [12:0] expr_update_bend_cents,
    output wire [7:0] expr_update_vibrato_depth_cents,
    output wire [24:0] touch_mask,output wire [2:0] fault,ready,
    output wire event_overflow,output wire [15:0] pending_events,
    output wire [11:0] last_error,output wire [95:0] error_count,last_success_age,
    output wire [14:0] init_stage,output wire [47:0] oor_status,
    output wire slider_active,output wire [11:0] slider_position
);
    wire [2:0] snap_valid,snap_ready;
    wire [1031:0] snaps;
    wire [2:0] early_valid,early_ready,event_snapshot_ready;
    wire [35:0] early_status;
    // 快通道只接键事件；滑条继续接完整且一致的43字节快照，不能回灌旧键状态。
    assign snap_ready=EARLY_KEY_ENABLE?3'b111:event_snapshot_ready;
    assign early_ready=EARLY_KEY_ENABLE?event_snapshot_ready:3'b111;
    genvar g;
    generate for(g=0;g<3;g=g+1) begin: sensors
      mpr121_sampler #(.CLK_HZ(CLK_HZ),.I2C_HZ(I2C_HZ),.TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .POLL_CYCLES(POLL_CYCLES),.RESET_CYCLES(RESET_CYCLES),.SETTLE_CYCLES(SETTLE_CYCLES),
        .RETRY_CYCLES(RETRY_CYCLES),.CALIBRATION_SNAPSHOTS(CALIBRATION_SNAPSHOTS),
        .MAX_RETRIES(MAX_RETRIES),.ELECTRODES((g==0)?12:((g==1)?8:9)),
        .EARLY_KEY_ENABLE(EARLY_KEY_ENABLE),
        .I2C_ADDR((g==0)?ADDR0:((g==1)?ADDR1:ADDR2)),
        .TOUCH_THRESHOLD(TOUCH_THRESHOLD),.RELEASE_THRESHOLD(RELEASE_THRESHOLD),
        .FILTER_CDC(FILTER_CDC),.FILTER_CDT(FILTER_CDT)) sampler(
        .clk(clk),.resetn(resetn),.irq_n(irq_n[g]),.snapshot_ready(snap_ready[g]),
        .snapshot_valid(snap_valid[g]),.snapshot(snaps[g*344 +:344]),
        .ready(ready[g]),.fault(fault[g]),.last_error(last_error[g*4 +:4]),
        .error_count(error_count[g*32 +:32]),.last_success_age(last_success_age[g*32 +:32]),
        .init_stage(init_stage[g*5 +:5]),.oor_status(oor_status[g*16 +:16]),
        .scl(scl[g]),.sda(sda[g]),.early_key_valid(early_valid[g]),
        .early_key_ready(early_ready[g]),.early_key_status(early_status[g*12+:12]));
    end endgenerate
    mpr121_key_eventizer #(.FIFO_DEPTH(EVENT_FIFO_DEPTH),.SOURCE_BASE(SOURCE_BASE)) eventizer(
      .clk(clk),.resetn(resetn),.snapshot_valid(EARLY_KEY_ENABLE?early_valid:snap_valid),.snapshot_ready(event_snapshot_ready),
      .touch0(EARLY_KEY_ENABLE?early_status[7:0]:snaps[7:0]),
      .touch1(EARLY_KEY_ENABLE?early_status[12+:8]:snaps[344+:8]),
      .touch2(EARLY_KEY_ENABLE?early_status[24+:9]:snaps[688+:9]),
      .fault(fault),.key_map_flat(key_map_flat),.current_timbre(current_timbre),
      .key_valid(key_valid),.key_ready(key_ready),.key_on(key_on),.key_source(key_source),
      .key_note(key_note),.key_velocity(key_velocity),.key_timbre(key_timbre),
      .touch_mask(touch_mask),.overflow(event_overflow),.pending_events(pending_events));
    wire signed [12:0] latest_bend;
    mpr121_slider #(.NOISE0(SLIDER_NOISE0),.NOISE1(SLIDER_NOISE1),.NOISE2(SLIDER_NOISE2),
      .NOISE3(SLIDER_NOISE3),.GAIN0(SLIDER_GAIN0),.GAIN1(SLIDER_GAIN1),
      .GAIN2(SLIDER_GAIN2),.GAIN3(SLIDER_GAIN3),.MIN_WEIGHT(SLIDER_MIN_WEIGHT),
      .POSITION_MIN(SLIDER_POSITION_MIN),.POSITION_MAX(SLIDER_POSITION_MAX),
      .BEND_MAX_CENTS(SLIDER_BEND_MAX),.BEND_ENABLE(SLIDER_BEND_ENABLE)) slider(
      .clk(clk),.resetn(resetn),.snapshot_strobe(snap_valid[0] && snap_ready[0]),
      .snapshot(snaps[343:0]),.fault(fault[0]),
      .expr_update_valid(expr_update_valid),.expr_update_ready(expr_update_ready),
      .expr_update_mask(expr_update_mask),.expr_update_gain_q1_11(expr_update_gain_q1_11),
      .expr_update_bend_cents(expr_update_bend_cents),
      .expr_update_vibrato_depth_cents(expr_update_vibrato_depth_cents),
      .active(slider_active),.position(slider_position),.latest_bend(latest_bend));
endmodule
