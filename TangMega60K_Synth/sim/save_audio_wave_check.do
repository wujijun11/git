# Optional: refresh the snapshot after a successful waves_audio_v2.do run.
onerror {abort}
if {![llength [info commands ::audio_wave::save]]} {error "Run waves_audio_v2.do first."}
::audio_wave::save
