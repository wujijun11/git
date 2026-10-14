`timescale 1ns/1ps
module tb_full_control;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=0,cv=0,rr=0,er=0,xr=0,pr=0;
    reg [7:0] seq=0,op=0,ps=0; reg [79:0] p=0;
    wire cr,rv,ev,xv,pv,pan; wire [7:0] rs,ro,po;
    wire [79:0] rp,pp;wire eon;wire [5:0] es;wire [6:0] en,evel;wire [1:0] et,ct,fx;
    wire [2:0] xm;wire [11:0] xg;wire signed [12:0] xb;wire [7:0] xvib;
    wire [174:0] km;wire [15:0] ri;
    integer events=0,expressions=0,perfs=0,panics=0;
    remote_command_router dut(.clk(clk),.rst_n(rst_n),.cmd_valid(cv),.cmd_ready(cr),
        .cmd_seq(seq),.cmd_opcode(op),.cmd_payload(p),.rsp_valid(rv),.rsp_ready(rr),
        .rsp_seq(rs),.rsp_opcode(ro),.rsp_payload(rp),.event_valid(ev),.event_ready(er),
        .event_on(eon),.event_source(es),.event_note(en),.event_velocity(evel),.event_timbre(et),
        .expr_valid(xv),.expr_ready(xr),.expr_mask(xm),.expr_gain(xg),.expr_bend(xb),.expr_vibrato(xvib),
        .performance_valid(pv),.performance_pending(),.performance_ready(pr),.performance_opcode(po),.performance_payload(pp),
        .performance_status(ps),.key_map_flat(km),.current_timbre(ct),.effect_mode(fx),.panic_pulse(pan),
        .active_count(7'd32),.playing(1'b1),.recording(1'b0),.guide_active(1'b1),.overflow_sticky(1'b0),
        .record_count(16'd1024),.score_position(16'd12),.underrun_count(32'd0),
        .record_read_index(ri),.record_read_valid(ri==16'd3),.record_read_payload(80'h1234567890abcdef1234));
    always @(posedge clk) if(rst_n) begin
        if(ev && er) events<=events+1;
        if(xv && xr) expressions<=expressions+1;
        if(pv && pr) perfs<=perfs+1;
        if(pan) panics<=panics+1;
    end
    task send(input [7:0] s,input [7:0] o,input [79:0] data);
        begin @(negedge clk);while(!cr)@(negedge clk);seq=s;op=o;p=data;cv=1;
            @(negedge clk);cv=0;end
    endtask
    task response(input [7:0] opcode,input [79:0] payload);
        begin while(!rv)@(negedge clk);
            if(ro!==opcode || rp!==payload || rs!==seq) $fatal(1,"response mismatch op=%h p=%h",ro,rp);
            repeat(3)begin @(negedge clk);if(!rv || rp!==payload)$fatal(1,"stalled response changed");end
            rr=1;@(negedge clk);rr=0;end
    endtask
    reg [79:0] data;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(integer k=0;k<25;k=k+1)if(km[k*7+:7]!=60+k)$fatal(1,"default map");
        data=0;data[7:0]=7;data[15:8]=69;data[23:16]=100;data[31:24]=2;data[39:32]=1;
        send(0,1,data);repeat(10)@(negedge clk);
        if(!ev || es!=63 || en!=69 || !eon || evel!=100)$fatal(1,"note stall fields");
        er=1;@(negedge clk);er=0;response(8'h80,80'h00000000000000000001);
        send(0,1,data);response(8'h80,80'h00000000000000000001);
        if(events!=1)$fatal(1,"duplicate repeated note");
        data[15:8]=70;send(0,1,data);response(8'h80,80'h00000000000000000101);
        if(events!=1)$fatal(1,"conflicting sequence accepted");
        data[15:8]=128;send(1,1,data);response(8'h80,80'h00000000000000000101);
        data=0;data[7:0]=7;data[23:8]=1024;data[39:24]=-200;data[47:40]=25;
        send(2,2,data);repeat(5)@(negedge clk);
        if(!xv || xb!=-200 || xg!=1024 || xm!=7 || xvib!=25)$fatal(1,"expression");
        xr=1;@(negedge clk);xr=0;response(8'h80,80'h00000000000000000002);
        send(3,3,80'h0301);response(8'h80,80'h00000000000000000003);if(fx!=3)$fatal(1,"fx config");
        send(4,5,80'h4818);response(8'h80,80'h00000000000000000005);if(km[24*7+:7]!=72)$fatal(1,"map");
        send(5,4,80'h05);repeat(4)@(negedge clk);if(!pv || po!=4 || pp!=5)$fatal(1,"perf stall");
        pr=1;@(negedge clk);pr=0;response(8'h80,80'h00000000000000000004);
        if(panics!=1 || perfs!=1)$fatal(1,"panic handshake");
        send(6,8,0);response(8'h80,80'h00000000000000000008);
        response(8'h81,{16'd12,32'd0,16'd1024,8'd5,8'd32});
        send(7,8,80'h0301);response(8'h80,80'h00000000000000000008);
        response(8'h82,80'h1234567890abcdef1234);
        send(7,8,80'h0301);response(8'h80,80'h00000000000000000008);
        response(8'h82,80'h1234567890abcdef1234);
        send(255,8'hfe,0);response(8'h80,80'h000000000000000003fe);
        send(0,3,0);response(8'h80,80'h00000000000000000003);if(ct!=0)$fatal(1,"wrap");
        $display("FULL CONTROL ROUTER PASS");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule

module tb_expression_merge;
    reg clk=0;always #5 clk=~clk;reg rn=0,av=0,bv=0,ready=0;
    wire ar,br,ov;wire [11:0] g;wire signed [12:0] b;wire [7:0] v;
    expression_merge dut(.clk(clk),.rst_n(rn),.a_valid(av),.a_ready(ar),.a_mask(3'd2),
        .a_gain(12'd0),.a_bend(-13'sd250),.a_vibrato(8'd0),.b_valid(bv),.b_ready(br),
        .b_mask(3'd5),.b_gain(12'd1024),.b_bend(13'd0),.b_vibrato(8'd50),
        .out_valid(ov),.out_ready(ready),.out_gain(g),.out_bend(b),.out_vibrato(v));
    initial begin
        repeat(3)@(negedge clk);rn=1;bv=1;@(negedge clk);bv=0;
        if(!ov || g!=1024 || v!=50)$fatal(1,"phone expr");
        av=1;repeat(3)begin @(negedge clk);if(ar || b!=0)$fatal(1,"stall overwrite");end
        ready=1;@(negedge clk);av=0;
        if(g!=1024 || v!=50 || b!=-250)$fatal(1,"slider lost phone fields");
        av=1;bv=1;#1;if(!br)$fatal(1,"arbitration fairness");
        @(negedge clk);if(!ar)$fatal(1,"arbitration fairness next");
        $display("EXPRESSION MERGE PASS");$finish;
    end
endmodule

module tb_note_arbiter;
    reg clk=0;always #5 clk=~clk;reg rn=0,ready=0;reg [3:0] iv=0;
    reg [91:0] data={23'd4,23'd3,23'd2,23'd1};wire [3:0] ir;wire ov;wire [22:0] p;wire [1:0] s;
    note_arbiter dut(.clk(clk),.rst_n(rn),.in_valid(iv),.in_ready(ir),.in_payload(data),
        .out_valid(ov),.out_ready(ready),.out_payload(p),.selected(s));
    initial begin
        repeat(2)@(negedge clk);rn=1;iv=4'b1000;@(negedge clk);iv=4'b1111;
        repeat(4)begin @(negedge clk);if(p!=4 || s!=3 || ir!=0)$fatal(1,"grant moved while stalled");end
        ready=1;@(negedge clk);if(s!=0 || p!=1)$fatal(1,"round robin");
        @(negedge clk);if(s!=1 || p!=2)$fatal(1,"round robin2");
        @(negedge clk);if(s!=2 || p!=3)$fatal(1,"round robin3");
        $display("NOTE ARBITER PASS");$finish;
    end
endmodule
