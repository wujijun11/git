module wavetable_rom #(
    parameter WAVE_FILE="rtl/audio/rom/waves.hex",
    parameter NOTE_FILE="rtl/audio/rom/midi.hex",
    parameter VELOCITY_FILE="rtl/audio/rom/velocity.hex",
    parameter PIANO_FILE="rtl/audio/rom/piano.hex"
) (
    input wire clk,
    input wire [11:0] wave_addr,
    output reg signed [15:0] wave_sample,
    input wire [6:0] note_addr,
    output reg [31:0] note_ftw,
    input wire [6:0] velocity_addr,
    output reg [15:0] velocity_gain,
    input wire [12:0] piano_addr,
    output reg signed [15:0] piano_body, piano_bright
);
    reg [15:0] waves [0:4095];
    reg [31:0] notes [0:127];
    reg [15:0] velocities [0:127];
    // Two mathematical periodic waves, NOT recorded instrument samples.
    reg [31:0] piano [0:8191];
    initial begin
        $readmemh(WAVE_FILE, waves);
        $readmemh(NOTE_FILE, notes);
        $readmemh(VELOCITY_FILE, velocities);
        $readmemh(PIANO_FILE, piano);
    end
    always @(posedge clk) begin
        wave_sample <= waves[wave_addr];
        note_ftw <= notes[note_addr];
        velocity_gain <= velocities[velocity_addr];
        {piano_body,piano_bright} <= piano[piano_addr];
    end
endmodule
