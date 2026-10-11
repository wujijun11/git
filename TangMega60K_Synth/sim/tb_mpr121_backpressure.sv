`timescale 1ns/1ps
module tb_mpr121_backpressure;
    reg clk=0;always #5 clk=~clk;
    reg resetn=0;reg [2:0] snapshot_valid=0;wire [2:0] snapshot_ready;
    reg [7:0] touch0=0,touch1=0;reg [8:0] touch2=0;reg [2:0] fault=0;
    reg [174:0] key_map_flat;reg [1:0] current_timbre=2;
    wire key_valid,key_on;reg key_ready=0;
    wire [5:0] key_source;wire [6:0] key_note,key_velocity;wire [1:0] key_timbre;
    wire [24:0] touch_mask;wire overflow;wire [15:0] pending_events;
    mpr121_key_eventizer dut(.*);
    integer k,events=0,t;reg [24:0] held=0;
    reg stalled=0;reg [22:0] old_payload;
    reg [2:0] accepted_at_edge;
    always @(posedge clk) if(resetn) begin
        if(stalled && (!key_valid || {key_on,key_source,key_note,key_velocity,key_timbre}!==old_payload))
          $fatal(1,"queue payload changed under sustained backpressure");
        stalled=key_valid && !key_ready;old_payload={key_on,key_source,key_note,key_velocity,key_timbre};
        if(key_valid && key_ready) begin
          k=key_source-25;
          if(k<0 || k>24 || key_note!=60+k || key_velocity!=100 || key_timbre!=2)
            $fatal(1,"bad queued payload");
          if(key_on==held[k]) $fatal(1,"lost or duplicate transition source %0d",key_source);
          held[k]=key_on;events=events+1;
        end
        if(overflow) $fatal(1,"reserved capacity failed");
    end
    task send_batch(input bit on);
      reg [2:0] accepted;
      integer timeout;
      begin
        @(negedge clk);touch0=on?8'hff:0;touch1=on?8'hff:0;touch2=on?9'h1ff:0;
        snapshot_valid=7;accepted=0;timeout=0;
        while(accepted!=7 && timeout<10000) begin
          @(posedge clk);accepted=accepted | (snapshot_valid & snapshot_ready);
          @(negedge clk);snapshot_valid=7 & ~accepted;timeout=timeout+1;
        end
        if(accepted!=7) $fatal(1,"batch acceptance timeout on=%0d accepted=%b count=%0d scanning=%0d pending=%b",on,accepted,pending_events,dut.scanning,dut.release_pending);
        repeat(30) @(negedge clk);
      end
    endtask
    initial begin
      for(t=0;t<25;t=t+1) key_map_flat[t*7 +:7]=60+t;
      repeat(5) @(negedge clk);resetn=1;
      send_batch(1);send_batch(0);
      if(pending_events!=50) $fatal(1,"50 transition burst not retained");
      @(negedge clk);snapshot_valid=7;touch0=255;touch1=255;touch2=511;
      // Eight more events fit, then subsequent complete module batches stall.
      t=0;
      while(pending_events!=58 && t<100) begin
        @(posedge clk);accepted_at_edge=snapshot_ready & snapshot_valid;
        @(negedge clk);snapshot_valid=snapshot_valid & ~accepted_at_edge;t=t+1;
      end
      if(pending_events!=58) $fatal(1,"expected capacity boundary got %0d",pending_events);
      repeat(500) begin
        @(negedge clk);if(snapshot_ready!=0 || pending_events!=58) $fatal(1,"unreserved batch accepted");
      end
      // Fault work is deferred safely while a batch and FIFO are stalled.
      fault=1;repeat(100) @(negedge clk);key_ready=1;
      while(snapshot_valid!=0) begin
        @(posedge clk);accepted_at_edge=snapshot_ready & snapshot_valid;
        @(negedge clk);snapshot_valid=snapshot_valid & ~accepted_at_edge;
      end
      repeat(300) @(negedge clk);
      if(events!=83 || held!=25'h1ffff00) $fatal(1,"fault or stalled batch lost events=%0d held=%h",events,held);
      fault=0;send_batch(0);repeat(100) @(negedge clk);
      if(events!=100 || held!=0) $fatal(1,"release after FIFO stall failed events=%0d",events);
      $display("PASS tb_mpr121_backpressure: 50 retained transitions, capacity reservation, stable payload and deferred fault releases");$finish;
    end
    initial begin #2000000;$fatal(1,"backpressure watchdog");end
endmodule
