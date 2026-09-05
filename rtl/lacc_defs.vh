//==============================================================================================//
// MODULE: lacc_defs.vh
//
// DESCRIPTION: LaCC 的 RTL 侧定义集：op 域宽度、op 编码、归类宏、未分配 op 的应答值、
//   调度层输出寄存器的延迟。消费者是 lacc_funcs_top.v、fp/fp32_fpu_top.v 与 sim/lacc/*。
//
// NOTE:
//   1. 加新 op 要同时加 `define 和进归类宏，漏了归类会被判未实现而静默返回 qNaN
//   2. 软件侧同一张表在 sdk/software/bsp/include/hal/lacc_isa.h，改编码两边一起改
//==============================================================================================//

`ifndef LACC_DEFS_VH
`define LACC_DEFS_VH

// op 域宽度，例化方传入的 CmdWidth 须与之相等
`define LACC_CMD_WIDTH 4

// 超越函数
`define LACC_CMD_EXP    4'd0
`define LACC_CMD_SIN    4'd1
`define LACC_CMD_COS    4'd2
`define LACC_CMD_RSQRT  4'd3

// 标量 FP
`define LACC_CMD_FADD   4'd4
`define LACC_CMD_FSUB   4'd5
`define LACC_CMD_FMUL   4'd6
`define LACC_CMD_FCMP   4'd8
`define LACC_CMD_FCVT   4'd9
`define LACC_CMD_FRECIP 4'd13

// op 7 / 10~12 / 14~15 未分配，由 lacc_funcs_top 兜底应答 qNaN

// 归类：走 fp32_fpu_top 的六条
`define LACC_CMD_IS_FPU(c) ( ((c) == `LACC_CMD_FADD)   || \
                             ((c) == `LACC_CMD_FSUB)   || \
                             ((c) == `LACC_CMD_FMUL)   || \
                             ((c) == `LACC_CMD_FCMP)   || \
                             ((c) == `LACC_CMD_FCVT)   || \
                             ((c) == `LACC_CMD_FRECIP) )

// 归类：全部已实现的 op
`define LACC_CMD_IS_IMPL(c) ( ((c) == `LACC_CMD_EXP)   || \
                              ((c) == `LACC_CMD_SIN)   || \
                              ((c) == `LACC_CMD_COS)   || \
                              ((c) == `LACC_CMD_RSQRT) || \
                              `LACC_CMD_IS_FPU(c) )

// 未分配 op 的兜底应答值
`define LACC_QNAN 32'h7FC00000

// lacc_funcs_top 输出寄存器引入的延迟，对外延迟 = 子单元延迟（sfu_lat.vh 等）+ 本值
`define LACC_RSP_REG_LAT 1

`endif // LACC_DEFS_VH
