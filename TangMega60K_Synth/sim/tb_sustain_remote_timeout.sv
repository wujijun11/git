`timescale 1ns/1ps
// Inject at the decoded UART/menu boundaries, keep router/watchdog/allocator/
// sustain gate/audio engine real. No fabricated BLE/RF hardware claim.
module tb_sustain_remote_timeout;
    reg clk=0; always #5 clk=~clk;
    reg rn=0, valid=0, local_write=0, local_value=0;
    reg [7:0] seq=0,opcode=0;
    reg [79:0] payload=0;
    tri1 [2:0] scl,sda;
    wire enabled; wire [6:0] deferred;
    integer acks=0,engine_ons=0,engine_offs=0;
    instrument_full_system #(.CLK_HZ(1000),.UART_BAUD(100),.SUSTAIN_ENABLE(1),
        .SENSOR_SETTLE_CYCLES(10),.MENU_ENABLE(0),.STABLE_CHORD_MIX_ENABLE(1)) dut(
        .clk(clk),.rst_n(rn),.uart_rx(1'b1),.mpr_scl(scl),.mpr_sda(sda),.mpr_irq_n(3'b111),
        .local_action_valid(1'b0),.local_action(8'd0),
        .video_clk(clk),.video_x(10'd0),.video_y(10'd0),.video_de(1'b0),
        .sustain_enabled(enabled),.sustain_deferred_count(deferred));
    initial begin
        force dut.cv=valid;force dut.cs=seq;force dut.co=opcode;force dut.cp=payload;
        force dut.rr=1'b1;
        force dut.sensors.ready=3'b111;force dut.sensors.fault=3'b000;
        force dut.sensor_overflow=1'b0;
        force dut.local_sustain_write=local_write;force dut.local_sustain_value=local_value;
    end
    always @(posedge clk)if(rn)begin
        if(dut.rv && dut.rr && dut.ro==8'h80)begin
            if(dut.rp[15:8]!=0)$fatal(1,"unexpected command NACK");
            acks=acks+1;
        end
        if(dut.engine_cmd_valid && dut.engine_cmd_ready)
            if(dut.engine_cmd_on)engine_ons=engine_ons+1;else engine_offs=engine_offs+1;
    end
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task reset_case;
        begin rn=0;valid=0;local_write=0;cycles(5);rn=1;cycles(100);seq=0;end
    endtask
    task request(input [7:0] op,input [79:0] data);
        integer before_ack,t;
        begin
            @(negedge clk);before_ack=acks;opcode=op;payload=data;valid=1;t=0;
            do begin @(posedge clk);t=t+1;if(t>3000)$fatal(1,"command acceptance timeout");end while(!dut.cr);
            @(negedge clk);valid=0;t=0;
            while(acks==before_ack)begin cycles(1);t=t+1;if(t>3000)$fatal(1,"ACK timeout");end
            cycles(2);seq=seq+1'b1;
        end
    endtask
    task local_pedal(input bit value);
        begin @(negedge clk);local_write=1;local_value=value;cycles(1);local_write=0;cycles(2);end
    endtask
    task released_remote_note;
        integer t;
        begin
            request(1,(80'd1<<32)|(80'd2<<24)|(80'd100<<16)|(80'd60<<8));
            request(1,(80'd2<<24)|(80'd100<<16)|(80'd60<<8));
            t=0;while(deferred!=1)begin cycles(1);t=t+1;if(t>2000)$fatal(1,"release was not deferred");end
            if(dut.watchdog.held!=0 || dut.phone_releasing)$fatal(1,"test must have no held remote key");
        end
    endtask
    integer before_off;
    initial begin
        reset_case();request(3,80'h0102);released_remote_note();before_off=engine_offs;
        cycles(5000);
        if(enabled || deferred || engine_offs<=before_off)
            $fatal(1,"remote sustain survived lost heartbeat with all keys released");
        // Velocity zero is NOTE OFF in the existing public V2 contract.
        // It must not arm the held-key watchdog or cancel a local pedal later.
        reset_case();local_pedal(1);
        request(1,(80'd1<<32)|(80'd2<<24)|(80'd60<<8));cycles(100);
        if(dut.watchdog.held!=0)$fatal(1,"velocity-zero NOTE ON armed held-key watchdog");
        cycles(5000);if(!enabled)$fatal(1,"velocity-zero event cancelled local sustain");
        // A live remote controller can keep a released sustained voice.
        reset_case();request(3,80'h0102);released_remote_note();before_off=engine_offs;
        repeat(4)begin cycles(1500);request(8,80'd0);end
        if(!enabled || deferred!=1 || engine_offs!=before_off)$fatal(1,"live heartbeat released sustain");
        cycles(5000);if(enabled || deferred)$fatal(1,"heartbeat expiry did not release");
        // Local pedal ownership must survive any length of remote silence.
        reset_case();local_pedal(1);released_remote_note();before_off=engine_offs;cycles(6500);
        if(!enabled || deferred!=1 || engine_offs!=before_off)$fatal(1,"local sustain was timed out");
        local_pedal(0);cycles(1600);if(enabled || deferred)$fatal(1,"local pedal-up failed");
        // Most recent local/remote writer owns the setting.
        reset_case();request(3,80'h0102);cycles(1000);local_pedal(1);cycles(5000);
        if(!enabled)$fatal(1,"local takeover lost ownership");
        request(3,80'h0102);cycles(5000);if(enabled)$fatal(1,"remote takeover never expired");
        request(3,80'h0102);request(4,80'd5);cycles(5000);
        if(enabled || deferred)$fatal(1,"panic retained remote sustain");
        $display("SUSTAIN REMOTE TIMEOUT PASS released-key expiry, heartbeat, local ownership, takeover, panic");
        $finish;
    end
    initial begin #2000000;$fatal(1,"remote sustain test timeout");end
endmodule
