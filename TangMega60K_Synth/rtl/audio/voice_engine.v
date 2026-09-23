// Audio owner implementation for the published V2 interface (166f043).
// Clock: 49.152 MHz, nominal Fs=48 kHz. Up to 15*N + overhead clocks/frame.
// clocks, independent of active count. State RAM has ONE arbitrated writer.
// Command mailbox is applied only outside voice scanning; no state lost update.
module voice_engine #(
    parameter VOICE_COUNT=64, SAMPLE_RATE=48000,
    parameter ATTACK_MS=10, DECAY_MS=80, RELEASE_MS=100,
    parameter PAN_SPREAD=1, MASTER_SHIFT=1,
    parameter FX_ENABLE=0, DELAY_SAMPLES=2400,
    parameter EXPRESSION_ENABLE=1,
    parameter FM_ENABLE=0,
    parameter ROM_DIR="rtl/audio/rom/"
) (
    input wire clk, rst_n,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire cmd_on,
    input wire [5:0] cmd_voice,
    input wire [6:0] cmd_note,cmd_velocity,
    input wire [1:0] cmd_timbre,
    output reg done_valid,
    input wire done_ready,
    output reg [5:0] done_voice,
    output wire sample_valid,
    input wire sample_ready,
    output wire signed [23:0] sample_left,sample_right,
    output wire engine_sample_begin,
    input wire [11:0] active_gain,
    input wire signed [12:0] active_bend_cents,
    input wire [7:0] active_vibrato_cents
);
    localparam INIT=0, IDLE=1, CMD_READ=2, CMD_WRITE=3, PREP=4, LATCH=5,
        EXPR_WAIT=6, V_READ=7, V_CALC=8, V_FREQ=9, V_ADDR=10,
        V_ROM=11, V_ENV=12, V_VEL=13, V_MIX=14, V_WRITE=15,
        MASTER=16, FX_SEND=17, OUTPUT_WAIT=18, V_TONE=19, V_TONE_SUM=20;
    reg [4:0] state;
    reg [5:0] init_id,voice_id;
    reg pending_command, pending_on;
    reg [5:0] pending_voice;
    reg [6:0] pending_note,pending_velocity;
    reg [1:0] pending_timbre;
    reg [VOICE_COUNT-1:0] done_pending;
    reg found_done;
    reg [5:0] selected_done;
    integer i;
    assign cmd_ready=rst_n && state!=INIT && !pending_command;
    assign engine_sample_begin=rst_n && state==PREP;
    // Exactly one pending command is applied, then PREP runs. Continuous
    // command traffic cannot starve audio. No new frame until output accepted.
    wire [5:0] ram_addr=(state==CMD_READ || state==CMD_WRITE) ? pending_voice : voice_id;
    wire [124:0] ram_data;
    reg ram_write;
    reg [5:0] ram_write_addr;
    reg [124:0] ram_write_data;
    voice_state_ram #(.VOICE_COUNT(VOICE_COUNT),.WIDTH(125)) u_state (
        .clk(clk),.read_addr(ram_addr),.read_data(ram_data),
        .write_enable(ram_write),.write_addr(ram_write_addr),.write_data(ram_write_data)
    );
    wire r_active=ram_data[100];
    wire [19:0] r_age=ram_data[120:101];
    wire [1:0] r_timbre=ram_data[99:98];
    wire [6:0] r_velocity=ram_data[97:91];
    wire [2:0] r_stage=ram_data[90:88];
    wire [23:0] r_env=ram_data[87:64];
    wire [31:0] r_base=ram_data[63:32],r_phase=ram_data[31:0];
    wire [2:0] env_next_stage;
    wire [23:0] env_next;
    wire env_finished;
    adsr #(.SAMPLE_RATE(SAMPLE_RATE),.ATTACK_MS(ATTACK_MS),
        .DECAY_MS(DECAY_MS),.RELEASE_MS(RELEASE_MS),.FM_ENABLE(FM_ENABLE)) u_adsr (
        .active(r_active),.timbre(r_timbre),.stage(r_stage),.level(r_env),
        .next_stage(env_next_stage),.next_level(env_next),.finished(env_finished)
    );
    wire expr_valid;
    wire [11:0] frame_gain;
    wire [22:0] frame_ratio;
    pitch_expression #(.SAMPLE_RATE(SAMPLE_RATE),.SINE_FILE({ROM_DIR,"sine.hex"}),
        .RATIO_FILE({ROM_DIR,"ratio.hex"})) u_expression (
        .clk(clk),.rst_n(rst_n),.start(state==LATCH),
        .gain_target(EXPRESSION_ENABLE ? active_gain : 12'd2048),
        .bend_target(EXPRESSION_ENABLE ? active_bend_cents : 13'sd0),
        .depth_target(EXPRESSION_ENABLE ? active_vibrato_cents : 8'd0),
        .valid(expr_valid),.frame_gain(frame_gain),.frame_ratio(frame_ratio)
    );
    reg w_active,w_finished;
    reg [1:0] w_timbre;
    reg [6:0] w_velocity;
    reg [2:0] w_stage;
    reg [23:0] w_env;
    reg [19:0] w_age;
    reg [31:0] w_base,w_phase,effective_ftw,phase_next;
    reg [54:0] pitch_product;
    wire [54:0] rounded_pitch=(pitch_product+55'd524288)>>20;
    wire [31:0] dds_next_phase;
    wire [11:0] dds_addr;
    reg [11:0] wave_addr;
    dds_lane u_dds (.phase(w_phase),.ftw(effective_ftw),.timbre(w_timbre),
        .next_phase(dds_next_phase),.wave_addr(dds_addr));
    wire signed [15:0] wave_sample;
    wire [31:0] note_ftw;
    wire [15:0] velocity_gain;
    reg signed [15:0] tone_sample;
    wire pv0,pv1;
    wire fm_valid;
    wire signed [15:0] fm_sample;
    wire signed [31:0] pL0,pR0,pL1,pR1;
    polar_lane #(.LANE(0),.ROM_DIR(ROM_DIR)) u_polar0 (
        .clk(clk),.rst_n(rst_n),.start(state==V_READ),.voice(voice_id),
        .active(r_active && r_timbre==2),.age(r_age),.fundamental_ftw(effective_ftw),.base_ftw(r_base),
        .valid(pv0),.left(pL0),.right(pR0));
    polar_lane #(.LANE(1),.ROM_DIR(ROM_DIR)) u_polar1 (
        .clk(clk),.rst_n(rst_n),.start(state==V_READ),.voice(voice_id),
        .active(r_active && r_timbre==2),.age(r_age),.fundamental_ftw(effective_ftw),.base_ftw(r_base),
        .valid(pv1),.left(pL1),.right(pR1));
    generate if(FM_ENABLE) begin: g_fm
        fm_piano_lane #(.ROM_DIR(ROM_DIR)) u_fm (
            .clk(clk),.rst_n(rst_n),.start(state==V_READ),.voice(voice_id),
            .active(r_active && r_timbre==3),.age(r_age),
            .velocity(r_velocity),.fundamental_ftw(effective_ftw),
            .valid(fm_valid),.sample(fm_sample));
    end else begin: g_no_fm
        assign fm_valid=1'b1;
        assign fm_sample=16'sd0;
    end endgenerate
    function signed [15:0] bound16;
        input signed [31:0] value;
        begin
            if(value>32767) bound16=16'sh7fff;
            else if(value < -32768) bound16=16'sh8000;
            else bound16=value[15:0];
        end
    endfunction
    wire signed [15:0] piano_left=bound16(pL0+pL1),piano_right=bound16(pR0+pR1);
    wavetable_rom #(.WAVE_FILE({ROM_DIR,"waves.hex"}),.NOTE_FILE({ROM_DIR,"midi.hex"}),
        .VELOCITY_FILE({ROM_DIR,"velocity.hex"}),.PIANO_FILE({ROM_DIR,"piano.hex"})) u_tables (
        .clk(clk),.wave_addr(wave_addr),.wave_sample(wave_sample),
        .note_addr(pending_note),.note_ftw(note_ftw),
        .velocity_addr(w_velocity),.velocity_gain(velocity_gain),
        .piano_addr(13'd0),.piano_body(),.piano_bright()
    );
    reg signed [32:0] env_product,velocity_product;
    reg signed [32:0] env_product_r,velocity_product_r;
    wire signed [32:0] env_rounded=(env_product+33'sd16384)>>>15;
    wire signed [15:0] env_sample=env_rounded[15:0];
    wire signed [32:0] vel_rounded=(velocity_product+33'sd16384)>>>15;
    wire signed [15:0] voice_sample=vel_rounded[15:0];
    wire signed [32:0] env_rounded_r=(env_product_r+33'sd16384)>>>15;
    wire signed [15:0] env_sample_r=env_rounded_r[15:0];
    wire signed [32:0] vel_rounded_r=(velocity_product_r+33'sd16384)>>>15;
    wire signed [15:0] voice_sample_r=vel_rounded_r[15:0];
    wire signed [31:0] mix_left,mix_right;
    stereo_mixer #(.PAN_SPREAD(PAN_SPREAD)) u_mixer (
        .clk(clk),.rst_n(rst_n),.clear(state==PREP),.add(state==V_MIX),
        .voice_id(voice_id),.sample_in(voice_sample),.left_sum(mix_left),.right_sum()
    );
    // Preserve the existing shift/add panning and master gain scale. Each
    // stereo partial is computed before per-voice panning, not collapsed mono.
    stereo_mixer #(.PAN_SPREAD(PAN_SPREAD)) u_mixer_r (
        .clk(clk),.rst_n(rst_n),.clear(state==PREP),.add(state==V_MIX),
        .voice_id(voice_id),.sample_in(voice_sample_r),.left_sum(),.right_sum(mix_right));
    wire signed [23:0] dry_left,dry_right;
    gain_saturator #(.SHIFT(MASTER_SHIFT)) u_gain (
        .clk(clk),.mix_left(mix_left),.mix_right(mix_right),.gain(frame_gain),
        .out_left(dry_left),.out_right(dry_right)
    );
    wire fx_ready;
    audio_fx #(.ENABLE(FX_ENABLE),.DELAY_SAMPLES(DELAY_SAMPLES)) u_fx (
        .clk(clk),.rst_n(rst_n),.bypass(!FX_ENABLE),
        .in_valid(state==FX_SEND),.in_ready(fx_ready),.in_left(dry_left),.in_right(dry_right),
        .out_valid(sample_valid),.out_ready(sample_ready),.out_left(sample_left),.out_right(sample_right)
    );
    always @(*) begin
        found_done=0; selected_done=0;
        for(i=0;i<VOICE_COUNT;i=i+1) if(done_pending[i] && !found_done) begin
            found_done=1; selected_done=i;
        end
        ram_write=0; ram_write_addr=0; ram_write_data=0;
        if(state==INIT) begin ram_write=1; ram_write_addr=init_id; end
        else if(state==CMD_WRITE && pending_voice<VOICE_COUNT) begin
            ram_write=1; ram_write_addr=pending_voice;
            if(pending_on) begin
                // Keep phase/envelope on held retrigger; fresh voice starts at 0.
                if(pending_timbre==2 || (FM_ENABLE && pending_timbre==3)) begin
                    // Held piano retrigger ramps the gate down first, then
                    // restarts the parameter age; no instantaneous phase reset.
                    ram_write_data={4'd0,(r_active && r_timbre==pending_timbre ? r_age : 20'd0),
                        1'b1,pending_timbre,pending_velocity,
                        (r_active && r_timbre==pending_timbre ? 3'd5 : 3'd1),
                        (r_active && r_timbre==pending_timbre ? r_env : 24'd0),note_ftw,
                        (r_active ? r_phase : 32'd0)};
                end else ram_write_data={24'd0,1'b1,pending_timbre,pending_velocity,3'd1,
                    (r_active ? r_env : 24'd0),note_ftw,(r_active ? r_phase : 32'd0)};
            end else begin
                // Do not overwrite note, velocity or timbre on release.
                ram_write_data=ram_data;
                if(r_active) ram_write_data[90:88]=3'd4;
            end
        end else if(state==V_WRITE) begin
            ram_write=1; ram_write_addr=voice_id;
            ram_write_data={4'd0,w_age,w_active && !w_finished,w_timbre,w_velocity,w_stage,w_env,w_base,phase_next};
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=INIT; init_id<=0; voice_id<=0;
            pending_command<=0; pending_on<=0; pending_voice<=0;
            pending_note<=0; pending_velocity<=0; pending_timbre<=0;
            done_pending<=0; done_valid<=0; done_voice<=0;
            w_active<=0; w_finished<=0; w_timbre<=0; w_velocity<=0;
            w_stage<=0; w_env<=0; w_base<=0; w_phase<=0; phase_next<=0;
            effective_ftw<=0; pitch_product<=0; wave_addr<=0;
            env_product<=0; velocity_product<=0;
            w_age<=0; tone_sample<=0; env_product_r<=0; velocity_product_r<=0;
        end else begin
            if(cmd_valid && cmd_ready) begin
                pending_command<=1; pending_on<=cmd_on; pending_voice<=cmd_voice;
                pending_note<=cmd_note; pending_velocity<=cmd_velocity; pending_timbre<=cmd_timbre;
            end
            // Registered choice cannot change under done backpressure.
            if(done_valid) begin
                if(done_ready) begin done_valid<=0; done_pending[done_voice]<=0; end
            end else if(found_done) begin done_valid<=1; done_voice<=selected_done; end
            case(state)
                INIT: if(init_id==VOICE_COUNT-1) state<=IDLE; else init_id<=init_id+1'b1;
                IDLE: if(pending_command) state<=CMD_READ; else state<=PREP;
                CMD_READ: state<=CMD_WRITE;
                CMD_WRITE: begin pending_command<=0; state<=PREP; end
                PREP: state<=LATCH;
                LATCH: state<=EXPR_WAIT;
                EXPR_WAIT: if(expr_valid) begin voice_id<=0; state<=V_READ; end
                V_READ: state<=V_CALC;
                V_CALC: begin
                    w_active<=r_active; w_finished<=env_finished; w_timbre<=r_timbre;
                    w_velocity<=r_velocity; w_stage<=env_next_stage; w_env<=env_next;
                    w_age<=!r_active || ((r_timbre==2 || (FM_ENABLE && r_timbre==3)) && r_stage==5 && env_next_stage==1)
                        ? 20'd0 : r_age==20'hfffff ? r_age : r_age+1'b1;
                    w_base<=r_base; w_phase<=r_phase;
                    pitch_product<=r_base*frame_ratio;
                    state<=V_FREQ;
                end
                V_FREQ: begin
                    // Clamp to 0.45 Fs instead of wrapping an out-of-band pitch.
                    effective_ftw<=rounded_pitch>55'h73333333 ? 32'h73333333 : rounded_pitch[31:0];
                    state<=V_ADDR;
                end
                V_ADDR: begin
                    wave_addr<=dds_addr;
                    phase_next<=w_active ? dds_next_phase : w_phase;
                    state<=V_ROM;
                end
                V_ROM: state<=V_TONE;
                V_TONE: begin
                    state<=V_TONE_SUM;
                end
                V_TONE_SUM: begin
                    tone_sample<=wave_sample;
                    state<=V_ENV;
                end
                V_ENV: begin
                    if((w_timbre!=2 || (pv0 && pv1)) && (!FM_ENABLE || w_timbre!=3 || fm_valid)) begin
                        env_product<=(w_timbre==2 ? piano_left : FM_ENABLE && w_timbre==3 ? fm_sample : tone_sample)*$signed({1'b0,w_env[23:8]});
                        env_product_r<=(w_timbre==2 ? piano_right : FM_ENABLE && w_timbre==3 ? fm_sample : tone_sample)*$signed({1'b0,w_env[23:8]});
                        state<=V_VEL;
                    end
                end
                V_VEL: begin
                    velocity_product<=env_sample*$signed({1'b0,velocity_gain});
                    velocity_product_r<=env_sample_r*$signed({1'b0,velocity_gain});
                    state<=V_MIX;
                end
                V_MIX: state<=V_WRITE;
                V_WRITE: begin
                    if(w_finished) done_pending[voice_id]<=1;
                    if(voice_id==VOICE_COUNT-1) state<=MASTER;
                    else begin voice_id<=voice_id+1'b1; state<=V_READ; end
                end
                MASTER: state<=FX_SEND;
                FX_SEND: if(fx_ready) state<=OUTPUT_WAIT;
                OUTPUT_WAIT: if(sample_valid && sample_ready) state<=IDLE;
                default: state<=INIT;
            endcase
        end
    end
endmodule
