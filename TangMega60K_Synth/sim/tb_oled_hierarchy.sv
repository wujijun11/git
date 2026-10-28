`timescale 1ns/1ps
// 导出真实渲染器的字节，由独立Python按用户可读文本和字库逐字节核对。
module tb_oled_hierarchy;
    reg clk=0;always #5 clk=~clk;
    reg [2:0] screen_page=0;
    reg [6:0] column=0;
    reg [3:0] view=0;
    reg [1:0] zone=0,expression_mode=0;
    reg recording=0,playing=0,guide=0,busy=0,control_negative=0;
    reg [7:0] error=0,control_percent=100;
    reg [15:0] record_digits=16'h0012,control_digits=16'h0100;
    wire [7:0] data;
    oled_hierarchy_renderer dut(.*);
    integer f,n,p,x,number;
    initial begin
        f=$fopen("sim/audio_results/oled_hierarchy_pixels.csv","w");
        $fdisplay(f,"frame,view,mode,zone,value,negative,percent,page,column,data");
        for(n=0;n<12;n=n+1)begin
            view=n<9?n:0;
            expression_mode=(n==9 || n==11)?1:n==10?2:0;
            zone=n%4;
            number=n==9?200:n==10?50:n==11?2400:100;
            control_digits=n==9?16'h0200:n==10?16'h0050:n==11?16'h2400:16'h0100;
            control_negative=n==9;
            control_percent=n==9?0:n==10?50:100;
            for(p=0;p<8;p=p+1)begin
                screen_page=p;
                for(x=0;x<128;x=x+1)begin
                    column=x;repeat(2)@(negedge clk);
                    $fdisplay(f,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",n,view,expression_mode,zone,
                        number,control_negative,control_percent,p,x,data);
                end
            end
        end
        $fclose(f);
        $display("OLED HIERARCHY PIXELS EXPORTED 12 frames including signed bend and vibrato percent");
        $finish;
    end
    initial begin #1000000;$fatal(1,"OLED hierarchy timeout");end
endmodule
