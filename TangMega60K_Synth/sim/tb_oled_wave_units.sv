`timescale 1ns/1ps
// 独立整数参考验证采样区间、同步读、整帧快照、静音及显示缩放饱和。
module tb_oled_wave_capture;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg valid = 0;
    reg signed [23:0] sample = 0;
    reg snapshot = 0;
    reg [6:0] column = 0;
    reg [2:0] page = 0;
    wire [11:0] bounds;
    wire [7:0] pixels;
    oled_wave_capture dut (
        .clk(clk), .rst_n(rst_n), .sample_valid(valid), .sample(sample),
        .frame_snapshot(snapshot), .read_column(column), .read_bounds(bounds)
    );
    oled_wave_renderer renderer (
        .clk(clk), .screen_page(page), .column(column), .bounds(bounds), .data(pixels)
    );
    function integer triangle(input integer n);
        begin
            triangle = n % 64 < 32 ? n % 32 - 16 : 16 - n % 32;
        end
    endfunction
    task push(input integer value);
        begin
            @(negedge clk);
            sample = value;
            valid = 1;
            @(negedge clk);
            valid = 0;
        end
    endtask
    task commit_frame;
        begin
            @(negedge clk);
            snapshot = 1;
            @(negedge clk);
            snapshot = 0;
            repeat (3) @(negedge clk);
        end
    endtask
    integer n, x, p, b, first, top, bottom, y, checks = 0;
    reg [7:0] expected;
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (3) @(negedge clk);
        if (bounds !== {6'd24, 6'd24}) $fatal(1, "initial RAM exposed");
        for (n = 0; n < 512; n = n + 1)
            push(triangle(n) * 32768);
        if (bounds !== {6'd24, 6'd24}) $fatal(1, "uncommitted frame visible");
        commit_frame;
        for (x = 0; x < 128; x = x + 1) begin
            first = x == 0 ? 0 : x * 4 - 1;
            top = 47;
            bottom = 0;
            for (n = first; n < x * 4 + 4; n = n + 1) begin
                y = 24 - triangle(n);
                if (y < top) top = y;
                if (y > bottom) bottom = y;
            end
            column = x;
            for (p = 0; p < 8; p = p + 1) begin
                page = p;
                repeat (2) @(negedge clk);
                if (bounds !== ((top << 6) | bottom)) $fatal(1, "column bounds %d", x);
                expected = 0;
                for (b = 0; b < 8; b = b + 1) begin
                    y = (p - 2) * 8 + b;
                    if (p >= 2 && ((y >= top && y <= bottom) || (y == 24 && x % 8 == 0)))
                        expected[b] = 1;
                end
                if (pixels !== expected) $fatal(1, "pixel p=%d x=%d", p, x);
                checks = checks + 1;
            end
        end
        // 下一帧捕获期间，当前帧保持不动。
        column = 0;
        repeat (3) @(negedge clk);
        for (n = 0; n < 512; n = n + 1) begin
            push(0);
            if (bounds !== {6'd37, 6'd40}) $fatal(1, "front buffer torn");
        end
        commit_frame;
        repeat (3) @(negedge clk);
        if (bounds !== {6'd24, 6'd24}) $fatal(1, "silence not flat");
        for (n = 0; n < 512; n = n + 1)
            push(n % 2 ? 8388607 : -8388608);
        commit_frame;
        repeat (3) @(negedge clk);
        if (bounds !== {6'd2, 6'd46}) $fatal(1, "visual full-scale clamp failed");
        rst_n = 0;
        repeat (3) @(negedge clk);
        if (bounds !== {6'd24, 6'd24}) $fatal(1, "stale RAM after reset");
        $display("OLED WAVE CAPTURE PASS %0d pixel bytes, real ranges, frame coherence, silence, clip and reset", checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "capture timeout");
    end
endmodule

// 总菜单/子页面都保持原状态，由显示覆盖层统一处理空闲，不吞掉唤醒手势。
module tb_oled_idle_menu;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg touch = 0;
    reg [11:0] position = 0;
    reg busy = 0;
    reg [7:0] error = 0;
    wire main_menu, performance, request_valid, wave;
    wire [1:0] page, zone;
    slider_menu_controller #(.CLK_HZ(100), .DEBOUNCE_CYCLES(2), .LONG_PRESS_CYCLES(8),
        .PERFORMANCE_ENABLE(1), .ROOT_IDLE_CYCLES(0)) menu (
        .clk(clk), .rst_n(rst_n), .touch_active(touch), .touch_fault(1'b0), .position(position),
        .request_ready(1'b1), .request_valid(request_valid), .main_menu(main_menu),
        .page(page), .selected_zone(zone), .action_busy(busy), .performance_mode(performance)
    );
    oled_idle_view #(.IDLE_CYCLES(16)) idle (
        .clk(clk), .rst_n(rst_n), .touch_active(touch), .busy(busy), .error(error),
        .ui_signature({main_menu, page, zone, performance, 8'd100}), .waveform_view(wave)
    );
    task gesture(input integer point, hold_cycles);
        begin
            @(negedge clk);
            touch = 1;
            position = point;
            repeat (hold_cycles) @(negedge clk);
            touch = 0;
            repeat (3) @(negedge clk);
            if (wave) $fatal(1, "touch did not restore UI");
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        rst_n = 1;
        repeat (30) @(negedge clk);
        if (!wave || !performance) $fatal(1, "initial idle view");
        gesture(0, 15);
        if (!main_menu || performance) $fatal(1, "long press root");
        repeat (80) @(negedge clk);
        if (!wave || !main_menu || performance) $fatal(1, "root timed back to volume");
        gesture(1000, 5);
        if (main_menu || page != 1 || performance) $fatal(1, "wake selection lost");
        repeat (80) @(negedge clk);
        if (!wave || main_menu || page != 1 || performance) $fatal(1, "submenu state changed on idle");
        gesture(0, 15);
        if (!main_menu) $fatal(1, "long press return lost");
        gesture(2700, 5);
        if (main_menu || page != 3) $fatal(1, "score page selection lost");
        repeat (80) @(negedge clk);
        if (!wave || page != 3) $fatal(1, "score idle view");
        busy = 1;
        repeat (3) @(negedge clk);
        if (wave) $fatal(1, "busy UI hidden");
        busy = 0;
        error = 1;
        repeat (30) @(negedge clk);
        if (wave) $fatal(1, "error UI hidden");
        error = 0;
        repeat (30) @(negedge clk);
        if (!wave) $fatal(1, "idle recovery failed");
        $display("OLED IDLE MENU PASS root/submenu preserve, wake gestures, long press and priority");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1, "idle menu timeout");
    end
endmodule
