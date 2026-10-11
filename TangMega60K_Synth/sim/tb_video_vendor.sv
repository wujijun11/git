`timescale 1ps/1ps
module tb_video_vendor;
    reg clk_50=0;always #10000 clk_50=~clk_50;
    reg reset=1;wire clk_pixel,clk_serial,locked;
    video_clocking clocks(.clk_50(clk_50),.reset(reset),.clk_pixel(clk_pixel),.clk_serial(clk_serial),.locked(locked));
    GSR GSR(.GSRI(1'b1));
    reg de=0,hsync=0,vsync=0;reg [7:0] red=8'hc3,green=8'h5a,blue=8'h19;
    wire tmds_clk_p,tmds_clk_n;wire [2:0] tmds_data_p,tmds_data_n;
    // Match the board: asynchronously assert on lock loss, then release after
    // two pixel-clock edges. This deliberately changes reset on a PCLK edge.
    reg [1:0] video_ready=0;
    always @(posedge clk_pixel or negedge locked)begin
        if(!locked)video_ready<=0;else video_ready<={video_ready[0],!reset};
    end
    wire video_reset=!video_ready[1];
    video_tmds_tx tx(.clk_pixel(clk_pixel),.clk_serial(clk_serial),.reset(video_reset),.red(red),.green(green),.blue(blue),.hsync(hsync),.vsync(vsync),.de(de),.tmds_clk_p(tmds_clk_p),.tmds_clk_n(tmds_clk_n),.tmds_data_p(tmds_data_p),.tmds_data_n(tmds_data_n));
    reg [9:0] words[0:2];reg [7:0] q,decoded;integer b,k;
    time t0,elapsed;integer serial_edges=0;
    reg stream_active=0;reg [7:0] stream_seq=0,previous_seq,stream_red;
    always @(negedge clk_pixel)if(stream_active)begin
        red<=stream_seq;green<=stream_seq^8'h5a;blue<=stream_seq+8'h33;
        stream_seq<=stream_seq+1'b1;
    end
    always @(posedge clk_serial)if(locked)serial_edges=serial_edges+1;
    task get_word;
        begin
            @(negedge tmds_clk_p);#1000;
            for(b=0;b<10;b=b+1)begin
                for(k=0;k<3;k=k+1)words[k][b]=tmds_data_p[k];
                if(tmds_data_n!==~tmds_data_p||tmds_clk_n!==~tmds_clk_p)$fatal(1,"differential polarity");
                if(b<9)#4000;
            end
        end
    endtask
    task expect_rgb(input [7:0] rv,gv,bv);
        reg [7:0] expected;integer lane,j;
        begin get_word();for(lane=0;lane<3;lane=lane+1)begin
            q=words[lane][9]?~words[lane][7:0]:words[lane][7:0];decoded[0]=q[0];
            for(j=1;j<8;j=j+1)decoded[j]=q[j]^q[j-1]^!words[lane][8];
            expected=lane==2?rv:(lane==1?gv:bv);
            if(decoded!==expected)$fatal(1,"vendor ODDR lane%0d decoded%h expected%h word%b",lane,decoded,expected,words[lane]);
        end end
    endtask
    initial begin
        repeat(8)@(posedge clk_50);reset=0;wait(locked);
        if($time<2000000000)$fatal(1,"video lock was not held stable 2ms");
        @(posedge clk_pixel);t0=$time;serial_edges=0;
        repeat(100)@(posedge clk_pixel);elapsed=$time-t0;#1;
        if(elapsed!=4000000||serial_edges<499||serial_edges>501)$fatal(1,"PLL25/125 periods %0d edges %0d",elapsed,serial_edges);
        repeat(20)@(posedge clk_pixel);get_word();
        for(k=0;k<3;k=k+1)if(words[k]!==10'b1101010100)$fatal(1,"vendor serialized control %b",words[k]);
        @(negedge clk_pixel);de=1;repeat(12)@(posedge clk_pixel);
        repeat(16)expect_rgb(8'hc3,8'h5a,8'h19);
        // Changing every pixel detects word duplication/drop and lane phase
        // errors which static-color tests would not expose.
        stream_active=1;repeat(12)@(posedge clk_pixel);
        for(integer sample=0;sample<128;sample=sample+1)begin
            get_word();
            for(integer lane=2;lane>=0;lane=lane-1)begin
                q=words[lane][9]?~words[lane][7:0]:words[lane][7:0];decoded[0]=q[0];
                for(integer bitn=1;bitn<8;bitn=bitn+1)decoded[bitn]=q[bitn]^q[bitn-1]^!words[lane][8];
                if(lane==2)stream_red=decoded;
                else if(lane==1&&decoded!==(stream_red^8'h5a))$fatal(1,"dynamic green lane phase");
                else if(lane==0&&decoded!==(stream_red+8'h33))$fatal(1,"dynamic blue lane phase");
            end
            if(sample>0&&stream_red!==previous_seq+8'd1)$fatal(1,"dynamic ODDR dropped/repeated pixel");
            previous_seq=stream_red;
        end
        stream_active=0;
        @(negedge clk_pixel);de=0;hsync=1;vsync=1;repeat(12)@(posedge clk_pixel);get_word();
        if(words[0]!==10'b1010101011||words[1]!==10'b1101010100||words[2]!==10'b1101010100)$fatal(1,"sync belongs only to blue lane");
        reset=1;#1000;if(locked)$fatal(1,"reset lock gating");
        repeat(8)@(posedge clk_50);reset=0;wait(locked);repeat(20)@(posedge clk_pixel);get_word();
        if(words[0]!==10'b1010101011)$fatal(1,"serializer did not recover after reset");
        $display("ALL VIDEO VENDOR TESTS PASSED (actual Gowin PLLA25/125MHz,ODDR bit order,TLVDS polarity,reset)");$finish;
    end
    initial begin #10000000000;$fatal(1,"video PLL/serializer timeout");end
endmodule
