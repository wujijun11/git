// GW5AT-60B PLLA audio clock for the board's 50 MHz oscillator.
// PLL0: 50 * 24 / 31.25 = 38.4 MHz (VCO = 1200 MHz).
// PLL1: 38.4 * 32 / 25 = 49.152 MHz (VCO = 1228.8 MHz).
// The existing 1024-clock I2S frame is therefore exactly 48 kHz nominal.
// pll_init.v is the Gowin V1.9.12 PLL_ADV/PLLA initialization source.
module audio_clock_48k (
    input wire clk_50,
    output wire clk_audio,
    output wire locked
);
    wire clk_38m4;
    wire lock_38m4;
    wire lock_49m152;
    reg [16:0] first_lock_count = 0;
    reg first_lock_stable = 0;
    reg [16:0] second_lock_count = 0;
    reg second_lock_stable = 0;

    // Gowin advises observing LOCK continuously for at least 2 ms.
    // Both counters run from the independent 50 MHz reference (100000 cycles).
    always @(posedge clk_50) begin
        if (!lock_38m4) begin
            first_lock_count <= 0;
            first_lock_stable <= 0;
        end else if (!first_lock_stable) begin
            if (first_lock_count == 17'd99999)
                first_lock_stable <= 1;
            else
                first_lock_count <= first_lock_count + 1'b1;
        end

        if (!first_lock_stable || !lock_49m152) begin
            second_lock_count <= 0;
            second_lock_stable <= 0;
        end else if (!second_lock_stable) begin
            if (second_lock_count == 17'd99999)
                second_lock_stable <= 1;
            else
                second_lock_count <= second_lock_count + 1'b1;
        end
    end

    assign locked = second_lock_stable && lock_49m152 && first_lock_stable && lock_38m4;

    audio_plla_stage #(
        .INPUT_MHZ("50"), .MDIV(24), .ODIV(31), .ODIV_FRAC(2)
    ) pll_38m4 (
        .clkin(clk_50), .mdclk(clk_50), .reset(1'b0),
        .clkout(clk_38m4), .locked(lock_38m4)
    );

    audio_plla_stage #(
        .INPUT_MHZ("38.4"), .MDIV(32), .ODIV(25), .ODIV_FRAC(0)
    ) pll_49m152 (
        .clkin(clk_38m4), .mdclk(clk_50), .reset(!first_lock_stable),
        .clkout(clk_audio), .locked(lock_49m152)
    );
endmodule

module audio_plla_stage #(
    parameter INPUT_MHZ = "50",
    parameter integer MDIV = 24,
    parameter integer ODIV = 15,
    parameter integer ODIV_FRAC = 0
) (
    input wire clkin,
    input wire mdclk,
    input wire reset,
    output wire clkout,
    output wire locked
);
    wire primitive_lock;
    wire primitive_reset;
    wire [7:0] md_read;
    wire [7:0] md_write;
    wire [1:0] md_op;
    wire md_inc;

    // The shipped PLLA simulation model does not implement MDRDO, which the
    // vendor PLL_INIT simulation needs. Simulate the PLL divider and raw LOCK;
    // synthesize the complete Gowin initialization sequence for hardware.
`ifdef SIM
    assign primitive_reset = reset;
    assign md_inc = 1'b0;
    assign md_op = 2'b00;
    assign md_write = 8'b0;
    assign locked = primitive_lock;
`else
    // Both MDCLK inputs are the 50 MHz board oscillator, hence CLK_PERIOD=20.
    PLL_INIT #(.CLK_PERIOD(20), .MULTI_FAC(MDIV)) init (
        .I_RST(reset), .I_MD_CLK(mdclk), .O_RST(primitive_reset),
        .I_LOCK(primitive_lock), .O_LOCK(locked),
        .O_MD_INC(md_inc), .O_MD_OPC(md_op),
        .O_MD_WR_DATA(md_write), .I_MD_RD_DATA(md_read),
        .PLL_INIT_BYPASS(1'b0), .MDRDO(),
        .MDOPC(2'b00), .MDAINC(1'b0), .MDWDI(8'b0)
    );
`endif

    PLLA #(
        .FCLKIN(INPUT_MHZ),
        .IDIV_SEL(1), .FBDIV_SEL(1),
        .MDIV_SEL(MDIV), .MDIV_FRAC_SEL(0),
        .ODIV0_SEL(ODIV), .ODIV0_FRAC_SEL(ODIV_FRAC),
        .CLKOUT0_EN("TRUE"), .CLKFB_SEL("INTERNAL")
    ) pll (
        .CLKIN(clkin), .CLKFB(1'b0), .CLKOUT0(clkout),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(),
        .CLKOUT5(), .CLKOUT6(), .CLKFBOUT(),
        .LOCK(primitive_lock), .RESET(primitive_reset),
        .PLLPWD(1'b0), .RESET_I(1'b0), .RESET_O(1'b0),
        .PSSEL(3'b0), .PSDIR(1'b0), .PSPULSE(1'b0),
        .SSCPOL(1'b0), .SSCON(1'b0), .SSCMDSEL(7'b0),
        .SSCMDSEL_FRAC(3'b0),
        .MDCLK(mdclk), .MDOPC(md_op), .MDAINC(md_inc),
        .MDWDI(md_write), .MDRDO(md_read)
    );
endmodule
