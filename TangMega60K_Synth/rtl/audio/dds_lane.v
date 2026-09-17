// Phase is unsigned modulo 2^32. The scheduler commits it ONCE per sample.
module dds_lane (
    input wire [31:0] phase,
    input wire [31:0] ftw,
    input wire [1:0] timbre,
    output wire [31:0] next_phase,
    output wire [11:0] wave_addr
);
    // Harmonics stay below 0.45 Fs. 0/2=sine, 1/3=organ with band selection.
    wire [1:0] bank = !timbre[0] ? 2'd0 :
        (ftw < 32'h26666666) ? 2'd1 :
        (ftw < 32'h39999999) ? 2'd2 : 2'd0;
    assign next_phase = phase + ftw;
    assign wave_addr = {bank, phase[31:22]};
endmodule
