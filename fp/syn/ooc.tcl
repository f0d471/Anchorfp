# 单条 lane 的离线综合，扫窗口宽度的面积代价
#   用法：vivado -mode batch -source ooc.tcl -tclargs <WinUp> <WinFrac> <UseCarrySave> <FuseMul>
#   UseCarrySave 只能传 0，传 1 会在例化期报 fp32_error_UseCarrySave_not_in_supported_set
set up   [lindex $argv 0]
set fr   [lindex $argv 1]
set cs   [lindex $argv 2]
set fuse [lindex $argv 3]
read_verilog -sv {../rtl/fp32_mac_unit.v ../rtl/fp32_mul_pipe.v}
set_property include_dirs {../rtl} [current_fileset]
synth_design -top fp32_mac_unit -part xc7a200tfbg676-1 -mode out_of_context \
    -generic WinUp=$up -generic WinFrac=$fr -generic UseCarrySave=$cs -generic FuseMul=$fuse
# 抓结果行。OOC 报告里那一行叫 "Slice LUTs*"，星号是"含 OOC 端口估计"的脚注标记，
# 正则必须允许它，否则整份日志一个 LUT 数都抓不到。
# 更稳的口径是别解析文本，见 ooc_mac.tcl 直接数网表单元。
set r [report_utilization -return_string]
foreach line [split $r "\n"] {
    if {[regexp {\| (Slice LUTs|Slice Registers|DSPs)\*?\s} $line]} { puts "OOCUTIL $line" }
}
puts "OOCDONE up=$up frac=$fr csa=$cs fuse=$fuse"
