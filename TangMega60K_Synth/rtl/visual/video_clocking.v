`timescale 1ns/1ps
// GW5AT-60B: 50MHz *20 => 1000MHz VCO; /8 =>125MHz, /40=>25MHz.
// Synthesis includes the repository's Gowin PLL_INIT initialization source.
// Primary board reference: sipeed/TangMega-60K-example/main/cam_dvi/src/
// gowin_pll/TMDS_PLL_800_600_60.v (PLLA ports and dual output arrangement).
module video_clocking #(
    parameter integer LOCK_STABLE_CYCLES=100000
)(
    input wire clk_50,reset,
    output wire clk_pixel,clk_serial,locked
);
    wire raw_lock,init_lock,primitive_reset;
    wire [7:0] md_read,md_write;
    wire [1:0] md_op;
    wire md_inc;
    reg [31:0] stable_count=0;
    reg stable=0;
    always @(posedge clk_50 or posedge reset)begin
        if(reset)begin stable_count<=0;stable<=0;end
        else if(!init_lock)begin stable_count<=0;stable<=0;end
        else if(!stable)begin
            if(stable_count==LOCK_STABLE_CYCLES-1)stable<=1;
            else stable_count<=stable_count+1'b1;
        end
    end
    assign locked=stable&&init_lock&&!reset;
`ifdef SIM
    // The vendor simulation PLLA does not implement the initialization MDRDO
    // interface. Only simulation bypasses PLL_INIT, as for audio_clock_48k.
    assign primitive_reset=reset;assign md_write=0;assign md_op=0;assign md_inc=0;assign init_lock=raw_lock;
`else
    PLL_INIT #(.CLK_PERIOD(20),.MULTI_FAC(20)) init(
        .I_RST(reset),.I_MD_CLK(clk_50),.O_RST(primitive_reset),.I_LOCK(raw_lock),.O_LOCK(init_lock),
        .O_MD_INC(md_inc),.O_MD_OPC(md_op),.O_MD_WR_DATA(md_write),.I_MD_RD_DATA(md_read),
        .PLL_INIT_BYPASS(1'b0),.MDRDO(),.MDOPC(2'b00),.MDAINC(1'b0),.MDWDI(8'b0));
`endif
    PLLA #(.FCLKIN("50"),.IDIV_SEL(1),.FBDIV_SEL(1),.MDIV_SEL(20),.MDIV_FRAC_SEL(0),
        .ODIV0_SEL(8),.ODIV0_FRAC_SEL(0),.ODIV1_SEL(40),.CLKOUT0_EN("TRUE"),
        .CLKOUT1_EN("TRUE"),.CLKFB_SEL("INTERNAL")) pll(
        .CLKIN(clk_50),.CLKFB(1'b0),.CLKOUT0(clk_serial),.CLKOUT1(clk_pixel),
        .CLKOUT2(),.CLKOUT3(),.CLKOUT4(),.CLKOUT5(),.CLKOUT6(),.CLKFBOUT(),
        .LOCK(raw_lock),.RESET(primitive_reset),.PLLPWD(1'b0),.RESET_I(1'b0),.RESET_O(1'b0),
        .PSSEL(3'b0),.PSDIR(1'b0),.PSPULSE(1'b0),.SSCPOL(1'b0),.SSCON(1'b0),
        .SSCMDSEL(7'b0),.SSCMDSEL_FRAC(3'b0),.MDCLK(clk_50),.MDOPC(md_op),.MDAINC(md_inc),
        .MDWDI(md_write),.MDRDO(md_read));
endmodule
