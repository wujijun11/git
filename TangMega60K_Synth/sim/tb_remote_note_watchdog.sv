`timescale 1ns/1ps
module tb_remote_note_watchdog;
    reg clk=0;always #5 clk=~clk;reg rn=0,hb=0,expire=0,acc=0,on=0,ready=0;reg [6:0] note=0;
    wire ev,eon,rel;wire [5:0] source;wire [6:0] en,vel;wire [1:0] timbre;wire [31:0] count;
    integer offs=0;reg [127:0] released=0;
    remote_note_watchdog #(.CLK_HZ(100),.TIMEOUT_SECONDS(1))dut(.clk(clk),.keepalive_required(1'b0),.rst_n(rn),
        .heartbeat(hb),.expire(expire),.accepted(acc),.accepted_on(on),.accepted_note(note),
        .event_valid(ev),.event_ready(ready),.event_on(eon),.event_source(source),
        .event_note(en),.event_velocity(vel),.event_timbre(timbre),.releasing(rel),.timeout_count(count));
    wire [22:0] payload={eon,source,en,vel,timbre};
    reg stalled=0;reg [22:0] stalled_payload;
    always @(posedge clk)begin
        if(!rn)begin offs<=0;released<=0;stalled<=0;end
        else begin
            if(stalled && (!ev || payload!==stalled_payload))$fatal(1,"lost stalled off payload");
            stalled<=ev && !ready;stalled_payload<=payload;
            if(ev && ready)begin
                if(eon || source!=63 || vel!=0 || timbre!=0 || released[en])$fatal(1,"wrong watchdog release");
                offs<=offs+1;released[en]<=1;
            end
        end
    end
    task pressed(input integer n,input bit v);
        begin @(negedge clk);acc=1;note=n;on=v;hb=1;@(negedge clk);acc=0;hb=0;end
    endtask
    task reset_case;
        begin
            @(negedge clk);rn=0;hb=0;expire=0;acc=0;on=0;ready=0;note=0;
            repeat(3)@(negedge clk);rn=1;
        end
    endtask
    task expire_with_event(input integer n,input bit v);
        begin
            @(negedge clk);acc=1;note=n;on=v;hb=1;expire=1;
            @(negedge clk);acc=0;hb=0;expire=0;
        end
    endtask
    task wait_release(input integer n);
        integer cycles;
        begin
            cycles=0;
            while(!ev && cycles<160)begin @(negedge clk);cycles=cycles+1;end
            if(!ev || !rel || en!=n)$fatal(1,"missing forced off note=%0d got=%0d",n,en);
            repeat(20)begin @(negedge clk);if(!ev || en!=n)$fatal(1,"forced off changed under backpressure");end
            ready=1;cycles=0;
            while(rel && cycles<160)begin @(negedge clk);cycles=cycles+1;end
            if(rel || ev || dut.held!=0 || offs!=1 || !released[n] || count!=1)
                $fatal(1,"forced release did not finish exactly once note=%0d",n);
        end
    endtask
    task first_on_expire;
        begin
            reset_case();expire_with_event(127,1);
            // The accepted NoteOn belongs to this expiry epoch even though the
            // pre-edge held mask was empty. Check admission before timer expiry.
            if(!rel || count!=1 || dut.held!==(128'd1<<127))
                $fatal(1,"same-cycle first NoteOn+expire did not start release");
            wait_release(127);
            $display("WATCHDOG first NoteOn+expire PASS");
        end
    endtask
    task last_off_expire;
        begin
            reset_case();pressed(60,1);expire_with_event(60,0);
            // The accepted final NoteOff already removed all ownership. There
            // is no release epoch, blocked admission or timeout to report.
            if(rel || ev || count!=0 || dut.held!=0)
                $fatal(1,"same-cycle last NoteOff+expire started an empty release");
            ready=1;repeat(150)@(negedge clk);
            if(rel || ev || count!=0 || offs!=0)$fatal(1,"final NoteOff caused a later release");
            $display("WATCHDOG last NoteOff+expire PASS");
        end
    endtask
    task remaining_note_expire;
        begin
            reset_case();pressed(60,1);pressed(64,1);expire_with_event(64,0);
            if(!rel || count!=1 || dut.held!==(128'd1<<60))
                $fatal(1,"same-cycle NoteOff+expire missed another held note");
            wait_release(60);
            $display("WATCHDOG remaining note+expire PASS");
        end
    endtask
    task normal_timeout;
        begin
        reset_case();pressed(60,1);pressed(64,1);pressed(67,1);pressed(64,0);
        repeat(90)@(negedge clk);hb=1;@(negedge clk);hb=0;
        repeat(90)@(negedge clk);if(rel)$fatal(1,"heartbeat ignored");
        repeat(100)@(negedge clk);if(!ev || !rel || en!=60)$fatal(1,"timeout");
        repeat(20)begin @(negedge clk);if(!ev || en!=60)$fatal(1,"lost stalled off");end
        ready=1;repeat(150)@(negedge clk);
        if(rel || offs!=2 || !released[60] || !released[67] || count!=1)$fatal(1,"release set");
        released=0;pressed(72,1);expire=1;@(negedge clk);expire=0;repeat(140)@(negedge clk);
        if(offs!=3 || count!=2)$fatal(1,"overflow recovery");
        $display("WATCHDOG heartbeat/timeout/backpressure PASS");
        end
    endtask
    integer test_case;
    initial begin
        // Individual cases allow the original RTL to demonstrate both failing
        // expiry boundaries independently, before running the fixed full suite.
        if(!$value$plusargs("WATCHDOG_CASE=%d",test_case))test_case=0;
        case(test_case)
            0:begin normal_timeout();first_on_expire();last_off_expire();remaining_note_expire();end
            1:first_on_expire();
            2:last_off_expire();
            3:normal_timeout();
            4:remaining_note_expire();
            default:$fatal(1,"unknown WATCHDOG_CASE=%0d",test_case);
        endcase
        $display("REMOTE NOTE WATCHDOG PASS");$finish;
    end
    initial begin #20000;$fatal(1,"timeout");end
endmodule
