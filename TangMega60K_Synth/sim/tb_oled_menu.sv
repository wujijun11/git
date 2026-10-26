`timescale 1ns/1ps
module tb_oled_menu;
    reg clk=0;always #5 clk=~clk;
    reg rn=0;
    tri1 scl,sda;
    reg ack_low=0,nack=0;
    assign sda=ack_low?1'b0:1'bz;
    reg main_menu=1;
    wire fault;wire [31:0] frames;
    oled_status_display #(.CLK_HZ(1000000),.I2C_HZ(100000),
        .POWER_WAIT_CYCLES(8),.FRAME_WAIT_CYCLES(8)) dut(
        .clk(clk),.rst_n(rn),.main_menu(main_menu),.menu_page(2'd0),.zone(2'd1),
        .recording(1'b0),.playing(1'b0),.guide(1'b0),.busy(1'b0),
        .error(8'd0),.record_count(16'd1234),.scl(scl),.sda(sda),
        .fault(fault),.completed_frames(frames));
    reg start=0;reg [15:0] number=0;wire done;wire [15:0] digits;
    bin16_to_bcd bcd(.clk(clk),.rst_n(rn),.start(start),.value(number),.done(done),.digits(digits));
    reg [7:0] received[0:2],image[0:1023];
    integer b,bitno,data_count=0,commands=0;
    // 独立总线从机：按真实SCL采样每字节，并在第九时钟ACK。
    initial forever begin
        @(negedge sda);
        if(scl===1'b1 && rn)begin
            for(b=0;b<3;b=b+1)begin
                for(bitno=7;bitno>=0;bitno=bitno-1)begin
                    @(posedge scl);received[b][bitno]=sda;
                end
                @(negedge scl);ack_low=!nack;
                @(posedge scl);@(negedge scl);ack_low=0;
                if(nack)b=3;
            end
            if(!nack)begin
                if(received[0]!==8'h78)$fatal(1,"incorrect OLED address");
                if(received[1]==8'h40)begin
                    if(data_count<1024)image[data_count]=received[2];
                    data_count=data_count+1;
                    // 第一帧写到一半时改页面，整帧必须仍然使用原来的快照。
                    if(data_count==10)main_menu=0;
                end else if(received[1]==0)begin
                    commands=commands+1;
                    if(commands==1 && received[2]!=8'hae)$fatal(1,"init must disable display first");
                    if(commands==25 && received[2]!=8'haf)$fatal(1,"init display-on missing");
                end else $fatal(1,"invalid control byte");
            end
        end
    end
    task decimal_test(input [15:0] value,input [15:0] expected);
        begin
            @(negedge clk);number=value;start=1;@(negedge clk);start=0;
            wait(done);@(negedge clk);
            if(digits!==expected)$fatal(1,"BCD conversion %0d got %h",value,digits);
        end
    endtask
    initial begin
        repeat(4)@(negedge clk);rn=1;
        decimal_test(0,16'h0000);decimal_test(9,16'h0009);
        decimal_test(10,16'h0010);decimal_test(1024,16'h1024);
        decimal_test(9999,16'h9999);decimal_test(65535,16'h9999);
        wait(frames==1);@(negedge clk);
        if(data_count!=1024 || commands!=49 || fault)$fatal(1,"frame bytes/page commands missing");
        $writememh("sim/audio_results/oled_frame.hex",image);
        // 断开屏幕后错误必须可见，恢复ACK后能够自动重初始化恢复。
        nack=1;wait(fault);nack=0;
        wait(frames==2);@(negedge clk);
        if(fault)$fatal(1,"OLED did not recover from NACK");
        rn=0;repeat(3)@(negedge clk);
        if(frames!=0)$fatal(1,"OLED reset failed");
        $display("OLED MENU PASS I2C frame, BCD, snapshot, NACK recovery and reset");$finish;
    end
    initial begin #20000000;$fatal(1,"OLED timeout");end
endmodule
