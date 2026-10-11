// Frame-atomic dry / feedback delay / Schroeder reverb / chorus selection.
// Histories restart at mode changes. SRAM is never globally reset; fill guards
// make reset and transitions deterministic without exposing old RAM contents.
module runtime_audio_fx #(
    // 40ms stereo delay at 48kHz; leave BSRAM for sensors and visualization.
    parameter HIST_SIZE=2048, HIST_AW=11, DELAY_LENGTH=1920,
    parameter CHORUS_BASE=480, CHORUS_DEPTH=96,
    parameter COMB0=1493, COMB1=1601, COMB2=1747, COMB3=1879,
    parameter AP0=113, AP1=337
) (
    input wire clk,rst_n,input wire [1:0] mode,
    input wire in_valid,output wire in_ready,
    input wire signed [23:0] in_left,in_right,
    output reg out_valid,input wire out_ready,
    output reg signed [23:0] out_left,out_right
);
    reg [2:0] state;
    reg [1:0] active_mode;
    reg signed [23:0] dry_l,dry_r,delay_l,delay_r;
    reg signed [23:0] hist_l[0:HIST_SIZE-1],hist_r[0:HIST_SIZE-1];
    reg [HIST_AW-1:0] ptr,read_ptr;
    reg [HIST_AW:0] filled;
    reg [15:0] phase;
    wire [6:0] triangle=phase[15] ? ~phase[14:8] : phase[14:8];
    wire [HIST_AW:0] lag=(mode==1) ? DELAY_LENGTH :
        CHORUS_BASE+(triangle*CHORUS_DEPTH)/128;
    wire [HIST_AW-1:0] raddr=ptr-lag;
    reg lag_valid;
    reg signed [15:0] comb_mem0[0:COMB0-1],comb_mem1[0:COMB1-1];
    reg signed [15:0] comb_mem2[0:COMB2-1],comb_mem3[0:COMB3-1];
    reg signed [15:0] ap_mem0[0:AP0-1],ap_mem1[0:AP1-1];
    reg [11:0] cptr0,cptr1,cptr2,cptr3,aptr0,aptr1;
    reg [12:0] cfill0,cfill1,cfill2,cfill3,afill0,afill1;
    reg signed [15:0] tap0,tap1,tap2,tap3,at0,at1,mono,comb_average;
    reg signed [19:0] aout0,aout1;
    wire accept=in_valid && in_ready;
    wire change=mode!=active_mode;
    wire signed [24:0] stereo_sum=$signed({in_left[23],in_left})+$signed({in_right[23],in_right});
    wire signed [19:0] t0=(cfill0==COMB0) ? {{4{tap0[15]}},tap0} : 20'sd0;
    wire signed [19:0] t1=(cfill1==COMB1) ? {{4{tap1[15]}},tap1} : 20'sd0;
    wire signed [19:0] t2=(cfill2==COMB2) ? {{4{tap2[15]}},tap2} : 20'sd0;
    wire signed [19:0] t3=(cfill3==COMB3) ? {{4{tap3[15]}},tap3} : 20'sd0;
    wire signed [19:0] m={{4{mono[15]}},mono};
    wire signed [19:0] cav={{4{comb_average[15]}},comb_average};
    wire signed [19:0] av0=(afill0==AP0) ? {{4{at0[15]}},at0} : 20'sd0;
    wire signed [19:0] av1=(afill1==AP1) ? {{4{at1[15]}},at1} : 20'sd0;
    function [23:0] sat24;
        input signed [31:0] x;
        begin
            if(x>32'sd8388607) sat24=24'h7fffff;
            else if(x< -32'sd8388608) sat24=24'h800000;
            else sat24=x[23:0];
        end
    endfunction
    function [15:0] sat16;
        input signed [19:0] x;
        begin
            if(x>20'sd32767) sat16=16'h7fff;
            else if(x< -20'sd32768) sat16=16'h8000;
            else sat16=x[15:0];
        end
    endfunction
    wire signed [31:0] dl={{8{dry_l[23]}},dry_l},dr={{8{dry_r[23]}},dry_r};
    wire signed [31:0] el=lag_valid ? {{8{delay_l[23]}},delay_l} : 32'sd0;
    wire signed [31:0] er=lag_valid ? {{8{delay_r[23]}},delay_r} : 32'sd0;
    assign in_ready=rst_n && state==0 && (!out_valid || out_ready);
    // Separate synchronous memory processes permit block RAM inference.
    always @(posedge clk) begin
        if(accept && !change && (mode==1 || mode==3)) begin
            delay_l<=hist_l[raddr]; delay_r<=hist_r[raddr];
        end
        if(state==1 && (active_mode==1 || active_mode==3)) begin
            hist_l[ptr]<=sat24(dl+((active_mode==1) ? (el>>>1) : 32'sd0));
            hist_r[ptr]<=sat24(dr+((active_mode==1) ? (er>>>1) : 32'sd0));
        end
        if(accept && !change && mode==2) begin
            tap0<=comb_mem0[cptr0]; tap1<=comb_mem1[cptr1];
            tap2<=comb_mem2[cptr2]; tap3<=comb_mem3[cptr3];
        end
        if(state==1 && active_mode==2) begin
            comb_mem0[cptr0]<=sat16(m+(t0>>>1)+(t0>>>2));
            comb_mem1[cptr1]<=sat16(m+(t1>>>1)+(t1>>>2));
            comb_mem2[cptr2]<=sat16(m+(t2>>>1)+(t2>>>2));
            comb_mem3[cptr3]<=sat16(m+(t3>>>1)+(t3>>>2));
            at0<=ap_mem0[aptr0]; at1<=ap_mem1[aptr1];
        end
        if(state==3) begin
            ap_mem0[aptr0]<=sat16(cav+(aout0>>>1));
            ap_mem1[aptr1]<=sat16(cav+(aout1>>>1));
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=0; active_mode<=0; out_valid<=0; out_left<=0; out_right<=0;
            dry_l<=0; dry_r<=0; ptr<=0; filled<=0; phase<=0; lag_valid<=0; read_ptr<=0;
            cptr0<=0;cptr1<=0;cptr2<=0;cptr3<=0;aptr0<=0;aptr1<=0;
            cfill0<=0;cfill1<=0;cfill2<=0;cfill3<=0;afill0<=0;afill1<=0;
            mono<=0; comb_average<=0; aout0<=0; aout1<=0;
        end else begin
            if(out_valid && out_ready) out_valid<=0;
            if(accept) begin
                if(change) begin
                    active_mode<=mode;
                    ptr<=0;filled<=0;phase<=0;
                    cptr0<=0;cptr1<=0;cptr2<=0;cptr3<=0;aptr0<=0;aptr1<=0;
                    cfill0<=0;cfill1<=0;cfill2<=0;cfill3<=0;afill0<=0;afill1<=0;
                    out_valid<=1; out_left<=in_left; out_right<=in_right;
                end else if(mode==0) begin
                    out_valid<=1; out_left<=in_left; out_right<=in_right;
                end else begin
                    dry_l<=in_left; dry_r<=in_right; mono<=stereo_sum>>>9;
                    lag_valid<=filled>=lag; read_ptr<=raddr; state<=1;
                end
            end
            if(state==1) begin
                if(active_mode==2) begin
                    comb_average<=sat16((t0+t1+t2+t3)>>>2); state<=2;
                    cptr0<=(cptr0==COMB0-1)?0:cptr0+1'b1;
                    cptr1<=(cptr1==COMB1-1)?0:cptr1+1'b1;
                    cptr2<=(cptr2==COMB2-1)?0:cptr2+1'b1;
                    cptr3<=(cptr3==COMB3-1)?0:cptr3+1'b1;
                    if(cfill0<COMB0)cfill0<=cfill0+1'b1;
                    if(cfill1<COMB1)cfill1<=cfill1+1'b1;
                    if(cfill2<COMB2)cfill2<=cfill2+1'b1;
                    if(cfill3<COMB3)cfill3<=cfill3+1'b1;
                end else begin
                    out_left<=sat24(dl+(el>>>1)); out_right<=sat24(dr+(er>>>1));
                    out_valid<=1; state<=0; ptr<=ptr+1'b1;
                    if(filled<HIST_SIZE)filled<=filled+1'b1;
                    if(active_mode==3)phase<=phase+16'd2;
                end
            end
            if(state==2) begin aout0<=av0-(cav>>>1);aout1<=av1-(cav>>>1);state<=3;end
            if(state==3) begin
                out_left<=sat24(dl+($signed({{12{aout0[19]}},aout0})<<<7));
                out_right<=sat24(dr+($signed({{12{aout1[19]}},aout1})<<<7));
                out_valid<=1;state<=0;
                aptr0<=(aptr0==AP0-1)?0:aptr0+1'b1;
                aptr1<=(aptr1==AP1-1)?0:aptr1+1'b1;
                if(afill0<AP0)afill0<=afill0+1'b1;
                if(afill1<AP1)afill1<=afill1+1'b1;
            end
        end
    end
endmodule
