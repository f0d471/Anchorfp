# 按给定顶层离线综合 fp32_mac_unit、fp32_mul_pipe、fp32_add，打印完整利用率报告
#   用法：vivado -mode batch -source ooc1.tcl -tclargs <顶层>
set top [lindex $argv 0]
read_verilog -sv {../rtl/fp32_mac_unit.v ../rtl/fp32_mul_pipe.v ../rtl/fp32_add.v}
set_property include_dirs {../rtl} [current_fileset]
synth_design -top $top -part xc7a200tfbg676-1 -mode out_of_context
puts [report_utilization -return_string]
