`timescale 1ns/1ps
// Default hardware divisors. Report exact RTL cycles; ms uses CLK_HZ, not a
// claim about sensor analog filtering or a measured physical touch-to-sound.
module tb_mpr121_timing;
    reg clk=0;always #10.172526 clk=~clk;
    reg resetn=0,cmd_valid=0,cmd_read=1;
    reg [6:0] cmd_addr=7'h5a;reg [7:0] cmd_reg=0,cmd_wdata=0;
    reg [5:0] cmd_len=43;
    wire cmd_ready,busy,done,rdata_valid;wire [2:0] error;
    wire [7:0] rdata;wire [5:0] rindex;tri1 scl,sda;
    i2c_register_master dut(.*);
    mpr121_bus_model model(clk,scl,sda,2'd0,1'b0,1'b0,1'b0);
    integer cycles=0,bytes=0,ticks=0,start_tick;
    always @(posedge clk) begin
      ticks=ticks+1;if(rdata_valid)bytes=bytes+1;
    end
    initial begin
      repeat(5)@(negedge clk);resetn=1;
      @(negedge clk);cmd_valid=1;
      @(posedge clk);start_tick=ticks;
      @(negedge clk);cmd_valid=0;
      while(!done && ticks-start_tick<60000) @(negedge clk);
      cycles=ticks-start_tick;
      if(!done || error!=0 || bytes!=43 || cycles>54000) $fatal(1,"default timing transaction failed");
      $display("PASS tb_mpr121_timing: 49.152MHz defaults, 43-byte transaction=%0d cycles = %0.6f ms, LOW_T=%0d HIGH_T=%0d",cycles,cycles*1000.0/49152000,dut.LOW_T,dut.HIGH_T);$finish;
    end
    initial begin #2000000;$fatal(1,"default timing watchdog");end
endmodule
