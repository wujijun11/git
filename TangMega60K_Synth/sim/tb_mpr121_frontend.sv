`timescale 1ns/1ps
module tb_mpr121_frontend #(parameter EARLY=0);
    reg clk=0;always #5 clk=~clk;
    reg resetn=0;reg [2:0] irq_n=3'b111;
    tri1 [2:0] scl,sda;
    reg [174:0] key_map_flat;reg [1:0] current_timbre=2;
    wire key_valid,key_on;reg key_ready=1;
    wire [5:0] key_source;wire [6:0] key_note,key_velocity;wire [1:0] key_timbre;
    wire expr_update_valid;reg expr_update_ready=1;wire [2:0] expr_update_mask;
    wire [11:0] expr_update_gain_q1_11;wire signed [12:0] expr_update_bend_cents;
    wire [7:0] expr_update_vibrato_depth_cents;
    wire [24:0] touch_mask;wire [2:0] fault,ready;
    wire event_overflow;wire [15:0] pending_events;wire [11:0] last_error;
    wire [95:0] error_count,last_success_age;wire [14:0] init_stage;
    wire [47:0] oor_status;wire slider_active;wire [11:0] slider_position;
    reg [1:0] nack0=0,nack1=2,nack2=0;
    reg mismatch0=1,mismatch1=0,mismatch2=0;
    reg hold0=0,hold1=0,hold2=0;
    mpr121_input_frontend #(.CLK_HZ(4000000),.I2C_HZ(400000),
      .TIMEOUT_CYCLES(10000),.POLL_CYCLES(40),.RESET_CYCLES(20),
      .SETTLE_CYCLES(100),.RETRY_CYCLES(200),.CALIBRATION_SNAPSHOTS(2),.EARLY_KEY_ENABLE(EARLY)) dut(.*);
    mpr121_bus_model m0(clk,scl[0],sda[0],nack0,mismatch0,hold0,1'b0);
    mpr121_bus_model m1(clk,scl[1],sda[1],nack1,mismatch1,hold1,1'b0);
    mpr121_bus_model m2(clk,scl[2],sda[2],nack2,mismatch2,hold2,1'b0);
    integer event_count=0,expr_count=0,k,source_index;
    reg [24:0] held=0;reg [6:0] held_note[0:24];
    reg stalled_key=0,stalled_expr=0;reg [22:0] previous_key;
    reg [35:0] previous_expr;
    reg signed [12:0] last_bend=0;
    always @(posedge clk) if(resetn) begin
      if(stalled_key && (!key_valid || {key_on,key_source,key_note,key_velocity,key_timbre}!==previous_key))
        $fatal(1,"key payload changed while stalled");
      if(stalled_expr && (!expr_update_valid || {expr_update_mask,expr_update_gain_q1_11,expr_update_bend_cents,expr_update_vibrato_depth_cents}!==previous_expr))
        $fatal(1,"expression payload changed while stalled");
      stalled_key=key_valid && !key_ready;previous_key={key_on,key_source,key_note,key_velocity,key_timbre};
      stalled_expr=expr_update_valid && !expr_update_ready;
      previous_expr={expr_update_mask,expr_update_gain_q1_11,expr_update_bend_cents,expr_update_vibrato_depth_cents};
      if(key_valid && key_ready) begin
        source_index=key_source-25;
        if(source_index<0 || source_index>=25 || key_velocity!=100) $fatal(1,"invalid physical key event");
        if(key_on) begin
          if(held[source_index]) $fatal(1,"duplicate note-on source %0d",key_source);
          held[source_index]=1;held_note[source_index]=key_note;
        end else begin
          if(!held[source_index] || held_note[source_index]!=key_note) $fatal(1,"unmatched note-off %0d",key_source);
          held[source_index]=0;
        end
        event_count=event_count+1;
      end
      if(expr_update_valid && expr_update_ready) begin
        if(expr_update_mask!=2 || expr_update_gain_q1_11!=2048 || expr_update_vibrato_depth_cents!=0)
          $fatal(1,"invalid expression payload");
        last_bend=expr_update_bend_cents;expr_count=expr_count+1;
      end
      if(event_overflow) $fatal(1,"unexpected event overflow");
    end
    task await_ready;
      integer t;
      begin
        t=0;while(ready!=7 && t<200000) begin @(negedge clk);t=t+1;end
        if(ready!=7) $fatal(1,"initialization timeout ready=%b fault=%b last_error=%h",ready,fault,last_error);
      end
    endtask
    task await_events(input integer n);
      integer t;
      begin
        t=0;while(event_count<n && t<60000) begin @(negedge clk);t=t+1;end
        if(event_count!=n) $fatal(1,"expected %0d events got %0d held=%h",n,event_count,held);
      end
    endtask
    task await_bend(input integer bend);
      integer t;
      begin
        t=0;while(last_bend!=bend && t<40000) begin @(negedge clk);t=t+1;end
        if(last_bend!=bend) $fatal(1,"expected bend=%0d got %0d position=%0d",bend,last_bend,slider_position);
      end
    endtask
    initial begin
      for(k=0;k<25;k=k+1) key_map_flat[k*7 +:7]=60+k;
      repeat(5) @(negedge clk);resetn=1;
      // Other buses initialize while two buses have readback/NACK failures.
      wait(ready[2]);if(!fault[0] || !fault[1] || last_error[3:0]!=4 || last_error[7:4]!=1)
        $fatal(1,"failure isolation/diagnostic missing");
      mismatch0=0;nack1=0;await_ready();
      if(m0.mem[8'h5e]!=8'h8c || m1.mem[8'h5e]!=8'h88 || m2.mem[8'h5e]!=8'h89 || m0.mem[8'h77]!=0)
        $fatal(1,"ECR/GPIO configuration incorrect");
      if(m0.mem[8'h41]!=12 || m0.mem[8'h42]!=6 || m0.mem[8'h5d]!=8'h20)
        $fatal(1,"threshold/sample configuration incorrect");
      m0.set_touches(12'h0ff);m1.set_touches(12'h0ff);m2.set_touches(12'h1ff);
      await_events(25);if(held!=25'h1ffffff) $fatal(1,"25-key bitmap wrong");
      // Unused electrodes/proximity must not enter the key bitmap. OOR is
      // diagnostic only because this configuration explicitly disables auto-config.
      m0.mem[1]=8'h10;m1.mem[1]=8'h1f;m2.mem[1]=8'h1f;
      m1.mem[2]=8'haa;m1.mem[3]=8'hc5;
      irq_n=3'b010;repeat(8000) @(negedge clk);
      if(event_count!=25 || ready!=7) $fatal(1,"constant-low IRQ made duplicate event or stalled bus");
      if(oor_status[31:16]!=16'hc5aa || fault!=0) $fatal(1,"OOR telemetry or disabled-auto-config semantics incorrect");
      irq_n=3'b111;
      // Existing notes release with the original mapping under backpressure.
      key_ready=0;current_timbre=1;key_map_flat[0+:7]=90;
      m0.set_touches(0);m1.set_touches(0);m2.set_touches(0);
      repeat(15000) @(negedge clk);
      if(!key_valid || pending_events!=25) $fatal(1,"release batch not retained");
      repeat(100) @(negedge clk);key_ready=1;await_events(50);
      if(held!=0) $fatal(1,"release batch incomplete");
      m0.set_touches(12'h101);m0.set_delta(8,104);
      m1.set_touches(1);m2.set_touches(1);await_events(53);await_bend(-200);
      if(held_note[0]!=90) $fatal(1,"map did not apply to next press");
      // Slider stays in one touch region and changes analog position without IRQ.
      m0.set_delta(8,0);m0.set_delta(11,104);m0.set_touches(12'h801);
      await_bend(200);
      expr_update_ready=0;
      m0.set_delta(11,0);m0.set_delta(9,54);m0.set_delta(10,54);m0.set_touches(12'h601);
      repeat(8000) @(negedge clk);
      if(!expr_update_valid || expr_update_bend_cents!=0) $fatal(1,"slider midpoint failed");
      m0.set_delta(9,-80);m0.set_delta(10,-80);m0.set_touches(1);
      repeat(8000) @(negedge clk);expr_update_ready=1;await_bend(0);
      // Failed module releases only its own keys and keeps healthy modules held.
      nack0=1;await_events(54);
      if(!fault[0] || held!=25'h0010100) $fatal(1,"fault release crossed module boundary held=%h fault=%b",held,fault);
      nack0=0;
      repeat(60000) @(negedge clk);
      if(ready[0] || event_count!=54) $fatal(1,"held key retriggered after recovery");
      m0.set_touches(0);m0.set_delta(8,0);m0.set_delta(9,0);m0.set_delta(10,0);m0.set_delta(11,0);
      await_ready();m0.set_touches(1);await_events(55);
      // OVCF is extracted before software masks, locks until system reset.
      m0.mem[1]=8'h80;await_events(56);
      if(last_error[3:0]!=5 || !fault[0]) $fatal(1,"OVCF not latched");
      m0.mem[1]=0;repeat(15000) @(negedge clk);
      if(ready[0] || !fault[0] || event_count!=56) $fatal(1,"OVCF recovered without reset");
      m1.set_touches(0);m2.set_touches(0);await_events(58);
      if(held!=0) $fatal(1,"healthy keys stuck");
      m0.set_touches(0);resetn=0;repeat(5) @(negedge clk);
      if(key_valid || expr_update_valid || ready!=0 || fault!=0) $fatal(1,"reset did not clear front-end state");
      resetn=1;await_ready();
      m2.set_touches(9'h100);await_events(59);
      if(held!=25'h1000000 || held_note[24]!=84) $fatal(1,"post-reset key24 boundary mapping failed");
      m2.set_touches(0);await_events(60);
      $display("PASS tb_mpr121_frontend: verified init, mismatch/NACK isolation, 25 keys, retained releases/map, slider signed deltas, module fault recovery and OVCF lock");$finish;
    end
    initial begin #8000000;$fatal(1,"frontend watchdog");end
endmodule
