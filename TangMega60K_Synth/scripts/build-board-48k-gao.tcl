file mkdir clock48/rtl/audio/rom
foreach rom {waves.hex midi.hex velocity.hex sine.hex ratio.hex piano.hex polar_lane0.hex polar_lane1.hex polar_ratios.hex} {
    file copy -force [file join rtl audio rom $rom] [file join clock48 rtl audio rom $rom]
}
open_project clock48/BoardAudio48kGAO.gprj
set_option -top_module board_audio_48k_gao_top
set_option -gen_text_timing_rpt 1
run all
