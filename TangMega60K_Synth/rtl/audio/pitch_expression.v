// One start per GENERATED stereo frame; start is AFTER captain's begin edge.
// Slew is in sample time, finite and exact at the target. No change on stalls.
module pitch_expression #(
    parameter SAMPLE_RATE=48000,
    parameter GAIN_STEP=8,
    parameter BEND_STEP=4,
    parameter DEPTH_STEP=1,
    parameter SINE_FILE="rtl/audio/rom/sine.hex",
    parameter RATIO_FILE="rtl/audio/rom/ratio.hex"
) (
    input wire clk, rst_n, start,
    input wire [11:0] gain_target,
    input wire signed [12:0] bend_target,
    input wire [7:0] depth_target,
    output reg valid,
    output wire [11:0] frame_gain,
    output reg [22:0] frame_ratio
);
    localparam [31:0] LFO_STEP=(64'd21474836480+SAMPLE_RATE/2)/SAMPLE_RATE;
    reg signed [15:0] sine [0:1023];
    reg [23:0] ratios [0:5000]; // hex file has six digits; bit23 is always zero
    reg [31:0] lfo_phase;
    reg signed [15:0] lfo_value;
    reg [11:0] gain_smooth;
    reg signed [12:0] bend_smooth;
    reg [7:0] depth_smooth;
    reg signed [24:0] vibrato_product;
    reg signed [13:0] total_cents;
    reg [12:0] ratio_addr;
    reg [23:0] ratio_data;
    reg [2:0] pipe;
    integer g_next,b_next,d_next;
    wire signed [12:0] safe_bend=(bend_target>13'sd2400) ? 13'sd2400 :
        (bend_target < -13'sd2400) ? -13'sd2400 : bend_target;
    wire [7:0] safe_depth=depth_target>100 ? 8'd100 : depth_target;
    wire signed [24:0] vibrato_cents=($signed(vibrato_product)+25'sd16384)>>>15;
    wire signed [13:0] combined_cents=$signed({bend_smooth[12],bend_smooth})+
        $signed(vibrato_cents[13:0]);
    wire [13:0] table_index=total_cents+14'sd2500;
    assign frame_gain=gain_smooth;
    initial begin $readmemh(SINE_FILE,sine); $readmemh(RATIO_FILE,ratios); end
    always @(*) begin
        g_next=gain_smooth;
        if (gain_target>gain_smooth) begin
            g_next=gain_smooth+GAIN_STEP;
            if (g_next>gain_target) g_next=gain_target;
        end else if (gain_target<gain_smooth) begin
            g_next=gain_smooth-GAIN_STEP;
            if (g_next<gain_target) g_next=gain_target;
        end
        b_next=$signed(bend_smooth);
        if ($signed(safe_bend)>$signed(bend_smooth)) begin
            b_next=$signed(bend_smooth)+BEND_STEP;
            if (b_next>$signed(safe_bend)) b_next=$signed(safe_bend);
        end else if ($signed(safe_bend)<$signed(bend_smooth)) begin
            b_next=$signed(bend_smooth)-BEND_STEP;
            if (b_next<$signed(safe_bend)) b_next=$signed(safe_bend);
        end
        d_next=depth_smooth;
        if (safe_depth>depth_smooth) begin
            d_next=depth_smooth+DEPTH_STEP;
            if (d_next>safe_depth) d_next=safe_depth;
        end else if (safe_depth<depth_smooth) begin
            d_next=depth_smooth-DEPTH_STEP;
            if (d_next<safe_depth) d_next=safe_depth;
        end
    end
    always @(posedge clk) begin
        lfo_value<=sine[lfo_phase[31:22]];
        ratio_data<=ratios[ratio_addr];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfo_phase<=0; gain_smooth<=2048; bend_smooth<=0; depth_smooth<=0;
            pipe<=0; valid<=0; ratio_addr<=2500; total_cents<=0;
            vibrato_product<=0; frame_ratio<=23'd1048576;
        end else begin
            valid<=0;
            if (start && pipe==0) begin
                gain_smooth<=g_next[11:0]; bend_smooth<=b_next[12:0]; depth_smooth<=d_next[7:0];
                lfo_phase<=lfo_phase+LFO_STEP;
                pipe<=1;
            end else case (pipe)
                1: begin
                    vibrato_product<=$signed(lfo_value)*$signed({1'b0,depth_smooth});
                    pipe<=2;
                end
                2: begin
                    // Round to nearest cent, ties toward +infinity.
                    total_cents<=combined_cents;
                    pipe<=3;
                end
                3: begin ratio_addr<=table_index[12:0]; pipe<=4; end
                4: pipe<=5; // synchronous ratio ROM latency
                5: begin frame_ratio<=ratio_data[22:0]; valid<=1; pipe<=0; end
                default: pipe<=0;
            endcase
        end
    end
endmodule
