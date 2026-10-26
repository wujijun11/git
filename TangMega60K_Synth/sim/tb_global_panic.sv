`timescale 1ns/1ps
// Real UART/router and all note producers. The I2C samplers are bypassed at
// their snapshot boundary; the production MPR eventizer/FIFO still runs.
module tb_global_panic;
    reg clk=0;always #10.1725 clk=~clk;
    reg vclk=0;always #20 vclk=~vclk;
    reg rn=0,rx=1,local_v=0;reg [7:0] local_action=0;
    wire tx,local_ready;tri1 [2:0] scl,sda;
    wire [6:0] voices;wire [24:0] touches;wire playing,guide;
    instrument_full_system #(.UART_BAUD(3072000))dut(
        .clk(clk),.rst_n(rn),.uart_rx(rx),.uart_tx(tx),
        .mpr_scl(scl),.mpr_sda(sda),.mpr_irq_n(3'b111),
        .local_action_valid(local_v),.local_action_ready(local_ready),.local_action(local_action),
        .active_count(voices),.touch_mask(touches),.playing(playing),.guide_active(guide),
        .video_clk(vclk),.video_x(10'd0),.video_y(10'd0),.video_de(1'b0));
    reg [2:0] snapshot_valid=0;reg [1031:0] snapshots=0;
    // PANIC短路径必须与原通用动作握手语义逐拍一致，包括远程/菜单冲突时。
    always @(negedge clk) if(rn) begin
        if(dut.local_panic !== (dut.merged_action_valid && dut.merged_action_ready && dut.merged_action==8'd5))
            $fatal(1,"local PANIC fast acceptance differs from original handshake");
    end
    initial begin
        force dut.sensors.snap_valid=snapshot_valid;
        force dut.sensors.snaps=snapshots;
        force dut.sensors.fault=3'b000;
    end
    task snapshot(input integer sensor,input [8:0] mask);
        integer timeout;
        begin
            @(negedge clk);snapshots[sensor*344+:12]={3'd0,mask};snapshot_valid=1<<sensor;
            timeout=0;
            while(!dut.sensors.snap_ready[sensor] && timeout<1000)begin @(negedge clk);timeout=timeout+1;end
            if(timeout==1000)$fatal(1,"snapshot blocked");
            @(negedge clk);snapshot_valid=0;
        end
    endtask
    wire [7:0] byte_rx;wire byte_valid,frame_error;
    remote_uart_rx #(.CLK_HZ(49152000),.BAUD(3072000))receiver(
        .clk(clk),.reset(!rn),.rx(tx),.data(byte_rx),.valid(byte_valid),.framing_error(frame_error));
    reg [7:0] bytes[0:15];integer byte_index=0,acks=0;
    function [7:0] crc(input [7:0] old,input [7:0] b);
        reg [7:0] q;begin q=old^b;for(integer k=0;k<8;k=k+1)q=q[7]?(q<<1)^7:q<<1;crc=q;end
    endfunction
    reg [7:0] check;
    always @(posedge clk)if(rn)begin
        if(frame_error)$fatal(1,"ACK framing");
        if(byte_valid)begin
            bytes[byte_index]=byte_rx;
            if(byte_index==15)begin
                check=0;for(integer k=2;k<15;k=k+1)check=crc(check,bytes[k]);
                if(bytes[0]!=8'ha5 || bytes[1]!=8'h5a || bytes[4]!=8'h80 || check!=byte_rx)
                    $fatal(1,"ACK packet/CRC");
                if(bytes[3]!=acks || bytes[6]!=0)$fatal(1,"ACK lost/reordered seq=%d expected=%d status=%d",bytes[3],acks,bytes[6]);
                acks=acks+1;byte_index=0;
            end else byte_index=byte_index+1;
        end
    end
    task send_byte(input [7:0] b);
        begin rx=0;repeat(16)@(negedge clk);
            for(integer k=0;k<8;k=k+1)begin rx=b[k];repeat(16)@(negedge clk);end
            rx=1;repeat(16)@(negedge clk);end
    endtask
    reg [7:0] seq=0;
    task send_command(input [7:0] op,input [79:0] payload);
        reg [7:0] c;
        begin
            c=crc(crc(crc(0,1),seq),op);
            @(negedge clk);send_byte(8'ha5);send_byte(8'h5a);send_byte(1);send_byte(seq);send_byte(op);
            for(integer k=0;k<10;k=k+1)begin send_byte(payload[k*8+:8]);c=crc(c,payload[k*8+:8]);end
            send_byte(c);seq=seq+1'b1;
        end
    endtask
    task wait_acks(input integer target);
        integer timeout;
        begin timeout=0;while(acks<target && timeout<30000)begin @(negedge clk);timeout=timeout+1;end
            if(acks!=target)$fatal(1,"ACK timeout actual=%d target=%d",acks,target);end
    endtask
    task local_command(input [7:0] action);
        begin @(negedge clk);local_action=action;local_v=1;
            while(!local_ready)@(negedge clk);@(negedge clk);local_v=0;end
    endtask
    task wait_quiet;
        integer timeout;
        begin timeout=0;while(dut.panic_quiescing && timeout<1000)begin @(negedge clk);timeout=timeout+1;end
            if(timeout==1000)$fatal(1,"PANIC drain deadlocked");end
    endtask
    reg panic_seen=0,allow_new_touch=0;
    reg previous_panic_discard=0;
    integer discarded_sensor=0,discarded_perf=0,discarded_watchdog=0,post_panic_ons=0,panic_cycles=0;
    integer discarded_buffered_sensor=0;
    wire buffered_sensor=dut.arbiter_push_valid && dut.arb_selected==0;
    reg sensor_stalled=0,perf_stalled=0,remote_stalled=0,watchdog_stalled=0;
    reg [22:0] last_sensor,last_perf,last_remote,last_watchdog;
    wire [22:0] sensor_payload={dut.sensor_on,dut.sensor_source,dut.sensor_note,dut.sensor_velocity,dut.sensor_timbre};
    wire [22:0] perf_payload={dut.perf_on,dut.perf_source,dut.perf_note,dut.perf_velocity,dut.perf_timbre};
    wire [22:0] remote_payload={dut.remote_on,dut.remote_source,dut.remote_note,dut.remote_velocity,dut.remote_timbre};
    wire [22:0] watchdog_payload={dut.watchdog_on,dut.watchdog_source,dut.watchdog_note,dut.watchdog_velocity,dut.watchdog_timbre};
    always @(posedge clk)if(rn)begin
        // Source-side valid/data must remain stable until a real ready handshake,
        // including the transition from an arbiter stall into the PANIC sink.
        if(sensor_stalled && (!dut.sensor_ev || sensor_payload!==last_sensor))$fatal(1,"sensor valid/ready broken");
        if(perf_stalled && (!dut.perf_ev || perf_payload!==last_perf))$fatal(1,"performance valid/ready broken");
        if(remote_stalled && (!dut.remote_ev || remote_payload!==last_remote))$fatal(1,"remote valid/ready broken");
        if(watchdog_stalled && (!dut.watchdog_ev || watchdog_payload!==last_watchdog))$fatal(1,"watchdog valid/ready broken");
        sensor_stalled=dut.sensor_ev && !dut.sensor_er;last_sensor=sensor_payload;
        perf_stalled=dut.perf_ev && !dut.perf_er;last_perf=perf_payload;
        remote_stalled=dut.remote_ev && !dut.remote_er;last_remote=remote_payload;
        watchdog_stalled=dut.watchdog_ev && !dut.watchdog_er;last_watchdog=watchdog_payload;
        if(dut.panic_discard)begin
            panic_seen=1;panic_cycles=panic_cycles+1;
            // 新弹性级可提前接走一条；把该条与来源队列的剩余条目一起精确计数。
            // 首次PANIC即禁止该条出队，随后异步复位必须清掉有效位。
            if(!previous_panic_discard && buffered_sensor)
                discarded_buffered_sensor=discarded_buffered_sensor+1;
            // 命令/事件入口必须立即屏蔽；高扇出音频复位允许寄存边界的一拍延迟。
            if((previous_panic_discard && dut.audio_rst_n) || dut.cr || dut.push_valid)
                $fatal(1,"PANIC sink admitted audio/new command");
            if(!dut.audio_rst_n && dut.event_pipeline.valid)
                $fatal(1,"PANIC did not clear the buffered event");
            if(dut.sensor_ev && dut.sensor_er)discarded_sensor=discarded_sensor+1;
            if(dut.perf_ev && dut.perf_er)discarded_perf=discarded_perf+1;
            if(dut.watchdog_ev && dut.watchdog_er)discarded_watchdog=discarded_watchdog+1;
        end
        if(panic_seen && dut.push_valid && dut.push_ready && dut.push_payload[22])begin
            if(dut.push_payload[21:16]!=63 && !allow_new_touch)$fatal(1,"stale producer note-on replayed after PANIC");
            post_panic_ons=post_panic_ons+1;
        end
        previous_panic_discard=dut.panic_discard;
    end
    reg [79:0] p;integer timeout;
    initial begin
        repeat(10)@(negedge clk);rn=1;
        p=0;p[7:0]=63;p[15:8]=69;p[23:16]=100;p[39:32]=1;
        send_command(1,p);wait_acks(1);repeat(2000)@(negedge clk);
        if(voices!=1 || dut.watchdog.held==0)$fatal(1,"phone setup");
        // Stall the audio input, queue all 25 physical on transitions and a
        // pending offline note. A forced TX stall lets PANIC and a later NOTE
        // coexist in the actual UART FIFO before the router accepts PANIC.
        force dut.push_ready=1'b0;
        snapshot(0,9'h0ff);snapshot(1,9'h0ff);snapshot(2,9'h1ff);
        repeat(30)@(negedge clk);local_command(1);repeat(20)@(negedge clk);
        if(dut.sensor_pending+buffered_sensor!=25 || !buffered_sensor ||
            !dut.sensor_ev || !dut.perf_ev || !playing)
            $fatal(1,"producer backlog missing sensor=%d buffered=%b perf=%b",
                dut.sensor_pending,buffered_sensor,dut.perf_ev);
        force dut.rr=1'b0;
        send_command(3,80'h00000000000000000200);
        send_command(4,80'd5);
        p[15:8]=90;send_command(1,p);
        if(!dut.rv || dut.uart.count!=2)$fatal(1,"UART backlog setup count=%d",dut.uart.count);
        release dut.rr;
        timeout=0;while(!dut.panic_quiescing && timeout<1000)begin @(negedge clk);timeout=timeout+1;end
        if(timeout==1000)$fatal(1,"UART PANIC not accepted");
        if(!dut.cv || dut.cs!=3 || dut.cr)$fatal(1,"new UART NOTE not preserved during PANIC");
        release dut.push_ready;
        wait_quiet;wait_acks(4);repeat(3000)@(negedge clk);
        if(voices!=1 || playing || guide || dut.performance.held!=0 || dut.watchdog.held!=(128'd1<<90))
            $fatal(1,"PANIC restored old state voices=%d perfheld=%h phoneheld=%h",voices,dut.performance.held,dut.watchdog.held);
        if(discarded_sensor+discarded_buffered_sensor!=25 || discarded_buffered_sensor!=1 ||
            discarded_perf<2 || discarded_watchdog<1 || post_panic_ons!=1)
            $fatal(1,"drain counts sensor=%d buffered=%d perf=%d watchdog=%d postons=%d",
                discarded_sensor,discarded_buffered_sensor,discarded_perf,discarded_watchdog,post_panic_ons);
        if(dut.panic_blocked_keys!=25'h1ffffff)$fatal(1,"held-key quarantine missing");
        // Repeated held snapshots cannot resurrect notes. Local PANIC must use
        // exactly the same sink/reset policy and leave UART usable afterwards.
        snapshot(0,9'h0ff);snapshot(1,9'h0ff);snapshot(2,9'h1ff);
        local_command(5);wait_quiet;repeat(2000)@(negedge clk);
        if(voices!=0 || dut.watchdog.held!=0)$fatal(1,"local PANIC not global");
        p[15:8]=91;send_command(1,p);wait_acks(5);repeat(2000)@(negedge clk);
        if(voices!=1)$fatal(1,"new phone event lost after local PANIC");
        // A physical release removes quarantine; a subsequent fresh press is
        // accepted once. The controller and score RAM were never reset.
        snapshot(0,0);snapshot(1,0);snapshot(2,0);repeat(100)@(negedge clk);
        if(touches!=0 || dut.panic_blocked_keys!=0)$fatal(1,"release did not clear quarantine");
        allow_new_touch=1;snapshot(0,1);repeat(3000)@(negedge clk);
        if(voices!=2 || post_panic_ons!=3)$fatal(1,"fresh physical press lost/duplicated voices=%d ons=%d",voices,post_panic_ons);
        if(dut.uart_overflows!=0 || dut.crc_errors!=0 || dut.framing_errors!=0)$fatal(1,"transport fault");
        $display("GLOBAL PANIC PASS old MPR=%0d buffered=%0d total=%0d perf=%0d watchdog=%0d sink_cycles=%0d; UART ACK/FIFO and fresh notes preserved",
            discarded_sensor,discarded_buffered_sensor,discarded_sensor+discarded_buffered_sensor,
            discarded_perf,discarded_watchdog,panic_cycles);
        $finish;
    end
    initial begin #20000000;$fatal(1,"global PANIC timeout");end
endmodule
