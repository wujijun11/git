// Tang Mega 60K NEO Dock: 50 MHz, three active-low 1.5 V keys,
// one WS2812 (GRB). No audio or external connector is driven.
module board_bringup_top #(
    parameter integer DEBOUNCE_CYCLES = 500000,
    parameter integer HALF_SECOND_CYCLES = 25000000,
    parameter integer STATUS_MODE = 0
) (
    input wire sys_clk,
    input wire [2:0] key_n,
    output reg rgb_data = 0,
    output wire pa_disable,
    output wire board_ready,
    output wire [2:0] keys_pressed,
    input wire [23:0] status_grb
);
    assign pa_disable = 1'b1;
    reg [15:0] power_count = 0;
    wire ready = &power_count;
    assign board_ready = ready;
    assign keys_pressed = ~key_stable;
    always @(posedge sys_clk)
        if (!ready) power_count <= power_count + 1'b1;

    reg [2:0] key_meta = 3'b111, key_sync = 3'b111;
    reg [2:0] key_stable = 3'b111;
    reg [19:0] debounce [0:2];
    integer k;
    always @(posedge sys_clk) begin
        key_meta <= key_n;
        key_sync <= key_meta;
        for (k=0; k<3; k=k+1) begin
            if (!ready || key_sync[k] == key_stable[k]) debounce[k] <= 0;
            else if (debounce[k] == DEBOUNCE_CYCLES-1) begin
                key_stable[k] <= key_sync[k];
                debounce[k] <= 0;
            end else debounce[k] <= debounce[k]+1'b1;
        end
    end

    reg [24:0] heartbeat_count = 0;
    reg heartbeat = 0;
    always @(posedge sys_clk) begin
        if (!ready) begin heartbeat_count <= 0; heartbeat <= 0; end
        else if (heartbeat_count == HALF_SECOND_CYCLES-1) begin
            heartbeat_count <= 0; heartbeat <= !heartbeat;
        end else heartbeat_count <= heartbeat_count+1'b1;
    end

    // Keys 0/1/2 control red/green/blue. Idle: dim green heartbeat.
    wire [7:0] red = !key_stable[0] ? 8'h10 : 8'h00;
    wire [7:0] green = !key_stable[1] ? 8'h10 :
        ((key_stable==3'b111 && heartbeat) ? 8'h04 : 8'h00);
    wire [7:0] blue = !key_stable[2] ? 8'h10 : 8'h00;
    reg [23:0] frame = 0;
    reg [5:0] phase = 0;
    reg [4:0] bit_index = 0;
    // 24 * 1.26 us then > 280 us reset low, refreshed every 20 ms.
    reg [19:0] refresh_count = 0;
    reg sending = 0;
    always @(posedge sys_clk) begin
        if (!ready) begin
            refresh_count<=0; sending<=0; rgb_data<=0;
            phase<=0; bit_index<=0; frame<=0;
        end else if (!sending) begin
            rgb_data<=0;
            if (refresh_count==999999) begin
                refresh_count<=0; frame<=STATUS_MODE ? status_grb : {green,red,blue};
                sending<=1; phase<=0; bit_index<=23;
            end else refresh_count<=refresh_count+1'b1;
        end else begin
            rgb_data <= phase < (frame[bit_index] ? 40 : 20);
            if (phase==62) begin
                phase<=0;
                if (bit_index==0) begin sending<=0; rgb_data<=0; end
                else bit_index<=bit_index-1'b1;
            end else phase<=phase+1'b1;
        end
    end
endmodule
