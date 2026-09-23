// Linear envelope, internal 24-bit UQ1.23; unity=0x800000.
// RELEASE uses a full-scale slope: early release ends proportionally sooner.
module adsr #(
    parameter SAMPLE_RATE=48000,
    parameter ATTACK_MS=10,
    parameter DECAY_MS=80,
    parameter RELEASE_MS=100,
    parameter FM_ENABLE=0
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
    localparam PN=(SAMPLE_RATE*2/1000 > 0) ? SAMPLE_RATE*2/1000 : 1;
    localparam [23:0] P_ATTACK=(8388608+PN-1)/PN;
    localparam [23:0] FM_SUSTAIN=24'h180000;
    localparam [23:0] FM_DECAY=(8388608-FM_SUSTAIN+(SAMPLE_RATE*600/1000)-1)/(SAMPLE_RATE*600/1000);
    // Natural partial decay comes from the polar control envelopes. This
    // additional gate provides live attack/release and smooth held retrigger.
    assign finished=active && stage==RELEASE && next_level==0;
    always @(*) begin
        next_stage=stage;
        next_level=level;
        if (!active) begin next_stage=IDLE; next_level=0; end
        else if(FM_ENABLE && timbre==3) begin
            case(stage)
                ATTACK: if(level>=24'h800000-P_ATTACK) begin
                    next_level=24'h800000; next_stage=DECAY;
                end else next_level=level+P_ATTACK;
                DECAY: if(level<=FM_SUSTAIN+FM_DECAY) begin
                    next_level=FM_SUSTAIN; next_stage=SUSTAIN;
                end else next_level=level-FM_DECAY;
                SUSTAIN: next_level=FM_SUSTAIN;
                5: if(level<=P_ATTACK) begin next_level=0; next_stage=ATTACK; end
                    else next_level=level-P_ATTACK;
                RELEASE: if(level<=R_STEP) begin next_level=0; next_stage=IDLE; end
                    else next_level=level-R_STEP;
                default: begin next_level=0; next_stage=IDLE; end
            endcase
        end else if(timbre==2) begin
            case(stage)
                ATTACK: if(level >= 24'h800000-P_ATTACK) begin
                    next_level=24'h800000; next_stage=DECAY;
                end else next_level=level+P_ATTACK;
                DECAY,SUSTAIN: begin next_level=24'h800000; next_stage=SUSTAIN; end
                5: if(level<=P_ATTACK) begin next_level=0; next_stage=ATTACK; end
                    else next_level=level-P_ATTACK;
                RELEASE: if(level<=R_STEP) begin next_level=0; next_stage=IDLE; end
                    else next_level=level-R_STEP;
                default: begin next_level=0; next_stage=IDLE; end
            endcase
        end else case (stage)
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
