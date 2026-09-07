# 单条 lane 的离线综合快照，改 fp32_mac_unit 之后做前后对照。
#   用法：vivado -mode batch -source ooc_mac.tcl -tclargs <标签> [WinUp WinFrac UseCarrySave FuseMul]
#   缺省参数 8 8 0 1；UseCarrySave 只能传 0，非零档不在支持集合内
#   结果直接数网表单元，不解析 report_utilization 的文本，报告格式变了也不会漏计

proc arg {i d} { global argv; if {[llength $argv] > $i} { return [lindex $argv $i] } ; return $d }

set tag  [arg 0 base]
set up   [arg 1 8]
set fr   [arg 2 8]
set cs   [arg 3 0]
set fuse [arg 4 1]

# 第 5 个参数是源目录，留给实验副本用；不给就读产线 RTL
set src [arg 5 ../rtl]
read_verilog -sv [list $src/fp32_mac_unit.v ../rtl/fp32_mul_pipe.v]
set_property include_dirs [list $src ../rtl] [current_fileset]
synth_design -top fp32_mac_unit -part xc7a200tfbg676-1 -mode out_of_context \
    -generic WinUp=$up -generic WinFrac=$fr -generic UseCarrySave=$cs -generic FuseMul=$fuse

create_clock -name clk -period 20.000 [get_ports clk]
set_input_delay  -clock clk 1.0 [get_ports {prod_valid acc_load last a[*] b[*] psum_in[*] rst_n}]
set_output_delay -clock clk 1.0 [all_outputs]
opt_design -quiet

set nlut  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
set nff   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
set ncy   [llength [get_cells -hier -filter {PRIMITIVE_GROUP == CARRY}]]
set ndsp  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == DSP}]]
set nmux  [llength [get_cells -hier -filter {PRIMITIVE_GROUP == MUXFX}]]

set p    [get_timing_paths -max_paths 1 -delay_type max]
set wns  [get_property SLACK $p]
set lvl  [get_property LOGIC_LEVELS $p]
set st   [get_property STARTPOINT_PIN $p]
set en   [get_property ENDPOINT_PIN $p]

puts "OOCMAC $tag LUT=$nlut FF=$nff CARRY=$ncy MUXFX=$nmux DSP=$ndsp WNS=$wns LEVELS=$lvl"
puts "OOCPATH $tag $st -> $en"
