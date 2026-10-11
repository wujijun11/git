`timescale 1ns/1ps
module tb_remote_note_watchdog;
    reg clk=0;always #5 clk=~clk;reg rn=0,hb=0,expire=0,acc=0,on=0,ready=0;reg [6:0] note=0;
    wire ev,eon,rel;wire [5:0] source;wire [6:0] en,vel;wire [1:0] timbre;wire [31:0] count;
    integer offs=0;reg [127:0] released=0;
    remote_note_watchdog #(.CLK_HZ(100),.TIMEOUT_SECONDS(1))dut(.clk(clk),.rst_n(rn),
        .heartbeat(hb),.expire(expire),.accepted(acc),.accepted_on(on),.accepted_note(note),
        .event_valid(ev),.event_ready(ready),.event_on(eon),.event_source(source),
        .event_note(en),.event_velocity(vel),.event_timbre(timbre),.releasing(rel),.timeout_count(count));
    always @(posedge clk)if(ev && ready)begin
        if(eon || source!=63 || released[en])$fatal(1,"wrong watchdog release");
        offs<=offs+1;released[en]<=1;
    end
    task pressed(input integer n,input bit v);
        begin @(negedge clk);acc=1;note=n;on=v;hb=1;@(negedge clk);acc=0;hb=0;end
    endtask
    initial begin
        repeat(3)@(negedge clk);rn=1;pressed(60,1);pressed(64,1);pressed(67,1);pressed(64,0);
        repeat(90)@(negedge clk);hb=1;@(negedge clk);hb=0;
        repeat(90)@(negedge clk);if(rel)$fatal(1,"heartbeat ignored");
        repeat(100)@(negedge clk);if(!ev || !rel || en!=60)$fatal(1,"timeout");
        repeat(20)begin @(negedge clk);if(!ev || en!=60)$fatal(1,"lost stalled off");end
        ready=1;repeat(150)@(negedge clk);
        if(rel || offs!=2 || !released[60] || !released[67] || count!=1)$fatal(1,"release set");
        released=0;pressed(72,1);expire=1;@(negedge clk);expire=0;repeat(140)@(negedge clk);
        if(offs!=3 || count!=2)$fatal(1,"overflow recovery");
        $display("REMOTE NOTE WATCHDOG PASS");$finish;
    end
    initial begin #20000;$fatal(1,"timeout");end
endmodule
