# 离线综合单条 lane，量窗口宽度的面积代价。参数从命令行 -tclargs 传入
# 注意 cs（UseCarrySave）现在只能传 0：该档已撤出支持集合，传 1 会在例化期报
# fp32_error_UseCarrySave_not_in_supported_set。理由见 docs/reports/10 第 4.4 节。
set up   [lindex $argv 0]
set fr   [lindex $argv 1]
set cs   [lindex $argv 2]
set fuse [lindex $argv 3]
read_verilog -sv {../rtl/fp32_mac_unit.v ../rtl/fp32_mul_pipe.v}
set_property include_dirs {../rtl} [current_fileset]
synth_design -top fp32_mac_unit -part xc7a200tfbg676-1 -mode out_of_context \
    -generic WinUp=$up -generic WinFrac=$fr -generic UseCarrySave=$cs -generic FuseMul=$fuse
# 抓结果行。原来这条正则是 `\| (Slice LUTs|...)\s`，而 OOC 报告里那一行叫
# "Slice LUTs*"（带星号，星号是"含 OOC 端口估计"的脚注标记），空白断言匹配不上，
# 于是本目录六份窗口宽度扫描日志里**一个 LUT 数都没量到** —— 而扫描的目的就是量面积。
# 2026-09-06 修：允许星号。要更稳的口径就别解析文本，见 ooc_mac.tcl 直接数网表单元。
set r [report_utilization -return_string]
foreach line [split $r "\n"] {
    if {[regexp {\| (Slice LUTs|Slice Registers|DSPs)\*?\s} $line]} { puts "OOCUTIL $line" }
}
puts "OOCDONE up=$up frac=$fr csa=$cs fuse=$fuse"
