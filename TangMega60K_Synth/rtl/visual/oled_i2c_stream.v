// OLED专用开漏I2C写流。命令后写一个控制字节，再写1..128个数据字节。
// 支持ACK错误、SCL延展、SDA卡低清总线及超时；不修改MPR121共享驱动。
module oled_i2c_stream #(
    parameter integer CLK_HZ = 49152000,
    parameter integer I2C_HZ = 100000,
    parameter integer TIMEOUT_CYCLES = CLK_HZ / 20
) (
    input wire clk,
    input wire resetn,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [6:0] cmd_addr,
    input wire [7:0] cmd_control,
    input wire [7:0] cmd_length,
    input wire data_valid,
    output wire data_ready,
    input wire [7:0] data,
    output reg done,
    output reg [2:0] error,
    inout wire scl,
    inout wire sda
);
    localparam integer PERIOD = (CLK_HZ + I2C_HZ - 1) / I2C_HZ;
    localparam integer LOW_SPEC = (CLK_HZ * 13 + 9999999) / 10000000;
    localparam integer LO = LOW_SPEC > PERIOD / 2 ? LOW_SPEC : PERIOD / 2;
    localparam integer LOW_T = LO < 4 ? 4 : LO;
    localparam integer HI = PERIOD - LOW_T;
    localparam integer HIGH_T = HI < 4 ? 4 : HI;
    localparam integer TW = $clog2(LOW_T + HIGH_T + 1);
    localparam integer WW = $clog2(TIMEOUT_CYCLES + 1);
    localparam IDLE=0, FREE=1, START=2, TX_LOW=3, TX_HIGH=4,
        ACK_LOW=5, ACK_HIGH=6, FETCH=7, STOP_LOW=8, STOP_HIGH=9,
        STOP_FREE=10, CLEAR_LOW=11, CLEAR_HIGH=12;
    reg [3:0] state;
    reg scl_low;
    reg sda_low;
    reg [1:0] scl_sync;
    reg [1:0] sda_sync;
    reg [TW-1:0] timer;
    reg [WW-1:0] watchdog;
    reg [7:0] tx_byte;
    reg [7:0] control;
    reg [7:0] length;
    reg [7:0] index;
    reg [2:0] bit_number;
    reg [1:0] phase;
    reg recovering;
    reg recovery_tried;
    reg [3:0] clear_count;
    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;
    assign cmd_ready = state == IDLE;
    assign data_ready = state == FETCH;
    always @(posedge clk) begin
        scl_sync <= {scl_sync[0], scl};
        sda_sync <= {sda_sync[0], sda};
        if (!resetn) begin
            state <= IDLE;
            scl_low <= 0;
            sda_low <= 0;
            scl_sync <= 3;
            sda_sync <= 3;
            timer <= 0;
            watchdog <= 0;
            tx_byte <= 0;
            control <= 0;
            length <= 1;
            index <= 0;
            bit_number <= 7;
            phase <= 0;
            recovering <= 0;
            recovery_tried <= 0;
            clear_count <= 0;
            done <= 0;
            error <= 0;
        end else begin
            done <= 0;
            if (state != IDLE)
                watchdog <= watchdog + 1'b1;
            if (state != IDLE && watchdog >= TIMEOUT_CYCLES - 1) begin
                state <= IDLE;
                scl_low <= 0;
                sda_low <= 0;
                done <= 1;
                error <= state == FREE || recovering ? 3'd3 : 3'd2;
            end else case (state)
                IDLE: if (cmd_valid) begin
                    tx_byte <= {cmd_addr, 1'b0};
                    control <= cmd_control;
                    length <= cmd_length == 0 ? 8'd1 : cmd_length;
                    index <= 0;
                    phase <= 0;
                    bit_number <= 7;
                    timer <= 0;
                    watchdog <= 0;
                    error <= 0;
                    recovering <= 0;
                    recovery_tried <= 0;
                    scl_low <= 0;
                    sda_low <= 0;
                    state <= FREE;
                end
                FREE: if (scl_sync[1] && sda_sync[1]) begin
                    if (timer == LOW_T - 1) begin
                        sda_low <= 1;
                        timer <= 0;
                        state <= START;
                    end else timer <= timer + 1'b1;
                end else if (scl_sync[1] && !sda_sync[1] && !recovery_tried) begin
                    recovering <= 1;
                    recovery_tried <= 1;
                    clear_count <= 0;
                    scl_low <= 1;
                    timer <= 0;
                    state <= CLEAR_LOW;
                end else timer <= 0;
                START: if (timer == HIGH_T - 1) begin
                    scl_low <= 1;
                    sda_low <= ~tx_byte[7];
                    timer <= 0;
                    state <= TX_LOW;
                end else timer <= timer + 1'b1;
                TX_LOW: if (timer == LOW_T - 1) begin
                    scl_low <= 0;
                    timer <= 0;
                    state <= TX_HIGH;
                end else timer <= timer + 1'b1;
                TX_HIGH: if (scl_sync[1]) begin
                    if (timer == HIGH_T - 1) begin
                        scl_low <= 1;
                        timer <= 0;
                        if (bit_number == 0) begin
                            sda_low <= 0;
                            state <= ACK_LOW;
                        end else begin
                            bit_number <= bit_number - 1'b1;
                            sda_low <= ~tx_byte[bit_number-1];
                            state <= TX_LOW;
                        end
                    end else timer <= timer + 1'b1;
                end
                ACK_LOW: if (timer == LOW_T - 1) begin
                    scl_low <= 0;
                    timer <= 0;
                    state <= ACK_HIGH;
                end else timer <= timer + 1'b1;
                ACK_HIGH: if (scl_sync[1]) begin
                    if (timer == HIGH_T - 1) begin
                        scl_low <= 1;
                        timer <= 0;
                        bit_number <= 7;
                        if (sda_sync[1]) begin
                            error <= 1;
                            sda_low <= 1;
                            state <= STOP_LOW;
                        end else if (phase == 0) begin
                            phase <= 1;
                            tx_byte <= control;
                            sda_low <= ~control[7];
                            state <= TX_LOW;
                        end else if (phase == 2 && index + 1 >= length) begin
                            sda_low <= 1;
                            state <= STOP_LOW;
                        end else begin
                            if (phase == 2)
                                index <= index + 1'b1;
                            phase <= 2;
                            sda_low <= 0;
                            state <= FETCH;
                        end
                    end else timer <= timer + 1'b1;
                end
                FETCH: if (data_valid) begin
                    tx_byte <= data;
                    sda_low <= ~data[7];
                    bit_number <= 7;
                    timer <= 0;
                    state <= TX_LOW;
                end
                STOP_LOW: if (timer == LOW_T - 1) begin
                    scl_low <= 0;
                    timer <= 0;
                    state <= STOP_HIGH;
                end else timer <= timer + 1'b1;
                STOP_HIGH: if (scl_sync[1]) begin
                    if (timer == HIGH_T - 1) begin
                        sda_low <= 0;
                        timer <= 0;
                        state <= STOP_FREE;
                    end else timer <= timer + 1'b1;
                end
                STOP_FREE: if (timer == LOW_T - 1) begin
                    timer <= 0;
                    if (recovering) begin
                        recovering <= 0;
                        state <= FREE;
                    end else begin
                        done <= 1;
                        state <= IDLE;
                    end
                end else timer <= timer + 1'b1;
                CLEAR_LOW: if (timer == LOW_T - 1) begin
                    scl_low <= 0;
                    timer <= 0;
                    state <= CLEAR_HIGH;
                end else timer <= timer + 1'b1;
                CLEAR_HIGH: if (scl_sync[1]) begin
                    if (timer == HIGH_T - 1) begin
                        scl_low <= 1;
                        timer <= 0;
                        if (clear_count == 8) begin
                            sda_low <= 1;
                            state <= STOP_LOW;
                        end else begin
                            clear_count <= clear_count + 1'b1;
                            state <= CLEAR_LOW;
                        end
                    end else timer <= timer + 1'b1;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
