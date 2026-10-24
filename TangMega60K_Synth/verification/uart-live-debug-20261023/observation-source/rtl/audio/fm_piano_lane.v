// One time-shared two-operator FM pipeline for 64 independent voices.
// Each voice keeps its OWN modulator and carrier DDS phase. The single sine
// ROM is read on two different clocks. No sample recording or PCM loop exists.
module fm_piano_lane #(
    parameter ROM_DIR="rtl/audio/rom/"
) (
    input wire clk,rst_n,start,
    input wire [5:0] voice,
    // Context is available one clock after start (voice_engine state RAM).
    input wire active,
    input wire [19:0] age,
    input wire [6:0] velocity,
    // Effective FTW is stable three clocks after start.
    input wire [31:0] fundamental_ftw,
    output wire valid,
    output wire signed [15:0] sample
);
    reg [63:0] phase_ram[0:63]; // {modulator phase, carrier phase}
    reg signed [15:0] sine[0:1023];
    initial $readmemh({ROM_DIR,"sine.hex"},sine);

    reg [7:0] pipe_valid;
    reg [63:0] read_phase;
    reg [5:0] voice0,voice1,voice2;
    reg active1,active2;
    reg [19:0] age1,age2;
    reg [6:0] velocity1,velocity2;
    reg [31:0] mod_phase1,car_phase1;
    reg [31:0] mod_phase2,car_phase2,next_mod2,next_car2;
    reg [9:0] mod_addr2,car_addr5;
    reg signed [15:0] mod_wave3,car_wave6;
    reg [15:0] index3;
    reg signed [31:0] modulation4;
    reg active3,active4,active5,active6;
    reg [31:0] car_phase3,car_phase4;

    // Q2.14 *cycles*, not radians: soft touch about 0.73 rad, hard touch
    // about 1.23 rad. The 1/(2*pi) conversion is baked into these constants
    // offline, so no divider/multiplier is needed at sample time.
    // Velocity changes at a retrigger only; no change to the public V2 ports.
    wire [15:0] initial_index=16'd1304+{velocity2,4'd0}-velocity2;
    wire [19:0] index_drop=age2>>4;
    wire [15:0] shaped_index=(age2>=20'd65536 ||
        index_drop+20'd652>=initial_index) ? 16'd652 :
        initial_index-index_drop[15:0];
    // sin is Q1.15, index is cycles in Q2.14; product << 3 is phase32.
    wire [31:0] offset_phase=modulation4<<<3;
    wire [31:0] fm_angle=car_phase4+offset_phase;
    assign valid=pipe_valid[6];
    assign sample=active6 ? car_wave6 : 16'sd0;

    // The FM operator uses one sine ROM twice on successive clocks.
    // A second external sine table or CORDIC is not required.
    always @(posedge clk) begin
        if(start) begin read_phase<=phase_ram[voice]; voice0<=voice; end
        if(pipe_valid[0]) begin
            mod_phase1<=age==0 ? 32'h40000000 : read_phase[63:32];
            car_phase1<=age==0 ? 32'd0 : read_phase[31:0];
            active1<=active; age1<=age; velocity1<=velocity;
            voice1<=voice0;
        end
        if(pipe_valid[1]) begin
            mod_phase2<=mod_phase1; car_phase2<=car_phase1;
            mod_addr2<=mod_phase1[31:22];
            active2<=active1; age2<=age1; velocity2<=velocity1;
            voice2<=voice1;
        end
        if(pipe_valid[2]) begin
            mod_wave3<=sine[mod_addr2];
            // 3:1 gives strong 2nd/4th and smaller higher harmonics using
            // one modulator; it was chosen against the reference attack's
            // above-2-kHz and above-4-kHz energy, not by peak loudness.
            next_mod2<=mod_phase2+(fundamental_ftw<<1)+fundamental_ftw;
            next_car2<=car_phase2+fundamental_ftw;
            phase_ram[voice2]<=active2 ?
                {mod_phase2+(fundamental_ftw<<1)+fundamental_ftw,
                 car_phase2+fundamental_ftw} : 64'd0;
            index3<=shaped_index; car_phase3<=car_phase2; active3<=active2;
        end
        if(pipe_valid[3]) begin
            modulation4<=mod_wave3*$signed({1'b0,index3});
            car_phase4<=car_phase3; active4<=active3;
        end
        if(pipe_valid[4]) begin
            car_addr5<=fm_angle[31:22]; active5<=active4;
        end
        if(pipe_valid[5]) begin
            car_wave6<=sine[car_addr5]; active6<=active5;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            pipe_valid<=0;
        end else begin
            pipe_valid<={pipe_valid[6:0],start};
        end
    end
endmodule
