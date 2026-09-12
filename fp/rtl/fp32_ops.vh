//==============================================================================================//
// FILE: fp32_ops.vh
//
// DESCRIPTION: fp32_fpu_top 的 op 域宽度与六条运算的编码，本目录唯一定义处。
//
// NOTE:
//   1. 编码值本身没有数值含义，集成方可按自己的指令编码修改本文件，五个计算单元与编码无关
//   2. 宽度 4 位共 16 个编码，本目录用掉 6 个；其余编码留给集成方的其他功能单元，
//      分发层对它们不做任何事，由调用方兜底
//   3. 改宽度须同时改例化方传入的 OpWidth，fp32_fpu_top 有例化期检查
//==============================================================================================//

`ifndef FP32_OPS_VH
`define FP32_OPS_VH

// op 域宽度，例化方传入的 OpWidth 须与之相等
`define FP32_OP_WIDTH 4

// 六条标量 FP 运算
`define FP32_OP_FADD   4'd4
`define FP32_OP_FSUB   4'd5
`define FP32_OP_FMUL   4'd6
`define FP32_OP_FCMP   4'd8
`define FP32_OP_FCVT   4'd9
`define FP32_OP_FRECIP 4'd13

// 归类：走本目录五个计算单元的六条
`define FP32_OP_IS_FPU(c) ( ((c) == `FP32_OP_FADD)   || \
                            ((c) == `FP32_OP_FSUB)   || \
                            ((c) == `FP32_OP_FMUL)   || \
                            ((c) == `FP32_OP_FCMP)   || \
                            ((c) == `FP32_OP_FCVT)   || \
                            ((c) == `FP32_OP_FRECIP) )

`endif // FP32_OPS_VH
