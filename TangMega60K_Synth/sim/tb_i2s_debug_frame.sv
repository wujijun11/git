`timescale 1ns/1ps
// Observe the added held-frame probe against an independent serial receiver.
// Stimulus may target a boundary, but decoding never reads DUT shifts/index.
module i2s_debug_case #(parameter HALF_DIV=8)(output reg finished=0);
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg sample_valid=0;reg signed[23:0] sample_left=0,sample_right=0;
 wire ready,bclk,ws,dout,tick,underrun_pulse,underrun_sticky;
 wire[1:0]level;wire[31:0]underruns;wire signed[23:0]debug_left;
 i2s_tx #(.BCLK_HALF_DIV(HALF_DIV)) dut(.clk(clk),.rst_n(rst_n),
 .sample_valid(sample_valid),.sample_ready(ready),.sample_left(sample_left),
 .sample_right(sample_right),.i2s_bclk(bclk),.i2s_lrclk(ws),.i2s_data(dout),
 .frame_tick(tick),.fifo_level(level),.underrun_pulse(underrun_pulse),
 .underrun_sticky(underrun_sticky),.underrun_count(underruns),.debug_frame_left(debug_left));
 reg[47:0]queue[0:1023];integer written=0,consumed=0;
 reg[47:0]expected=0;reg started=0;integer expected_underruns=0;
 integer total_frames=0,epoch_frames=0,epochs=0;
 integer priming_hits=0,pop_hits=0,bypass_hits=0,underrun_hits=0,full_exchanges=0;
 integer input_stalls=0,hold_checks=0,reset_checks=0;
 reg missing=0;reg[23:0]before_debug;
 reg boundary;integer csv,k;
 reg prior_input_stall=0;reg[47:0]held_input;
 always @(posedge clk) begin
  if(rst_n)begin
   if(prior_input_stall&&(!sample_valid||{sample_left,sample_right}!==held_input))
    $fatal(1,"DIV%0d source changed stalled sample",HALF_DIV);
   prior_input_stall=sample_valid&&!ready;held_input={sample_left,sample_right};
   if(sample_valid&&!ready)input_stalls=input_stalls+1;
   if(sample_valid&&ready)begin
    if(written>=1024)$fatal(1,"scoreboard overflow");
    queue[written]={sample_left,sample_right};written=written+1;
    if(level==2)full_exchanges=full_exchanges+1;
   end
   boundary=dut.start_frame;before_debug=debug_left;
   if(boundary)begin
    if(dut.pop_sample)pop_hits=pop_hits+1;
    else if(dut.bypass_sample)bypass_hits=bypass_hits+1;
    else if(dut.playback_started)underrun_hits=underrun_hits+1;
    else priming_hits=priming_hits+1;
   end
   #0.001;
   if(rst_n&&!boundary)begin
    if(debug_left!==before_debug)$fatal(1,"DIV%0d debug changed during serialization",HALF_DIV);
    hold_checks=hold_checks+1;
   end
  end
 end
 always @(negedge rst_n)begin
  written=0;consumed=0;expected=0;started=0;expected_underruns=0;epoch_frames=0;
  missing=0;prior_input_stall=0;
  #0.002;
  if(debug_left!==0||level!==0||ready!==0||underruns!==0||underrun_sticky!==0)
   $fatal(1,"DIV%0d reset failed",HALF_DIV);
  reset_checks=reset_checks+1;
 end
 // Accepted same-edge input is in the transaction queue before this WS edge.
 always @(negedge ws)if(rst_n)begin
  #0.001;
  missing=started&&(written==consumed);
  if(consumed<written)begin
   expected=queue[consumed];consumed=consumed+1;started=1;
  end else begin
   expected=0;if(started)expected_underruns=expected_underruns+1;
  end
  if(debug_left!==expected[47:24])
   $fatal(1,"DIV%0d boundary debug %h expected %h",HALF_DIV,debug_left,expected[47:24]);
 end
 always @(negedge clk)begin
  #0.01;
  if(rst_n)begin
   if(level!==(written-consumed)||underruns!==expected_underruns||
    underrun_sticky!==(expected_underruns!=0)||underrun_pulse!==(tick&&missing))
    $fatal(1,"DIV%0d FIFO/underrun contract mismatch level%0d q%0d underrun%0d exp%0d",HALF_DIV,level,written-consumed,underruns,expected_underruns);
  end
 end
 // Independent Philips-I2S receiver. Only physical BCLK/WS/DATA are decoded.
 reg locked=0,previous_ws=1;integer slot_bit=0;
 reg[23:0]word=0,left_word=0,frame_probe=0;
 realtime last_rise=0;
 always @(posedge bclk or negedge rst_n)begin
  if(!rst_n)begin
   locked=0;previous_ws=1;slot_bit=0;word=0;left_word=0;frame_probe=0;last_rise=0;
  end else begin
   if(last_rise!=0&&($realtime-last_rise!=20*HALF_DIV))$fatal(1,"BCLK period");
   last_rise=$realtime;
   if(ws!==previous_ws)begin
    if(locked&&slot_bit!=31)$fatal(1,"DIV%0d not32bit slot",HALF_DIV);
    locked=1;slot_bit=0;word=0;previous_ws=ws;
    if(!ws)frame_probe=debug_left;
   end else if(locked)slot_bit=slot_bit+1;
   if(locked)begin
    if(slot_bit>31)$fatal(1,"missing WS");
    if((slot_bit==0||slot_bit>24)&&dout!==0)$fatal(1,"delay/pad must0");
    if(slot_bit>=1&&slot_bit<=24)begin
     word={word[22:0],dout};
     if(slot_bit==24)begin
      if(!ws)begin
       left_word=word;
       if(word!==frame_probe||word!==debug_left||word!==expected[47:24])
        $fatal(1,"DIV%0d serial-left/debug mismatch decoded%h probe%h exp%h",HALF_DIV,word,frame_probe,expected[47:24]);
      end else if({left_word,word}!==expected)$fatal(1,"serial stereo mismatch");
     end
    end
    if(ws&&slot_bit==31&&!finished)begin
     total_frames=total_frames+1;epoch_frames=epoch_frames+1;
     $fdisplay(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d",epochs,total_frames,$signed(expected[47:24]),$signed(frame_probe),$signed(left_word),$signed(word),underruns);
    end
   end
  end
 end
 always @(ws or dout)if(rst_n&&bclk!==0)$fatal(1,"changed serial with BCLK high");
 task send(input[23:0]l,r);
  begin
   @(negedge clk);sample_valid=1;sample_left=l;sample_right=r;
   do @(posedge clk);while(!ready);
   @(negedge clk);sample_valid=0;
  end
 endtask
 task wait_frames(input integer n);
  integer target;
  begin target=epoch_frames+n;wait(epoch_frames>=target);@(negedge clk);end
 endtask
 task reset_case;
  begin
   @(negedge clk);rst_n=0;sample_valid=0;epochs=epochs+1;
   repeat(4)@(negedge clk);rst_n=1;
  end
 endtask
 task bypass(input[23:0]l,r);
  begin
   if(level!=0)$fatal(1,"bypass stimulus requires empty FIFO");
   @(negedge clk);while(!dut.start_frame)@(negedge clk);
   sample_left=l;sample_right=r;sample_valid=1;
   @(posedge clk);if(!ready)$fatal(1,"bypass not ready");
   @(negedge clk);sample_valid=0;
  end
 endtask
 initial begin
  csv=$fopen($sformatf("debug_frame_div%0d.csv",HALF_DIV),"w");
  if(!csv)$fatal(1,"CSV open");
  $fdisplay(csv,"epoch,frame,expected_left,debug_left,decoded_left,decoded_right,underruns");
  reset_case();wait_frames(4);
  if(underruns!=0||debug_left!=0)$fatal(1,"priming not silent");
  bypass(24'h800000,24'h7fffff);wait_frames(1);
  // Fill before the next boundary and maintain pressure through full exchanges.
  for(k=0;k<24;k=k+1)send(24'h123457+(k*24'h010101),24'hFEDCBA-(k*24'h001122));
  wait_frames(5);
  if(underruns==0||!underrun_sticky||debug_left!=0)$fatal(1,"missing underrun silence");
  bypass(24'hffffff,24'h000001);wait_frames(1);
  send(24'h010203,24'hABCDEF);send(24'h112233,24'hCCDDEE);
  // Reset partway through a nonzero word, clear queued/sticky state.
  wait(!ws);repeat(9*2*HALF_DIV)@(negedge clk);reset_case();
  wait_frames(3);if(underruns!=0||debug_left!=0)$fatal(1,"postreset priming");
  send(24'h400001,24'hc00002);wait_frames(3);
  if(priming_hits<5||pop_hits<20||bypass_hits<2||underrun_hits<2||
   full_exchanges<5||input_stalls<5||hold_checks<100||reset_checks<1||epochs!=2)
   $fatal(1,"coverage insufficient priming%0d pop%0d bypass%0d underrun%0d full%0d stalls%0d holds%0d reset%0d epoch%0d",priming_hits,pop_hits,bypass_hits,underrun_hits,full_exchanges,input_stalls,hold_checks,reset_checks,epochs);
  $fclose(csv);
  $display("I2S DEBUG CASE PASS div=%0d frames=%0d priming=%0d pop=%0d bypass=%0d underrun=%0d full_exchange=%0d stalls=%0d holds=%0d reset=%0d",HALF_DIV,total_frames,priming_hits,pop_hits,bypass_hits,underrun_hits,full_exchanges,input_stalls,hold_checks,reset_checks);
  finished=1;
 end
endmodule
module tb_i2s_debug_frame;
 wire a,b;
 i2s_debug_case #(.HALF_DIV(1)) c1(a);
 i2s_debug_case #(.HALF_DIV(8)) c8(b);
 initial begin wait(a&&b);$display("I2S DEBUG FRAME PASSED");$finish;end
 initial begin #10000000;$fatal(1,"debug frame watchdog");end
endmodule
