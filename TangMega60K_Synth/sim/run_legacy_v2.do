onerror {quit -f -code 1}
if {![file isdirectory work]} {vlib work}
vlog -work work ../rtl/voice_allocator_v2.v
vlog -sv +define+V2_LEGACY_TEST -work work tb_voice_allocator.sv
vsim -modelsimini modelsim_local.ini work.tb_voice_allocator
onbreak {quit -f -code 1}
run -all
quit -f -code 0
