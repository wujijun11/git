// Diagnostic DDS triangle oscillator, not the team's final synthesis engine.
// phase_step = round(frequency_hz * 2^32 / sample_rate_hz).
// Defaults: A4=440 Hz at 48 kHz. Phase advances ONLY on accepted samples.
module test_tone_source #(
    parameter [31:0] LEFT_STEP = 32'd39370534,
    parameter [31:0] RIGHT_STEP = 32'd39370534
) (
    input wire clk,
    input wire rst_n,
    output wire sample_valid,
    input wire sample_ready,
    output wire signed [23:0] sample_left,
    output wire signed [23:0] sample_right
);
    reg [31:0] phase_left, phase_right;
    function signed [23:0] triangle;
        input [31:0] phase;
        reg [22:0] folded;
        reg signed [23:0] centered;
        begin
            folded = phase[31] ? ~phase[30:8] : phase[30:8];
            centered = $signed({1'b0, folded}) - 24'sd4194304;
            // About -18 dBFS peak; avoid unexpectedly loud preview audio.
            triangle = centered >>> 2;
        end
    endfunction
    assign sample_valid = rst_n;
    assign sample_left = triangle(phase_left);
    assign sample_right = triangle(phase_right);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase_left <= 0;
            phase_right <= 0;
        end else if (sample_valid && sample_ready) begin
            phase_left <= phase_left + LEFT_STEP;
            phase_right <= phase_right + RIGHT_STEP;
        end
    end
endmodule
