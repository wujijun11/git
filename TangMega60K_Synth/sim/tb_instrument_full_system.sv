`timescale 1ns/1ps
module tb_instrument_full_system;
    reg clk=0;always #10.1725 clk=~clk;
    reg vclk=0;always #20 vclk=~vclk;
    reg rn=0,rx=1,local_v=0;reg [7:0] local_action=0;wire tx,local_ready;
    tri1 [2:0] scl,sda;wire bc,lr,sd,led;wire [6:0] voices;wire [31:0] underruns;
    wire playing,recording,guide,overflow,pcm_valid;wire signed [23:0] pl,pr;
    instrument_full_system #(.UART_BAUD(3072000))dut(.clk(clk),.rst_n(rn),.uart_rx(rx),.uart_tx(tx),
        .mpr_scl(scl),.mpr_sda(sda),.mpr_irq_n(3'b111),.local_action_valid(local_v),
        .local_action_ready(local_ready),.local_action(local_action),.i2s_bclk(bc),.i2s_lrclk(lr),.i2s_data(sd),
        .guide_led_data(led),.active_count(voices),.underrun_count(underruns),.overflow_sticky(overflow),
        .playing(playing),.recording(recording),.guide_active(guide),.video_clk(vclk),
        .video_x(10'd0),.video_y(10'd0),.video_de(1'b0),.monitor_left(pl),.monitor_right(pr),.monitor_valid(pcm_valid));
    wire [7:0] byte_rx;wire byte_valid,frame_error;
    remote_uart_rx #(.CLK_HZ(49152000),.BAUD(3072000))receiver(.clk(clk),.reset(!rn),.rx(tx),
        .data(byte_rx),.valid(byte_valid),.framing_error(frame_error));
    reg [7:0] bytes[0:15];integer byte_index=0,acks=0,data_packets=0;
    reg [7:0] ack_seq,ack_status;reg [79:0] data_payload;reg [7:0] data_opcode;
    function [7:0] crc(input [7:0] old,input [7:0] b);
        reg [7:0] q;begin q=old^b;for(integer k=0;k<8;k=k+1)q=q[7]?(q<<1)^7:q<<1;crc=q;end
    endfunction
    reg [7:0] check;reg [79:0] result;
    always @(posedge clk)if(rn)begin
        if(frame_error)$fatal(1,"response framing");
        if(byte_valid)begin
            bytes[byte_index]=byte_rx;
            if(byte_index==15)begin
                check=0;for(integer k=2;k<15;k=k+1)check=crc(check,bytes[k]);
                if(bytes[0]!=8'ha5 || bytes[1]!=8'h5a || check!=byte_rx)$fatal(1,"response packet CRC");
                result=0;for(integer k=0;k<10;k=k+1)result[k*8+:8]=bytes[k+5];
                if(bytes[4]==8'h80)begin acks=acks+1;ack_seq=bytes[3];ack_status=bytes[6];end
                else begin data_packets=data_packets+1;data_payload=result;data_opcode=bytes[4];end
                byte_index=0;
            end else byte_index=byte_index+1;
        end
    end
    task send_byte(input [7:0] b);
        begin rx=0;repeat(16)@(negedge clk);
            for(integer k=0;k<8;k=k+1)begin rx=b[k];repeat(16)@(negedge clk);end
            rx=1;repeat(16)@(negedge clk);end
    endtask
    reg [7:0] seq=0;
    task command(input [7:0] op,input [79:0] payload,input [7:0] status);
        integer before_count,t;reg [7:0] c;
        begin
            before_count=acks;c=crc(crc(crc(0,1),seq),op);
            @(negedge clk);send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(seq);send_byte(op);
            for(integer k=0;k<10;k=k+1)begin send_byte(payload[k*8+:8]);c=crc(c,payload[k*8+:8]);end
            send_byte(c);t=0;
            while(acks==before_count && t<10000)begin @(negedge clk);t=t+1;end
            if(acks!=before_count+1 || ack_seq!=seq || ack_status!=status)$fatal(1,"ACK seq=%d status=%d",ack_seq,ack_status);
            seq=seq+1'b1;
        end
    endtask
    task local_command(input [7:0] action);
        begin @(negedge clk);local_action=action;local_v=1;
            while(!local_ready)@(negedge clk);@(negedge clk);local_v=0;end
    endtask
    integer samples=0,audible=0;
    always @(posedge clk)if(pcm_valid)begin
        samples=samples+1;if(pl!=0 || pr!=0)audible=audible+1;
        if((^pl===1'bx) || (^pr===1'bx))$fatal(1,"PCM X l=%h r=%h raw_l=%h raw_r=%h fx=%h rst=%b",pl,pr,dut.pcm_l,dut.pcm_r,dut.fx,dut.audio_rst_n);
    end
    reg [79:0] p;
    initial begin
        repeat(10)@(negedge clk);rn=1;
        for(integer n=0;n<64;n=n+1)begin
            p=0;p[7:0]=63;p[15:8]=36+n;p[23:16]=100;p[31:24]=n%4;p[39:32]=1;
            command(1,p,0);
        end
        repeat(10000)@(negedge clk);
        if(voices!=64 || audible<100 || underruns!=0)$fatal(1,"64voice voices=%d audible=%d underrun=%d",voices,audible,underruns);
        p=0;p[7:0]=7;p[23:8]=1024;p[39:24]=100;p[47:40]=35;command(2,p,0);
        for(integer m=1;m<=3;m=m+1)begin command(3,{64'd0,8'(m),8'd1},0);repeat(5000)@(negedge clk);end
        if(dut.gain!=1024 || dut.bend!=100 || dut.vibrato!=35 || underruns!=0)$fatal(1,"expr/fx integration");
        command(4,5,0);repeat(5000)@(negedge clk);if(voices!=0)$fatal(1,"panic didn't clear voices");
        command(4,2,0);
        p=0;p[7:0]=63;p[15:8]=69;p[23:16]=100;p[39:32]=1;command(1,p,0);
        p[39:32]=0;command(1,p,0);command(4,3,0);
        command(8,0,0);while(data_packets<1)@(negedge clk);
        if(data_opcode!=8'h81 || data_payload[31:16]!=2)$fatal(1,"record telemetry %h",data_payload);
        command(8,1,0);while(data_packets<2)@(negedge clk);
        if(data_opcode!=8'h82 || data_payload[62:56]!=69 || !data_payload[72])$fatal(1,"record RAM response %h",data_payload);
        local_command(6);repeat(300)@(negedge clk);
        if(!guide || playing || dut.guide_mask!=16)$fatal(1,"offline guide localstart");
        local_command(7);repeat(300)@(negedge clk);if(guide || dut.guide_mask!=0)$fatal(1,"guide stop");
        local_command(1);repeat(3000)@(negedge clk);if(!playing || voices<1)$fatal(1,"local score");
        local_command(0);repeat(3000)@(negedge clk);if(playing || dut.performance.held!=0)$fatal(1,"local stop release");
        if(underruns!=0 || overflow)$fatal(1,"streaming fault");
        $display("FULL SYSTEM PASS 64 mixed-timbre voices, expression, effects, panic, recording, offline LED guide samples=%d",samples);$finish;
    end
    initial begin #30000000;$fatal(1,"full timeout");end
endmodule
