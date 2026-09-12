# 标量 FP32 单元的离线综合快照：网表单元计数与 20 ns 约束下的最差路径
#   用法：vivado -mode batch -source ooc_units.tcl -tclargs <顶层> [器件]
#   顶层：fp32_add、fp32_mul_pipe、fp32_cmp、fp32_cvt、fp32_recip、fp32_fpu_top
#   结果直接数网表单元，不解析报告文本

proc arg {i d} { global argv; if {[llength $argv] > $i} { return [lindex $argv $i] }; return $d }

set top  [arg 0 fp32_add]
set part [arg 1 xc7a200tfbg676-1]

read_verilog [list ../rtl/fp32_add.v ../rtl/fp32_mul_pipe.v ../rtl/fp32_cmp.v ../rtl/fp32_cvt.v \
                   ../rtl/fp32_recip.v ../rtl/fp32_fpu_top.v ../../common/bram_lut_1024x32.v]
set_property include_dirs [list ../rtl] [current_fileset]
# $readmemh 用裸文件名，把表登记进工程供综合查找
read_mem ../rtl/recip_lut.mem

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

# 含倒数单元的顶层必须找到带初值的 ROM，否则表未加载
if {$top eq "fp32_recip" || $top eq "fp32_fpu_top"} {
    if {[llength $rams] == 0} { error "OOCFP $top: 网表里没有找到 RAMB 单元" }
    foreach r $rams {
        if {[regexp {^256'h0+$} [get_property INIT_00 $r]]} { error "OOCFP $top: $r 没有初值" }
    }
}

set p   [get_timing_paths -max_paths 1 -delay_type max]
set wns [get_property SLACK $p]
set lvl [get_property LOGIC_LEVELS $p]

puts "OOCFP $top LUT=$nlut FF=$nff CARRY=$ncy DSP=$ndsp RAMB36=$n36 RAMB18=$n18 WNS=$wns LEVELS=$lvl"
puts "OOCPATH $top [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
