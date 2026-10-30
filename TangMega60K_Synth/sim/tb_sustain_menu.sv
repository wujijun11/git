`timescale 1ns/1ps
// 小时基验证导航；四页执行请求独立核对，忙/错误不伪装成功。
module tb_sustain_menu;
    reg clk=0;always #5 clk=~clk;
    reg rn=0,touch=0,fault=0,ready=1,busy=0,done=0;
    reg [7:0] error=0;
    reg [11:0] position=0;
    wire valid,wave,reset_expression,fx_write,pv;
    wire [1:0] kind,page,zone,expression_mode,fx_value,preview;
    wire [3:0] view;
    wire [7:0] displayed_error;
    wire [11:0] control_position;
    wire sustain_write,sustain_value;
    reg sustain_enabled=0;
    always @(posedge clk)if(!rn)sustain_enabled<=0;else if(sustain_write)sustain_enabled<=sustain_value;
    menu_hierarchy #(.SUSTAIN_ENABLE(1),.DEBOUNCE_CYCLES(3),.LONG_PRESS_CYCLES(9),.IDLE_CYCLES(10000)) dut(
        .clk(clk),.rst_n(rn),.touch_active(touch),.touch_fault(fault),.position(position),
        .request_valid(valid),.request_ready(ready),.request_kind(kind),.request_page(page),.request_zone(zone),
        .action_busy(busy),.action_done(done),.action_error(error),.display_error(displayed_error),
        .fx_write(fx_write),.fx_value(fx_value),.expression_reset(reset_expression),
        .sustain_write(sustain_write),.sustain_value(sustain_value),
        .view(view),.expression_mode(expression_mode),.waveform_view(wave),
        .preview_zone(preview),.position_valid(pv),.control_position(control_position));
    integer requests=0,fxs=0,resets=0,positions=0;
    reg stalled=0;reg [5:0] saved;
    always @(posedge clk)if(rn)begin
        if(stalled && (!valid || {kind,page,zone}!==saved))$fatal(1,"unstable menu payload under backpressure");
        stalled<=valid && !ready;saved<={kind,page,zone};
        if(valid && ready)requests=requests+1;
        if(fx_write)fxs=fxs+1;if(reset_expression)resets=resets+1;if(pv)positions=positions+1;
    end else stalled<=0;
    task cycles(input integer n);repeat(n)@(negedge clk);endtask
    task tap(input integer z);begin position=z*768+100;touch=1;cycles(7);touch=0;cycles(6);end endtask
    task hold_left;begin position=0;touch=1;cycles(18);touch=0;cycles(5);end endtask
    task root;begin
        if(wave)begin tap(2);if(view!=0)$fatal(1,"wake did not select continuous volume");end
        hold_left;if(view!=1 || wave)$fatal(1,"root missing");
    end endtask
    task complete(input integer status);begin error=status;done=1;cycles(1);done=0;cycles(3);end endtask
    task expect_request(input integer p,z);
        begin
            if(!valid || kind!=0 || page!=p || zone!=z)$fatal(1,"wrong request page=%d zone=%d",page,zone);
        end
    endtask

    reg [2:0] screen_page=0;reg [6:0] column=0;wire [7:0] pixels;
    oled_hierarchy_renderer #(.SUSTAIN_ENABLE(1)) renderer(.clk(clk),.screen_page(screen_page),.column(column),
        .view(view),.zone(preview),.expression_mode(expression_mode),.recording(1'b0),.playing(1'b0),
        .guide(1'b0),.busy(1'b0),.error(8'd0),.record_digits(16'd0),.control_digits(16'h0100),
        .control_negative(1'b0),.control_percent(8'd100),.sustain_enabled(sustain_enabled),.data(pixels));
    integer f,frame=0;
    task screen;
        begin
            for(integer page_no=0;page_no<8;page_no=page_no+1)
                for(integer x=0;x<128;x=x+1)begin
                    screen_page=page_no;column=x;cycles(2);
                    $fdisplay(f,"%0d,%0d,%0d,%0d,%0d,%0d,%0d",frame,view,sustain_enabled,preview,page_no,x,pixels);
                end
            frame=frame+1;
        end
    endtask
    initial begin
        f=$fopen("sim/audio_results/sustain_menu_pixels.csv","w");
        $fdisplay(f,"frame,view,sustain,zone,page,column,data");
        cycles(3);rn=1;cycles(3);
        root;tap(0);if(view!=2)$fatal(1,"sound view missing");screen;
        tap(3);if(view!=9)$fatal(1,"sustain view missing");screen;
        tap(1);if(!sustain_enabled || !wave)$fatal(1,"sustain ON did not return wave");
        root;tap(0);tap(3);screen;
        tap(2);if(view!=2)$fatal(1,"sustain back navigation");
        tap(3);tap(3);if(view!=1)$fatal(1,"sustain root navigation");
        tap(0);tap(3);tap(0);if(sustain_enabled || !wave)$fatal(1,"sustain OFF failed");
        root;tap(0);tap(3);cycles(10050);
        if(!wave)$fatal(1,"sustain menu idle10 policy");
        tap(2);if(view!=0 || expression_mode!=0)$fatal(1,"wave wake volume policy");
        $fclose(f);$display("SUSTAIN MENU PASS frames=%0d",frame);$finish;
    end
    initial begin #3000000;$fatal(1,"sustain menu timeout");end
endmodule
