`timescale 1ns/1ps
// 外部I2C从机逐字节核对两帧：百分比/刻度与菜单四区选项，输入中途变化不得撕裂。
module tb_oled_volume;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0;
    tri1 scl,sda;
    reg ack_low=0;
    assign sda=ack_low ? 1'b0 : 1'bz;
    reg performance_mode=1;
    reg [7:0] volume_percent=37;
    reg [15:0] record_count=0;
    wire fault;
    wire [31:0] frames;
    oled_status_display #(.CLK_HZ(1000000),.I2C_HZ(100000),.PERFORMANCE_UI_ENABLE(1),
        .POWER_WAIT_CYCLES(8),.FRAME_WAIT_CYCLES(8)) dut(
        .clk(clk),.rst_n(rst_n),.main_menu(1'b0),.menu_page(2'd0),.zone(2'd1),
        .recording(1'b0),.playing(1'b0),.guide(1'b0),.busy(1'b0),.error(8'd0),
        .record_count(record_count),.performance_mode(performance_mode),.volume_percent(volume_percent),
        .scl(scl),.sda(sda),.fault(fault),.completed_frames(frames));
    reg [7:0] received[0:2],image[0:2047],font[0:2047];
    integer b,bitno,count=0,commands=0;
    initial forever begin
        @(negedge sda);
        if(scl===1'b1 && rst_n)begin
            for(b=0;b<3;b=b+1)begin
                for(bitno=7;bitno>=0;bitno=bitno-1)begin
                    @(posedge scl);received[b][bitno]=sda;
                end
                @(negedge scl);ack_low=1;
                @(posedge scl);@(negedge scl);ack_low=0;
            end
            if(received[0]!==8'h78)$fatal(1,"OLED volume address");
            if(received[1]==8'h40)begin
                if(count<2048)image[count]=received[2];
                count=count+1;
                if(count==10)begin performance_mode=0;volume_percent=88;record_count=12345;end
            end else if(received[1]==0)commands=commands+1;
            else $fatal(1,"OLED control byte");
        end
    end
    function integer expected_glyph(input integer frame_id,row,col);
        begin
            expected_glyph=0;
            if(frame_id==0)begin
                case(row)
                    0:case(col)0:expected_glyph=21;1:expected_glyph=13;2:expected_glyph=17;3:expected_glyph=18;endcase
                    1:case(col)0:expected_glyph=21;1:expected_glyph=13;3:expected_glyph=1;
                        4:expected_glyph=4;5:expected_glyph=8;6:expected_glyph=14;endcase
                    3:case(col)0:expected_glyph=50;1:expected_glyph=51;2:expected_glyph=52;
                        3:expected_glyph=53;4:expected_glyph=19;5:expected_glyph=17;6:expected_glyph=18;endcase
                endcase
            end else begin
                case(row)
                    0:case(col)0:expected_glyph=21;1:expected_glyph=22;2:expected_glyph=17;3:expected_glyph=18;
                        6:expected_glyph=23;7:expected_glyph=3;endcase
                    1:case(col)0:expected_glyph=29;1:expected_glyph=30;2:expected_glyph=31;3:expected_glyph=30;
                        4:expected_glyph=32;5:expected_glyph=33;6:expected_glyph=11;7:expected_glyph=12;endcase
                    2:case(col)0:expected_glyph=57;1:expected_glyph=58;2:expected_glyph=63;
                        4,5,6,7:expected_glyph=10;endcase
                    3:case(col)0:expected_glyph=50;1:expected_glyph=51;2:expected_glyph=15;
                        3:expected_glyph=53;4:expected_glyph=42;5:expected_glyph=21;6:expected_glyph=13;endcase
                endcase
            end
        end
    endfunction
    integer index,frame_id,p,column,glyph;
    reg [7:0] expected;
    reg fill;
    initial begin
        $readmemh("rtl/audio/rom/menu_font.hex",font);
        repeat(4)@(negedge clk);rst_n=1;
        wait(frames==2);@(negedge clk);
        if(count!=2048 || commands!=73 || fault)$fatal(1,"OLED volume frame incomplete");
        for(index=0;index<2048;index=index+1)begin
            frame_id=index/1024;p=(index%1024)/128;column=index%128;
            glyph=expected_glyph(frame_id,p/2,column/16);
            expected=font[glyph*32+(p%2)*16+column%16];
            if(frame_id==0 && p/2==2)begin
                fill=column>=6 && column<=121 && (column-6)*100<37*116;
                if(column==4 || column==123)expected=(p%2)?8'h07:8'hfc;
                else if(column>4 && column<123)
                    expected=(p%2)?(fill?8'h07:8'h04):(fill?8'hfc:8'h04);
                else expected=0;
            end else if(frame_id==1 && p/2==1 && column/32==1)expected=expected^8'hff;
            if(image[index]!==expected)$fatal(1,"OLED volume pixel index=%d got=%h expected=%h",index,image[index],expected);
        end
        $writememh("sim/audio_results/oled_volume_frames.hex",image);
        $display("OLED VOLUME PASS 2048 external I2C bytes, 037 percent, bar, four options, region highlight, atomic snapshot");
        $finish;
    end
    initial begin #15000000;$fatal(1,"OLED volume timeout count=%d",count);end
endmodule
