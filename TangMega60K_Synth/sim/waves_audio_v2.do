# Run from the project root. Load all procedures before starting simulation.
onerror {abort}
if {![file exists sim/audio_wave_session.tcl]} {error "First cd to the TangMega60K_Synth project root."}
source sim/audio_wave_session.tcl
::audio_wave::run
