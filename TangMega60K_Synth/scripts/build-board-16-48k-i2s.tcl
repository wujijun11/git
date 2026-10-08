# Isolated output directory preserves the playable and 64-voice bitstreams.
file mkdir board16/rtl/audio/rom
foreach rom {waves.hex midi.hex velocity.hex sine.hex ratio.hex piano.hex polar_lane0.hex polar_lane1.hex polar_ratios.hex} {
    file copy -force [file join rtl audio rom $rom] [file join board16 rtl audio rom $rom]
}
open_project board16/BoardAudio16_48kI2S.gprj
set_option -top_module board_audio_16_48k_i2s_top
set_option -gen_text_timing_rpt 1
run all
