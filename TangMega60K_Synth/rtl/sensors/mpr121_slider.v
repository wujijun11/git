// Signed baseline-filtered deltas with per-electrode noise/gain calibration.
// Sequential restoring division takes 32 clocks, avoiding a variable combinational divider.
module mpr121_slider #(
    parameter integer NOISE0=4,NOISE1=4,NOISE2=4,NOISE3=4,
    parameter integer GAIN0=256,GAIN1=256,GAIN2=256,GAIN3=256,
    parameter integer MIN_WEIGHT=12, POSITION_MIN=0,POSITION_MAX=3072,
    parameter integer BEND_MAX_CENTS=200, DEADZONE_CENTS=3,HYSTERESIS_CENTS=2,
    // 旧采集测试默认仍输出弯音；菜单入口只取位置，不提交表情参数。
    parameter integer BEND_ENABLE=1
)(
    input wire clk,resetn, snapshot_strobe,input wire [343:0] snapshot,
    input wire fault,
    output reg expr_update_valid,input wire expr_update_ready,
    output wire [2:0] expr_update_mask,
    output wire [11:0] expr_update_gain_q1_11,
    output reg signed [12:0] expr_update_bend_cents,
    output wire [7:0] expr_update_vibrato_depth_cents,
    output reg active,output reg [11:0] position,
    output reg signed [12:0] latest_bend
);
    assign expr_update_mask=3'b010;
    assign expr_update_gain_q1_11=12'd2048;
    assign expr_update_vibrato_depth_cents=0;
    integer f0,f1,f2,f3,d0,d1,d2,d3,w0,w1,w2,w3,total,numer;
    always @* begin
        f0={snapshot[21*8 +:2],snapshot[20*8 +:8]};
        f1={snapshot[23*8 +:2],snapshot[22*8 +:8]};
        f2={snapshot[25*8 +:2],snapshot[24*8 +:8]};
        f3={snapshot[27*8 +:2],snapshot[26*8 +:8]};
        d0=({snapshot[38*8 +:8],2'b00})-f0-NOISE0;
        d1=({snapshot[39*8 +:8],2'b00})-f1-NOISE1;
        d2=({snapshot[40*8 +:8],2'b00})-f2-NOISE2;
        d3=({snapshot[41*8 +:8],2'b00})-f3-NOISE3;
        w0=(d0>0)?(d0*GAIN0)/256:0;w1=(d1>0)?(d1*GAIN1)/256:0;
        w2=(d2>0)?(d2*GAIN2)/256:0;w3=(d3>0)?(d3*GAIN3)/256:0;
        total=w0+w1+w2+w3;numer=(w1+2*w2+3*w3)*1024;
    end
    localparam [2:0] IDLE=0,DIV_POSITION=1,CLAMP_POSITION=2,
      PREP_BEND=3,DIV_BEND=4,APPLY_BEND=5;
    localparam signed [12:0] MAX_BEND=BEND_MAX_CENTS;
    reg [2:0] state;
    reg [5:0] cycles;
    reg [31:0] quotient,divisor;reg [32:0] remainder;
    reg [11:0] raw_position,bend_units;
    wire [32:0] trial={remainder[31:0],quotient[31]};
    wire subtract=(trial>={1'b0,divisor});
    wire [31:0] next_quotient={quotient[30:0],subtract};
    wire signed [12:0] raw_bend=$signed({1'b0,bend_units})-MAX_BEND;
    wire signed [12:0] centered_bend=(raw_bend>=-DEADZONE_CENTS && raw_bend<=DEADZONE_CENTS)?13'sd0:raw_bend;
    wire signed [13:0] bend_diff=$signed({centered_bend[12],centered_bend})-$signed({latest_bend[12],latest_bend});
    always @(posedge clk) begin
        if(!resetn) begin
            state<=IDLE;cycles<=0;quotient<=0;divisor<=1;remainder<=0;raw_position<=1536;bend_units<=0;
            active<=0;position<=1536;latest_bend<=0;expr_update_valid<=0;expr_update_bend_cents<=0;
        end else begin
            if(expr_update_valid && expr_update_ready) expr_update_valid<=0;
            if(BEND_ENABLE && (!expr_update_valid || expr_update_ready) && expr_update_bend_cents!=latest_bend) begin
                expr_update_bend_cents<=latest_bend;expr_update_valid<=1;
            end
            if(fault) begin active<=0;latest_bend<=0;state<=IDLE;position<=1536;end
            else if(snapshot_strobe && state==IDLE) begin
                if(total<MIN_WEIGHT || snapshot[11:8]==0) begin
                    active<=0;latest_bend<=0;position<=1536;
                end else begin
                    divisor<=total;quotient<=numer;remainder<=0;cycles<=0;state<=DIV_POSITION;active<=1;
                end
            end else if(state==DIV_POSITION || state==DIV_BEND) begin
                quotient<=next_quotient;
                remainder<=subtract?(trial-{1'b0,divisor}):trial;
                if(cycles==31) begin
                    if(state==DIV_POSITION) begin raw_position<=next_quotient[11:0];state<=CLAMP_POSITION;end
                    else begin bend_units<=next_quotient[11:0];state<=APPLY_BEND;end
                end else cycles<=cycles+1;
            end else if(state==CLAMP_POSITION) begin
                if(raw_position<POSITION_MIN) position<=POSITION_MIN;
                else if(raw_position>POSITION_MAX) position<=POSITION_MAX;
                else position<=raw_position;
                state<=BEND_ENABLE ? PREP_BEND : IDLE;
            end else if(state==PREP_BEND) begin
                // Reuse the sequential divider for calibrated endpoint mapping;
                // a constant /3072 combinational divider exceeded 49.152MHz.
                quotient<=(position-POSITION_MIN)*2*BEND_MAX_CENTS+(POSITION_MAX-POSITION_MIN)/2;
                divisor<=POSITION_MAX-POSITION_MIN;remainder<=0;cycles<=0;state<=DIV_BEND;
            end else if(state==APPLY_BEND) begin
                if(bend_diff>=HYSTERESIS_CENTS || bend_diff<=-HYSTERESIS_CENTS || centered_bend==0)
                    latest_bend<=centered_bend;
                state<=IDLE;
            end
        end
    end
endmodule
