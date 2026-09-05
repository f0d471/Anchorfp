set top [lindex $argv 0]
read_verilog -sv {../rtl/fp32_mac_unit.v ../rtl/fp32_mul_pipe.v ../rtl/fp32_add.v}
set_property include_dirs {../rtl} [current_fileset]
synth_design -top $top -part xc7a200tfbg676-1 -mode out_of_context
puts [report_utilization -return_string]
