// Stereo circular delay. Exact dry bypass; bypass also freezes delay history.
// Static Q0.15 feedback is clamped to <=0.75. SRAM is not reset; fill count
// prevents stale/uninitialized samples from being observed after reset.
module audio_fx #(
    parameter ENABLE=0, DELAY_SAMPLES=2400,
    parameter FEEDBACK_Q15=16384, WET_Q15=8192
) (
    input wire clk, rst_n, bypass,
    input wire in_valid,
    output wire in_ready,
    input wire signed [23:0] in_left, in_right,
    output reg out_valid,
    input wire out_ready,
    output reg signed [23:0] out_left, out_right
);
    function integer width;
        input integer n;
        integer k;
        begin k=n-1; width=0; while(k>0) begin width=width+1; k=k>>1; end
            if (width<1) width=1;
        end
    endfunction
    generate if (!ENABLE) begin: dry_only
        assign in_ready=rst_n && (!out_valid || out_ready);
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin out_valid<=0; out_left<=0; out_right<=0; end
            else if (in_ready) begin
                out_valid<=in_valid;
                if (in_valid) begin out_left<=in_left; out_right<=in_right; end
            end
        end
    end else begin: delay_line
        localparam AW=width(DELAY_SAMPLES);
        localparam signed [16:0] FB=(FEEDBACK_Q15<0) ? 0 :
            (FEEDBACK_Q15>24576) ? 24576 : FEEDBACK_Q15;
        localparam signed [16:0] WET=(WET_Q15<0) ? 0 :
            (WET_Q15>32768) ? 32768 : WET_Q15;
        reg signed [23:0] mem_l[0:DELAY_SAMPLES-1],mem_r[0:DELAY_SAMPLES-1];
        reg signed [23:0] delayed_l,delayed_r,dry_l,dry_r;
        reg signed [40:0] feedback_l,feedback_r,wet_l,wet_r;
        reg [AW-1:0] ptr;
        reg [AW:0] filled;
        reg [1:0] state;
        wire accept=in_valid && in_ready;
        wire signed [40:0] dl={{17{dry_l[23]}},dry_l};
        wire signed [40:0] dr={{17{dry_r[23]}},dry_r};
        function [23:0] sat;
            input signed [40:0] x;
            begin
                if(x>41'sd8388607) sat=24'h7fffff;
                else if(x < -41'sd8388608) sat=24'h800000;
                else sat=x[23:0];
            end
        endfunction
        assign in_ready=rst_n && state==0 && (!out_valid || out_ready);
        always @(posedge clk) begin
            if(accept && !bypass) begin
                delayed_l<=mem_l[ptr]; delayed_r<=mem_r[ptr];
            end
            if(state==2) begin
                mem_l[ptr]<=sat(dl+((feedback_l+41'sd16384)>>>15));
                mem_r[ptr]<=sat(dr+((feedback_r+41'sd16384)>>>15));
            end
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                state<=0; ptr<=0; filled<=0; out_valid<=0; out_left<=0; out_right<=0;
                dry_l<=0; dry_r<=0; feedback_l<=0; feedback_r<=0; wet_l<=0; wet_r<=0;
            end else begin
                if(out_valid && out_ready) out_valid<=0;
                if(accept) begin
                    if(bypass) begin out_valid<=1; out_left<=in_left; out_right<=in_right; end
                    else begin dry_l<=in_left; dry_r<=in_right; state<=1; end
                end
                if(state==1) begin
                    feedback_l<=(filled==DELAY_SAMPLES) ? delayed_l*FB : 41'sd0;
                    feedback_r<=(filled==DELAY_SAMPLES) ? delayed_r*FB : 41'sd0;
                    wet_l<=(filled==DELAY_SAMPLES) ? delayed_l*WET : 41'sd0;
                    wet_r<=(filled==DELAY_SAMPLES) ? delayed_r*WET : 41'sd0;
                    state<=2;
                end
                if(state==2) begin
                    out_left<=sat(dl+((wet_l+41'sd16384)>>>15));
                    out_right<=sat(dr+((wet_r+41'sd16384)>>>15));
                    out_valid<=1; state<=0;
                    if(ptr==DELAY_SAMPLES-1) ptr<=0; else ptr<=ptr+1'b1;
                    if(filled<DELAY_SAMPLES) filled<=filled+1'b1;
                end
            end
        end
    end endgenerate
endmodule
