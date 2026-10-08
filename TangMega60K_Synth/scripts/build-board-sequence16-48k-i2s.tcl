# Isolated output directory preserves the playable and 64-voice bitstreams.
file mkdir boardseq16/rtl/audio/rom
foreach rom {waves.hex midi.hex velocity.hex sine.hex ratio.hex piano.hex polar_lane0.hex polar_lane1.hex polar_ratios.hex} {
    file copy -force [file join rtl audio rom $rom] [file join boardseq16 rtl audio rom $rom]
}
open_project boardseq16/BoardSequence16_48kI2S.gprj
set_option -top_module board_sequence16_48k_i2s_top
set_option -gen_text_timing_rpt 1
run all
