// Linear envelope, internal 24-bit UQ1.23; unity=0x800000.
// RELEASE uses a full-scale slope: early release ends proportionally sooner.
module adsr #(
    parameter SAMPLE_RATE=48000,
    parameter ATTACK_MS=10,
    parameter DECAY_MS=80,
    parameter RELEASE_MS=100
) (
    input wire active,
    input wire [1:0] timbre,
    input wire [2:0] stage,
    input wire [23:0] level,
    output reg [2:0] next_stage,
    output reg [23:0] next_level,
    output wire finished
);
    localparam IDLE=0, ATTACK=1, DECAY=2, SUSTAIN=3, RELEASE=4;
    localparam AN = (SAMPLE_RATE*ATTACK_MS/1000 > 0) ? SAMPLE_RATE*ATTACK_MS/1000 : 1;
    localparam DN = (SAMPLE_RATE*DECAY_MS/1000 > 0) ? SAMPLE_RATE*DECAY_MS/1000 : 1;
    localparam RN = (SAMPLE_RATE*RELEASE_MS/1000 > 0) ? SAMPLE_RATE*RELEASE_MS/1000 : 1;
    localparam [23:0] A_STEP=(8388608+AN-1)/AN;
    localparam [23:0] R_STEP=(8388608+RN-1)/RN;
    localparam [23:0] D_SINE=(2097152+DN-1)/DN;
    localparam [23:0] D_ORGAN=(4194304+DN-1)/DN;
    wire [23:0] sustain_level=timbre[0] ? 24'h400000 : 24'h600000;
    wire [23:0] decay_step=timbre[0] ? D_ORGAN : D_SINE;
    assign finished=active && stage==RELEASE && next_level==0;
    always @(*) begin
        next_stage=stage;
        next_level=level;
        if (!active) begin next_stage=IDLE; next_level=0; end
        else case (stage)
            ATTACK: if (level >= 24'h800000-A_STEP) begin
                next_level=24'h800000; next_stage=DECAY;
            end else next_level=level+A_STEP;
            DECAY: if (level <= sustain_level+decay_step) begin
                next_level=sustain_level; next_stage=SUSTAIN;
            end else next_level=level-decay_step;
            SUSTAIN: next_level=sustain_level;
            RELEASE: if (level <= R_STEP) begin
                next_level=0; next_stage=IDLE;
            end else next_level=level-R_STEP;
            default: begin next_level=0; next_stage=IDLE; end
        endcase
    end
endmodule
