// Single-clock 1-read/1-write state store. No bulk RAM reset: engine sweeps it.
// Same-address read/write is not consumed by the scheduler.
module voice_state_ram #(parameter VOICE_COUNT=64, WIDTH=101) (
    input wire clk,
    input wire [5:0] read_addr,
    output reg [WIDTH-1:0] read_data,
    input wire write_enable,
    input wire [5:0] write_addr,
    input wire [WIDTH-1:0] write_data
);
    reg [WIDTH-1:0] mem [0:VOICE_COUNT-1];
    always @(posedge clk) begin
        read_data <= mem[read_addr];
        if (write_enable) mem[write_addr] <= write_data;
    end
endmodule
