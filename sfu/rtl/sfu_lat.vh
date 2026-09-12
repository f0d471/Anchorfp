//==============================================================================================//
// FILE: sfu_lat.vh
//
// DESCRIPTION: SFU 函数单元的单元延迟，本目录唯一定义处。
//
// NOTE:
//   1. 延迟定义：in_valid 被采样的时钟沿记为 T，out_valid 拉高的时钟沿为 T+N，本文件给出 N
//   2. 各值为仿真实测量，单元测试台断言实测值与宏相等；改流水级数后须重测再改本文件
//==============================================================================================//
`ifndef SFU_LAT_VH
`define SFU_LAT_VH

// exp_func：p0 定点化 → s1 常数乘并提取 n/idx → 查表 → s2 收表 → 出口组装
`define EXP_FUNC_LAT 5

// sincos_func 及其两个固定包装：s0 相位归约与查表 → 出口组装
`define SIN_FUNC_LAT 2
`define COS_FUNC_LAT 2

// rsqrt_func：p1 分类 → p2 奇偶与查表 → p3 收表 → 出口组装
`define RSQRT_FUNC_LAT 4

`endif // SFU_LAT_VH
