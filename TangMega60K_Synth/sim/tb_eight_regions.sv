`timescale 1ns/1ps
module tb_eight_regions;
    reg clk=0,rst_n=0,start=0,active=1;
    always #10 clk=~clk;
    reg [5:0] voice=0;
    reg [19:0] age=0;
    reg [31:0] ftw=0,base_ftw=0;
    wire v0,v1;
    wire signed [31:0] l0,r0,l1,r1;
    reg test_passed=0;
    polar_lane #(.LANE(0)) a(clk,rst_n,start,voice,active,age,ftw,base_ftw,v0,l0,r0);
    polar_lane #(.LANE(1)) b(clk,rst_n,start,voice,active,age,ftw,base_ftw,v1,l1,r1);
    reg [31:0] root_ftw[0:3];
    integer notes[0:3];
    integer n,k,region,cycles,fd,count;
    reg [194:0] saved;
    task frame(input integer id,input integer index);
        begin
            @(negedge clk); voice=id; age=index; start=1;
            @(negedge clk); start=0; cycles=0;
            while(!v0 || !v1) begin
                @(negedge clk); cycles=cycles+1;
                if(cycles>10) $fatal(1,"eight-region latency increased");
            end
            if(cycles!=10 || (^{l0,r0,l1,r1})===1'bx)
                $fatal(1,"invalid eight-region output");
            if(l0+l1>32767 || l0+l1 < -32768 || r0+r1>32767 || r0+r1 < -32768)
                $fatal(1,"per-voice piano clipping");
            @(negedge clk);
        end
    endtask
    initial begin
        root_ftw[0]=23409859; root_ftw[1]=39370534;
        root_ftw[2]=46819719; root_ftw[3]=93639437;
        notes[0]=60; notes[1]=69; notes[2]=72; notes[3]=84;
        repeat(3) @(negedge clk); rst_n=1;
        for(region=0;region<4;region=region+1) begin
            base_ftw=root_ftw[region]; ftw=base_ftw;
            fd=$fopen($sformatf("sim/eight_results/lane_%0d.csv",notes[region]),"w");
            if(!fd) $fatal(1,"cannot open lane PCM");
            $fdisplay(fd,"sample,left,right");
            count=region==1 ? 576100 : 96000;
            for(n=0;n<count;n=n+1) begin
                frame(region,n);
                $fdisplay(fd,"%0d,%0d,%0d",n,l0+l1,r0+r1);
                if(a.states[region*4][174:173]!==region[1:0])
                    $fatal(1,"incorrect latched region");
            end
            $fclose(fd);
            if(region==1 && (l0+l1!=0 || r0+r1!=0))
                $fatal(1,"natural tail must reach zero");
        end
        // Each voice has private region, pointer, envelope and phase states.
        for(k=0;k<64;k=k+1) begin
            base_ftw=root_ftw[k%4]; ftw=base_ftw; frame(k,0); frame(k,1);
        end
        saved=a.states[0];
        for(k=1;k<64;k=k+1) begin
            base_ftw=root_ftw[k%4]; ftw=base_ftw; frame(k,2);
            if(a.states[k*4][174:173]!==k[1:0]) $fatal(1,"cross-voice region leak");
        end
        if(a.states[0]!==saved) $fatal(1,"cross-voice state overwrite");
        // Live bend and even a changed base must not switch the latched bank
        // mid-note. A new age-zero attack deliberately selects a fresh bank.
        base_ftw=root_ftw[3]; ftw=root_ftw[3]; frame(0,2);
        if(a.states[0][174:173]!==2'd0) $fatal(1,"mid-note region changed");
        frame(0,0);
        if(a.states[0][174:173]!==2'd3) $fatal(1,"new attack did not select region");
        saved=a.states[0]; repeat(50) @(negedge clk);
        if(a.states[0]!==saved) $fatal(1,"state advanced without start");
        start=1; @(negedge clk); start=0; rst_n=0;
        repeat(3) @(negedge clk); rst_n=1; frame(0,0);
        if(l0+l1!=0 || r0+r1!=0) $fatal(1,"reset attack not zero");
        $display("EIGHT REGIONS PASSED: four regions, A4 complete decay, 64 independent states, latched bank, reset, 10 clocks");
        test_passed=1; $finish;
    end
    initial begin #1000000000; $fatal(1,"eight-region timeout"); end
endmodule
