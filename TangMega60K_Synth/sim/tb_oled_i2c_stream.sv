`timescale 1ns/1ps
// 独立字节接收器：128字节、供数反压、时钟延展、NACK、卡线超时及复位。
module tb_oled_i2c_stream;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg command = 0;
    wire ready, data_ready, done;
    wire [2:0] error;
    reg [7:0] length = 128;
    reg [7:0] source_index = 0;
    integer cycles = 0;
    wire source_valid = cycles % 11 > 3;
    wire [7:0] source_data = 8'ha5 ^ source_index;
    tri1 scl, sda;
    reg ack_low = 0, stretch = 0, stuck = 0;
    assign scl = stretch ? 1'b0 : 1'bz;
    assign sda = ack_low || stuck ? 1'b0 : 1'bz;
    oled_i2c_stream #(.CLK_HZ(1000000), .I2C_HZ(100000), .TIMEOUT_CYCLES(30000)) dut (
        .clk(clk), .resetn(rst_n), .cmd_valid(command), .cmd_ready(ready),
        .cmd_addr(7'h3c), .cmd_control(8'h40), .cmd_length(length),
        .data_valid(source_valid), .data_ready(data_ready), .data(source_data),
        .done(done), .error(error), .scl(scl), .sda(sda)
    );
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (rst_n && data_ready && source_valid) source_index <= source_index + 1'b1;
    end
    reg ignore_receiver = 0;
    integer nack_byte = -1;
    integer received = 0;
    integer wanted;
    reg [7:0] value;
    task receive_byte(input integer index);
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                @(posedge scl);
                value[k] = sda;
            end
            if (index == 0 && value !== 8'h78) $fatal(1, "stream address");
            if (index == 1 && value !== 8'h40) $fatal(1, "stream control");
            if (index >= 2 && value !== (8'ha5 ^ (index-2))) $fatal(1, "stream data %d", index);
            received = received + 1;
            @(negedge scl);
            ack_low = index != nack_byte;
            @(posedge scl);
            @(negedge scl);
            ack_low = 0;
        end
    endtask
    initial forever begin
        @(negedge sda);
        if (scl === 1 && rst_n && !ignore_receiver) begin
            for (wanted = 0; wanted < length+2; wanted = wanted + 1) begin
                receive_byte(wanted);
                if (wanted == nack_byte) wanted = length+2;
            end
        end
    end
    task start(input integer size);
        begin
            @(negedge clk);
            source_index = 0;
            length = size;
            command = 1;
            do @(posedge clk); while (!ready);
            @(negedge clk);
            command = 0;
        end
    endtask
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        start(128);
        wait (dut.state == dut.TX_LOW);
        @(negedge clk);
        stretch = 1;
        repeat (20) @(negedge clk);
        stretch = 0;
        wait (done);
        @(negedge clk);
        if (error != 0 || received != 130 || source_index != 128) $fatal(1, "stream completion");
        nack_byte = 3;
        start(8);
        wait (done);
        @(negedge clk);
        if (error != 1 || scl !== 1 || sda !== 1) $fatal(1, "NACK stop");
        nack_byte = -1;
        ignore_receiver = 1;
        stuck = 1;
        start(1);
        wait (done);
        @(negedge clk);
        if (error != 3 || scl !== 1) $fatal(1, "stuck SDA timeout");
        stuck = 0;
        repeat (5) @(negedge clk);
        ignore_receiver = 0;
        start(1);
        wait (done);
        @(negedge clk);
        if (error != 0) $fatal(1, "bus recovery after fault");
        rst_n = 0;
        repeat (3) @(negedge clk);
        if (scl !== 1 || sda !== 1 || !ready) $fatal(1, "stream reset");
        $display("OLED I2C STREAM PASS 128 bytes, source stalls, stretch, NACK, stuck line and recovery");
        $finish;
    end
    initial begin
        #2000000;
        $fatal(1, "stream timeout");
    end
endmodule
