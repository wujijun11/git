`timescale 1ns/1ps
module tb_mpr121_i2c;
    reg clk=0;always #5 clk=~clk;
    reg resetn=0,cmd_valid=0,cmd_read=0;
    reg [6:0] cmd_addr=7'h5a;reg [7:0] cmd_reg=0,cmd_wdata=0;
    reg [5:0] cmd_len=1;
    wire cmd_ready,busy,done,rdata_valid;wire [2:0] error;
    wire [7:0] rdata;wire [5:0] rindex;
    tri1 scl,sda;reg [1:0] nack=0;reg mismatch=0,hold_scl=0,hold_sda=0;
    i2c_register_master #(.CLK_HZ(4000000),.I2C_HZ(400000),.TIMEOUT_CYCLES(10000)) dut(.*);
    mpr121_bus_model model(clk,scl,sda,nack,mismatch,hold_scl,hold_sda);
    integer bytes=0;reg [7:0] received[0:42];
    always @(posedge clk) if(rdata_valid) begin
      received[rindex]=rdata;bytes=bytes+1;
    end
    task request(input bit rd,input [7:0] address,input [7:0] value,input [5:0] length,input [2:0] expected);
      integer t;
      begin
        @(negedge clk);cmd_read=rd;cmd_reg=address;cmd_wdata=value;cmd_len=length;cmd_valid=1;
        @(negedge clk);cmd_valid=0;t=0;
        while(!done && t<11000) begin @(negedge clk);t=t+1;end
        if(!done || error!==expected) $fatal(1,"transaction error wanted %0d got %0d state %0d",expected,error,dut.state);
        @(negedge clk);
      end
    endtask
    initial begin
      repeat(5) @(negedge clk);resetn=1;
      request(0,8'h5c,8'h21,1,0);
      if(model.mem[8'h5c]!=8'h21) $fatal(1,"write failed");
      request(1,8'h5c,0,1,0);
      if(received[0]!=8'h21) $fatal(1,"readback failed %h",received[0]);
      model.set_touches(12'h805);model.set_delta(8,90);bytes=0;
      fork
        request(1,0,0,43,0);
        begin wait(rdata_valid && rindex==7);model.set_touches(0);model.set_delta(8,0);end
      join
      if(bytes!=43 || received[0]!=5 || received[1]!=8 || received[20]!=8'ha6 || received[21]!=1)
        $fatal(1,"coherent 43-byte read failed bytes=%0d d0=%h d1=%h d20=%h d21=%h",bytes,received[0],received[1],received[20],received[21]);
      if(model.master_nacks!=2) $fatal(1,"last-byte NACK was not generated");
      nack=1;request(0,8'h5c,8'h33,1,1);
      nack=2;request(0,8'h5c,8'h33,1,1);
      nack=3;request(0,8'h5c,8'h33,1,1);
      if(model.mem[8'h5c]!=8'h21) $fatal(1,"NACK write mutated register");
      nack=0;
      fork
        request(1,8'h5c,0,1,0);
        begin wait(dut.state==3);hold_scl=1;repeat(20) @(negedge clk);hold_scl=0;end
      join
      fork
        request(1,8'h5c,0,1,2);
        begin wait(dut.state==3);hold_scl=1;repeat(10100) @(negedge clk);hold_scl=0;end
      join
      // Stuck-busy bus has a distinct diagnostic and does not spin forever.
      hold_sda=1;request(0,8'h5c,0,1,3);hold_sda=0;
      repeat(5) @(negedge clk);request(1,8'h5c,0,1,0);
      $display("PASS tb_mpr121_i2c: write/read, 43 bytes, final NACK, address/register/data NACK, stretch and bounded timeout");$finish;
    end
    initial begin #5000000;$fatal(1,"watchdog");end
endmodule
