//==============================================================================================//
// FILE: fp32_lat.vh
//
// DESCRIPTION: fp 目录各计算单元的流水延迟常数，RTL 与 TB 的唯一定义处。
//
// NOTE:
//   1. 各 LAT 为仿真实测量，约束由 sim/fp_round/tb_fp_lat.v 施加
//   2. 修改流水级数后须重新实测并更新本文件，不得由级数推算
//   3. FP32_MAC_PACE 与 FP32_MAC_OUT_LAT 为派生量，不单独填写
//==============================================================================================//

`ifndef FP32_LAT_VH
`define FP32_LAT_VH

// in_valid 到 out_valid 的延迟，单位为拍
`define FP32_ADD_LAT   3   // 对阶 / 加减+规格化 / 舍入+组装
`define FP32_MUL_LAT   2   // 拆包+尾数乘+阶码和 / 规格化+舍入+组装
`define FP32_CMP_LAT   1   // 组合比较 + 输出寄存
`define FP32_CVT_LAT   1   // 组合转换 + 输出寄存
`define FP32_RECIP_LAT 5   // 拆包与查表在途 1 级 / 收表 1 级 / 牛顿迭代 2 级 / 舍入组装 1 级

// fp32_mac_unit 的三段延迟，各自独立实测，不由 FP32_ADD_LAT 派生。
// FP32_MAC_LOOP_LAT 与 FP32_ADD_LAT 是两回事，后者仍是标量 FPU 加法指令的延迟。
`define FP32_MAC_LOOP_LAT  1   // 累加反馈环：acc <= 移位后的 acc + term，一拍
`define FP32_MAC_ALIGN_LAT 2   // 环外对阶：基准推导与移位量一级 / 桶形右移一级
`define FP32_MAC_NORM_LAT  3   // 环外规格化：取模加前导零检测 / 规格化移位 / 舍入组装

// 相邻 prod_valid 的最小间隔，等于反馈环长
`define FP32_MAC_PACE `FP32_MAC_LOOP_LAT

// 末项 prod_valid 到 out_valid 的延迟。FUSE=1 取乘法器级 1，比走舍入积早一拍
`define FP32_MAC_OUT_LAT_F(FUSE) (((FUSE) ? 1 : `FP32_MUL_LAT) + `FP32_MAC_ALIGN_LAT \
                                  + `FP32_MAC_LOOP_LAT + `FP32_MAC_NORM_LAT)

// 产线构型 FuseMul = 1 那一档，保留原名给既有调用方
`define FP32_MAC_OUT_LAT `FP32_MAC_OUT_LAT_F(1)

`endif // FP32_LAT_VH
