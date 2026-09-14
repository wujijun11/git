// Milestone 01 integration boundary; NOT a board-pin top level.
// B teammate connects event_*; A teammate connects cmd_* and done_*.
// clk and rst_n must be synchronous system-domain inputs at integration.
module captain_control_top (
    input wire clk,
    input wire rst_n,
    input wire event_valid,
    output wire event_ready,
    input wire event_on,
    input wire [6:0] event_note,
    input wire [6:0] event_velocity,
    input wire [1:0] event_timbre,
    output wire cmd_valid,
    input wire cmd_ready,
    output wire cmd_on,
    output wire [5:0] cmd_voice,
    output wire [6:0] cmd_note,
    output wire [6:0] cmd_velocity,
    output wire [1:0] cmd_timbre,
    input wire done_valid,
    output wire done_ready,
    input wire [5:0] done_voice,
    output wire [6:0] active_count,
    output wire [63:0] active_mask,
    output wire [63:0] held_mask,
    output wire full_pulse,
    output wire ignored_pulse,
    output wire done_error_pulse
);
    voice_allocator #(.VOICE_COUNT(64), .ID_WIDTH(6)) u_allocator (
        .clk(clk), .rst_n(rst_n),
        .event_valid(event_valid), .event_ready(event_ready),
        .event_on(event_on), .event_note(event_note),
        .event_velocity(event_velocity), .event_timbre(event_timbre),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready),
        .cmd_on(cmd_on), .cmd_voice(cmd_voice), .cmd_note(cmd_note),
        .cmd_velocity(cmd_velocity), .cmd_timbre(cmd_timbre),
        .done_valid(done_valid), .done_ready(done_ready), .done_voice(done_voice),
        .active_count(active_count), .active_mask(active_mask), .held_mask(held_mask),
        .full_pulse(full_pulse), .ignored_pulse(ignored_pulse),
        .done_error_pulse(done_error_pulse)
    );
endmodule
