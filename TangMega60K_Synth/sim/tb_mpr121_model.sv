`timescale 1ns/1ps
// Bus-level MPR121 model: real serial address/pointer/data bytes and ACK ownership.
module mpr121_bus_model(input wire clk,inout wire scl,sda,
    input wire [1:0] nack_phase,input wire mismatch,hold_scl,hold_sda);
    reg drive_sda=0;
    assign sda=(drive_sda || hold_sda)?1'b0:1'bz;
    assign scl=hold_scl?1'b0:1'bz;
    reg [7:0] mem[0:255],frozen[0:42];
    integer starts=0,stops=0,writes=0,reads=0,master_nacks=0;
    integer state=4,phase=0,bits=0,txbit=7;
    reg [7:0] shift=0,ptr=0,tx=0;
    reg ack_start=0,ack_ok=0,reading=0,master_ack=0;
    integer i;
    task defaults;
      begin
        for(i=43;i<256;i=i+1) mem[i]=0;
        mem[8'h5c]=8'h10;mem[8'h5d]=8'h24;
      end
    endtask
    task set_touches(input [11:0] value);
      begin mem[0]=value[7:0];mem[1]={4'b0,value[11:8]};end
    endtask
    task set_delta(input integer electrode,input integer value);
      integer data;
      begin
        data=512-value;
        mem[4+2*electrode]=data & 255;mem[5+2*electrode]=(data>>8)&3;
        mem[30+electrode]=128;
      end
    endtask
    function [7:0] read_byte(input [7:0] address);
      begin
        if(mismatch && address==8'h5c) read_byte=8'h11;
        else if(address<=42) read_byte=frozen[address];
        else read_byte=mem[address];
      end
    endfunction
    initial begin
      for(i=0;i<256;i=i+1) mem[i]=0;
      defaults();for(i=0;i<13;i=i+1) set_delta(i,0);
    end
    always @(negedge sda) if(scl===1'b1 && !hold_sda) begin
      starts=starts+1;state=0;phase=0;bits=0;shift=0;ack_start=0;drive_sda=0;
    end
    always @(posedge sda) if(scl===1'b1) begin
      stops=stops+1;state=4;drive_sda=0;
    end
    always @(posedge scl) begin
      case(state)
      0: begin
        shift={shift[6:0],sda};bits=bits+1;
        if(bits==8) begin
          bits=0;state=1;ack_start=0;
          case(phase)
          0:begin
            ack_ok=(shift[7:1]==7'h5a && nack_phase!=1);reading=shift[0];
            if(reading && ack_ok) for(i=0;i<43;i=i+1) frozen[i]=mem[i];
          end
          1:begin ptr=shift;ack_ok=(nack_phase!=2);end
          2:begin
            ack_ok=(nack_phase!=3);
            if(ack_ok) begin
              if(ptr==8'h80 && shift==8'h63) defaults();else mem[ptr]=shift;
              writes=writes+1;ptr=ptr+1;
            end
          end
          endcase
        end
      end
      2: begin
        if(txbit==0) begin state=3;ack_start=0;reads=reads+1;end
        else txbit=txbit-1;
      end
      3:begin master_ack=(sda===1'b0);if(!master_ack) master_nacks=master_nacks+1;end
      endcase
    end
    always @(negedge scl) begin
      case(state)
      1:if(!ack_start) begin drive_sda=ack_ok;ack_start=1;end
        else begin
          drive_sda=0;
          if(!ack_ok) state=4;
          else if(phase==0 && reading) begin
            state=2;txbit=7;tx=read_byte(ptr);drive_sda=~tx[7];
          end else begin
            state=0;bits=0;shift=0;if(phase<2) phase=phase+1;
          end
        end
      2:drive_sda=~tx[txbit];
      3:if(!ack_start) begin drive_sda=0;ack_start=1;end
        else begin
          if(master_ack) begin ptr=ptr+1;tx=read_byte(ptr);txbit=7;state=2;drive_sda=~tx[7];end
          else begin state=4;drive_sda=0;end
        end
      endcase
    end
endmodule
