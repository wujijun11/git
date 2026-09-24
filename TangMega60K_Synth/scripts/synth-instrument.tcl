# Run from TangMega60K_Synth root. This synthesizes the complete logical
# input-to-I2S integration; it is still not a board-pin top without PLL/CST/SDC.
open_project AudioEngine_V2.gprj
set_option -top_module instrument_system_v2
run syn
