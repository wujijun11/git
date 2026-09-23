// Four independent partials per voice, time-multiplexed through ONE lane.
// Two lanes (even/odd partials) together process 64*8 oscillator states.
// Four note regions share the SAME 512x260 parameter ROM per lane.
// No recorded PCM: ROM holds segment boundaries, amplitude/phase and slopes.
// State is private per {voice,pair}; sine and arithmetic pipeline are shared.
module polar_lane #(
    parameter LANE=0,
    parameter ROM_DIR="rtl/audio/rom/"
) (
    input wire clk,rst_n,start,
    input wire [5:0] voice,
    // Context becomes valid one clock after start (engine synchronous state RAM).
    input wire active,
    input wire [19:0] age,
    // Frequency becomes valid three clocks after start and stays through issue.
    input wire [31:0] fundamental_ftw,
    // Unbent note FTW, valid with active/age one clock after start. Region
    // selection is latched in each partial's existing pointer at age zero.
    input wire [31:0] base_ftw,
    output reg valid,
    output reg signed [31:0] left,right
);
    reg [194:0] states[0:255];
    reg [259:0] params[0:511];
    reg [26:0] ratios[0:31];
    reg signed [15:0] sine[0:1023];
    initial begin
        if(LANE==0) $readmemh({ROM_DIR,"polar_lane0.hex"},params);
        else $readmemh({ROM_DIR,"polar_lane1.hex"},params);
        $readmemh({ROM_DIR,"polar_ratios.hex"},ratios);
        $readmemh({ROM_DIR,"sine.hex"},sine);
    end
    reg issuing;
    reg [1:0] issue_pair;
    reg [5:0] issue_voice;
    wire issue=start || issuing;
    wire [1:0] pair_now=start ? 2'd0 : issue_pair;
    wire [7:0] address_now={start ? voice : issue_voice,pair_now};
    reg [6:0] v;
    reg [194:0] s0,s1;
    reg [7:0] addr0,addr1,addr2,addr3;
    reg [1:0] pair0,pair1,pair2,pair3,pair4,pair5,pair6;
    reg boundary1;
    reg [6:0] ptr1,ptr2,ptr3;
    reg [259:0] record1;
    wire boundary0=(age==0) || (s0[194:175]!=20'hfffff && age>=s0[194:175]);
    wire [1:0] note_region=base_ftw<32'd31248413 ? 2'd0 :
                           base_ftw<32'd44191930 ? 2'd1 :
                           base_ftw<32'd66213081 ? 2'd2 : 2'd3;
    // pointer[6:5]=region; pointer[4:0]=segment. Terminal zero segment has
    // end=20'hfffff, so it never wraps into another region.
    wire [6:0] next_ptr=(age==0) ? {note_region,5'd0} :
        boundary0 ? {s0[174:173],s0[172:168]+5'd1} : s0[174:168];
    // ROM packing, MSB first: end20, aL28, daL28, thetaL32, dthetaL32,
    // aR28, daR28, thetaR32, dthetaR32. a is Q1.27; da is Q1.35.
    wire [19:0] rec_end=record1[259:240];
    wire [27:0] rec_aL=record1[239:212], rec_daL=record1[211:184];
    wire [31:0] rec_tL=record1[183:152], rec_dtL=record1[151:120];
    wire [27:0] rec_aR=record1[119:92], rec_daR=record1[91:64];
    wire [31:0] rec_tR=record1[63:32], rec_dtR=record1[31:0];
    reg [35:0] aL2,aR2,aL3,aR3;
    reg [31:0] tL2,tR2,tL3,tR3,phase2,phase3;
    reg [19:0] end2,end3;
    reg [26:0] ratio2;
    reg enabled2,enabled3;
    reg [58:0] frequency3;
    wire [58:0] rounded_frequency=(frequency3+59'd2097152)>>22;
    wire audible3=enabled3 && rounded_frequency<59'h73333333;
    wire [31:0] phase_after=phase3+rounded_frequency[31:0];
    wire [31:0] angleL=phase3+tL3+32'h40000000;
    wire [31:0] angleR=phase3+tR3+32'h40000000;
    reg [9:0] addressL4,addressR4;
    reg [27:0] ampL4,ampR4,ampL5,ampR5;
    reg signed [15:0] waveL5,waveR5;
    reg signed [44:0] productL6,productR6;
    wire signed [44:0] sampleL=(productL6+45'sd67108864)>>>27;
    wire signed [44:0] sampleR=(productR6+45'sd67108864)>>>27;
    // Amp clamp is below 1.0 and sine is signed 16-bit: each result fits
    // signed 16 bits, and four-partial accumulation fits signed 18 bits.
    wire signed [31:0] sampleL32=sampleL[31:0],sampleR32=sampleR[31:0];
    reg signed [31:0] sumL,sumR;
    function [35:0] next_amp;
        input [35:0] old;
        input [27:0] delta;
        reg signed [36:0] value;
        begin
            value=$signed({1'b0,old})+$signed({{9{delta[27]}},delta});
            if(value<0) next_amp=0;
            else if(value>37'h7ffffffff) next_amp=36'h7ffffffff;
            else next_amp=value[35:0];
        end
    endfunction
    // RAM/ROM datapath has no bulk reset, allowing block RAM inference.
    // age==0 selects initialized parameter state, never old/uninitialized RAM.
    always @(posedge clk) begin
        if(issue) begin s0<=states[address_now]; addr0<=address_now; pair0<=pair_now; end
        if(v[0]) begin
            record1<=params[{pair0,next_ptr}]; s1<=s0;
            addr1<=addr0; pair1<=pair0; boundary1<=boundary0; ptr1<=next_ptr;
        end
        if(v[1]) begin
            aL2<=!active ? 36'd0 : boundary1 ? {rec_aL,8'd0} : next_amp(s1[167:132],rec_daL);
            aR2<=!active ? 36'd0 : boundary1 ? {rec_aR,8'd0} : next_amp(s1[131:96],rec_daR);
            tL2<=boundary1 ? rec_tL : s1[95:64]+rec_dtL;
            tR2<=boundary1 ? rec_tR : s1[63:32]+rec_dtR;
            phase2<=age==0 || !active ? 32'd0 : s1[31:0];
            ptr2<=ptr1; end2<=rec_end; addr2<=addr1; pair2<=pair1;
            ratio2<=ratios[{ptr1[6:5],pair1,1'b0}+LANE]; enabled2<=active;
        end
        if(v[2]) begin
            frequency3<=fundamental_ftw*ratio2;
            aL3<=aL2; aR3<=aR2; tL3<=tL2; tR3<=tR2; phase3<=phase2;
            ptr3<=ptr2; end3<=end2; addr3<=addr2; pair3<=pair2; enabled3<=enabled2;
        end
        if(v[3]) begin
            states[addr3]<={end3,ptr3,aL3,aR3,tL3,tR3,enabled3 ? phase_after : 32'd0};
            addressL4<=angleL[31:22]; addressR4<=angleR[31:22];
            ampL4<=audible3 ? aL3[35:8] : 28'd0;
            ampR4<=audible3 ? aR3[35:8] : 28'd0; pair4<=pair3;
        end
        if(v[4]) begin
            waveL5<=sine[addressL4]; waveR5<=sine[addressR4];
            ampL5<=ampL4; ampR5<=ampR4; pair5<=pair4;
        end
        if(v[5]) begin
            productL6<=waveL5*$signed({1'b0,ampL5});
            productR6<=waveR5*$signed({1'b0,ampR5}); pair6<=pair5;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            issuing<=0; issue_pair<=0; issue_voice<=0; v<=0;
            valid<=0; left<=0; right<=0; sumL<=0; sumR<=0;
        end else begin
            v<={v[5:0],issue}; valid<=0;
            if(start) begin issuing<=1; issue_pair<=1; issue_voice<=voice; end
            else if(issuing) begin
                if(issue_pair==3) issuing<=0;
                else issue_pair<=issue_pair+1'b1;
            end
            if(v[6]) begin
                if(pair6==0) begin sumL<=sampleL32; sumR<=sampleR32; end
                else begin sumL<=sumL+sampleL32; sumR<=sumR+sampleR32; end
                if(pair6==3) begin
                    left<=sumL+sampleL32; right<=sumR+sampleR32; valid<=1;
                end
            end
        end
    end
endmodule
