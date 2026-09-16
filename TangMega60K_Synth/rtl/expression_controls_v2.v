// One-entry ready/valid mailbox for a COHERENT GLOBAL expression bundle.
// No synthesis/ADSR/LFO in this module. The audio engine applies the parameters.
// engine_sample_begin is emitted by the engine BEFORE computing a new sample,
// not the I2S output frame tick (audio samples can be buffered).
module expression_controls_v2 (
    input wire clk,
    input wire rst_n,
    input wire expr_valid,
    output wire expr_ready,
    input wire [11:0] expr_gain,              // unsigned Q1.11: 2048 = unity
    input wire signed [12:0] expr_bend_cents, // clipped to -2400..2400
    input wire [7:0] expr_vibrato_cents,      // clipped to 0..100; depth, not rate
    input wire engine_sample_begin,
    output reg [11:0] active_gain,
    output reg signed [12:0] active_bend_cents,
    output reg [7:0] active_vibrato_cents,
    output reg expr_applied
);
    reg pending_valid;
    reg [11:0] pending_gain;
    reg signed [12:0] pending_bend;
    reg [7:0] pending_vibrato;
    wire accept = expr_valid && expr_ready;
    wire signed [12:0] safe_bend =
        ($signed(expr_bend_cents) > 13'sd2400) ? 13'sd2400 :
        ($signed(expr_bend_cents) < -13'sd2400) ? -13'sd2400 : expr_bend_cents;
    wire [7:0] safe_vibrato = (expr_vibrato_cents > 8'd100) ?
                              8'd100 : expr_vibrato_cents;
    // Can consume the old bundle and queue the next on the same edge.
    assign expr_ready = rst_n && (!pending_valid || engine_sample_begin);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending_valid <= 0;
            pending_gain <= 12'd2048;
            pending_bend <= 0;
            pending_vibrato <= 0;
            active_gain <= 12'd2048;
            active_bend_cents <= 0;
            active_vibrato_cents <= 0;
            expr_applied <= 0;
        end else begin
            expr_applied <= 0;
            if (engine_sample_begin) begin
                if (pending_valid) begin
                    active_gain <= pending_gain;
                    active_bend_cents <= pending_bend;
                    active_vibrato_cents <= pending_vibrato;
                    expr_applied <= 1;
                    pending_valid <= 0;
                end else if (accept) begin
                    // Empty-mailbox bypass: a new bundle applies this boundary.
                    active_gain <= expr_gain;
                    active_bend_cents <= safe_bend;
                    active_vibrato_cents <= safe_vibrato;
                    expr_applied <= 1;
                end
            end
            if (accept && (!engine_sample_begin || pending_valid)) begin
                pending_gain <= expr_gain;
                pending_bend <= safe_bend;
                pending_vibrato <= safe_vibrato;
                pending_valid <= 1;
            end
        end
    end
endmodule
