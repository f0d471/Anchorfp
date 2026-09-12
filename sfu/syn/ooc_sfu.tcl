# SFU 单元的离线综合快照：网表单元计数与 20 ns 约束下的最差路径
#   用法：vivado -mode batch -source ooc_sfu.tcl -tclargs <顶层> [器件]
#   顶层：exp_func、rsqrt_func，以及 ooc_tops.v 里的 sincos_lut、trig_split、trig_split_sep
#   综合前按 manifest 检查查找表，综合后检查每块 ROM 都带初值；结果直接数网表单元

proc arg {i d} { global argv; if {[llength $argv] > $i} { return [lindex $argv $i] }; return $d }

set top  [arg 0 exp_func]
set part [arg 1 xc7a200tfbg676-1]

source ./check_sfu_luts.tcl
check_sfu_luts ../rtl

read_verilog [concat [glob ../rtl/*.v] [list ../../common/bram_lut_1024x32.v ooc_tops.v]]
set_property include_dirs [list ../rtl] [current_fileset]
# $readmemh 用裸文件名，把表登记进工程供综合查找
read_mem [glob ../rtl/*.mem]

synth_design -top $top -part $part -mode out_of_context

create_clock -name clk -period 20.000 [get_ports clk]
set_input_delay  -clock clk 1.0 [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay -clock clk 1.0 [all_outputs]
opt_design -quiet

set nlut [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set nff  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set ncy  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == CARRY}]]
set ndsp [llength [get_cells -hier -filter {REF_NAME =~ DSP48*}]]
set rams [get_cells -hier -filter {REF_NAME =~ RAMB*}]
set n36  [llength [get_cells -hier -filter {REF_NAME =~ RAMB36*}]]
set n18  [llength [get_cells -hier -filter {REF_NAME =~ RAMB18*}]]
# 四个顶层都含 ROM，找不到说明计数口径错了，不能让下面的初值检查在空集合上通过
if {[llength $rams] == 0} {
    error "OOCSFU $top: 网表里没有找到 RAMB 单元"
}

# 每块 ROM 的前 8 个表项不全为零，否则视为初值未加载
set noinit 0
foreach r $rams {
    set v [get_property INIT_00 $r]
    if {[regexp {^256'h0+$} $v]} { incr noinit; puts "OOCSFU-NOINIT $r" }
}

set p   [get_timing_paths -max_paths 1 -delay_type max]
set wns [get_property SLACK $p]
set lvl [get_property LOGIC_LEVELS $p]

puts "OOCSFU $top LUT=$nlut FF=$nff CARRY=$ncy DSP=$ndsp RAMB36=$n36 RAMB18=$n18 WNS=$wns LEVELS=$lvl"
puts "OOCPATH $top [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
if {$noinit != 0} {
    error "OOCSFU $top: $noinit 块 ROM 没有初值"
}
