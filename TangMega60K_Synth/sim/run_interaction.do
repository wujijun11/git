onerror {quit -f -code 1}
# First cd to this project's sim directory; keep the shared GW5A mapping intact.
if {![file isdirectory work]} {vlib work}
# Teammate B's event FIFO is compiled on its own. The testbench models the
# allocator's accept timing instead of instantiating it, so none of the
# captain's RTL is needed here and a failure cannot be blamed on it.
vlog -modelsimini modelsim_local.ini -work work ../rtl/event_fifo.v ../rtl/interaction_top.v
vlog -modelsimini modelsim_local.ini -sv -work work tb_interaction.sv
vsim -modelsimini modelsim_local.ini -voptargs=+acc work.tb_interaction
onbreak {quit -f -code 1}
run -all
quit -f -code 0
