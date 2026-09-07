`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: fp32_fpu_top
//
// DESCRIPTION: 标量 FP32 的分发层。按 op 把一路输入送给对应的计算单元，五个出口各自独立
//   引出，不做延迟对齐，结果 MUX 由调用方 lacc_funcs_top 完成。
//
// NOTE:
//   1. fpu_op 就是 LaCC ISA 的 op 域（恒等映射），编码单一出处在 rtl/lacc_defs.vh
//   2. 五条出口的延迟定义在 rtl/fp32_lat.vh，端口注释只引宏名，不写数值
//   3. FRECIP 是本模块唯一的近似原语（≤4 ULP），只经 hw_frecipf() 暴露，不接 __divsf3
//==============================================================================================//

`include "lacc_defs.vh"
`include "fp32_lat.vh"

module fp32_fpu_top #(
    parameter OpWidth  = `LACC_CMD_WIDTH,
    parameter ImmWidth = 7
) (
    input                   clk,
    input                   rst_n,
    input  [OpWidth-1:0]    fpu_op,
    input  [31:0]           fpu_a,
    input  [31:0]           fpu_b,
    input  [ImmWidth-1:0]   fpu_imm,       // fcmp: imm[0]=gt_family; cvt: imm[0]=mode, imm[1]=unsigned
    input                   fpu_in_valid,
    input                   fpu_flush,     // 作废在飞运算，广播给五个子函数

    // 加减出口，延迟 `FP32_ADD_LAT
    output                  fpu_faddsub_valid,
    output     [31:0]       fpu_faddsub_data,
    // 乘出口，延迟 `FP32_MUL_LAT
    output                  fpu_fmul_valid,
    output     [31:0]       fpu_fmul_data,
    // 比较出口，延迟 `FP32_CMP_LAT
    output                  fpu_fcmp_valid,
    output     [31:0]       fpu_fcmp_data,
    // 转换出口，延迟 `FP32_CVT_LAT
    output                  fpu_cvt_valid,
    output     [31:0]       fpu_cvt_data,
    // 倒数出口，延迟 `FP32_RECIP_LAT
    output                  fpu_recip_valid,
    output     [31:0]       fpu_recip_data
);

    // 例化不存在的模块，综合与 lint 在例化期即报错（V2001 无编译期断言）。
    // 例化期仅约束参数与常数关系；延迟常数与实际拍数的一致性由sim/tb_fp_lat.v 施加。
    generate
        // 例化方传入的 OpWidth 必须等于 ISA 的 op 域宽度（同 lacc_funcs_top 的检查）
        if (OpWidth != `LACC_CMD_WIDTH) begin : gen_op_width_check
            fp32_error_OP_WIDTH_must_equal_LACC_CMD_WIDTH u_op_width_check ();
        end
        // 五个计算单元均在输出寄存器前收口，延迟不可能为 0；
        // 填 0 意味着该出口为组合直通，调用方的 valid 对齐将整体错位。
        if (`FP32_ADD_LAT < 1) begin : gen_add_lat_check
            fp32_error_FP32_ADD_LAT_must_be_positive u_add_lat_check ();
        end
        if (`FP32_MUL_LAT < 1) begin : gen_mul_lat_check
            fp32_error_FP32_MUL_LAT_must_be_positive u_mul_lat_check ();
        end
        if (`FP32_CMP_LAT < 1) begin : gen_cmp_lat_check
            fp32_error_FP32_CMP_LAT_must_be_positive u_cmp_lat_check ();
        end
        if (`FP32_CVT_LAT < 1) begin : gen_cvt_lat_check
            fp32_error_FP32_CVT_LAT_must_be_positive u_cvt_lat_check ();
        end
        if (`FP32_RECIP_LAT < 1) begin : gen_recip_lat_check
            fp32_error_FP32_RECIP_LAT_must_be_positive u_recip_lat_check ();
        end
    endgenerate

    // 指令译码
    wire cmd_fadd  = (fpu_op == `LACC_CMD_FADD);
    wire cmd_fsub  = (fpu_op == `LACC_CMD_FSUB);
    wire cmd_fmul  = (fpu_op == `LACC_CMD_FMUL);
    wire cmd_fcmp  = (fpu_op == `LACC_CMD_FCMP);
    wire cmd_cvt   = (fpu_op == `LACC_CMD_FCVT);
    wire cmd_recip = (fpu_op == `LACC_CMD_FRECIP);

    // 加减共用的第二操作数
    wire [31:0] faddsub_b = cmd_fsub ? {~fpu_b[31], fpu_b[30:0]} : fpu_b;   // FSUB 走加法通路，翻 b 的符号位

    // 加减
    fp32_add u_add (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (fpu_a),
        .b         (faddsub_b),
        .in_valid  (fpu_in_valid && (cmd_fadd || cmd_fsub)),
        .flush     (fpu_flush),
        .out_valid (fpu_faddsub_valid),
        .s         (fpu_faddsub_data)
    );

    // 乘
    fp32_mul_pipe u_mul (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (fpu_a),
        .b         (fpu_b),
        .in_valid  (fpu_in_valid && cmd_fmul),
        .flush     (fpu_flush),
        .out_valid (fpu_fmul_valid),
        .p         (fpu_fmul_data)
    );

    // 比较
    fp32_cmp u_cmp (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (fpu_a),
        .b         (fpu_b),
        .gt_family (fpu_imm[0]),
        .in_valid  (fpu_in_valid && cmd_fcmp),
        .flush     (fpu_flush),
        .out_valid (fpu_fcmp_valid),
        .result    (fpu_fcmp_data)
    );

    // 转换
    fp32_cvt u_cvt (
        .clk        (clk),
        .rst_n      (rst_n),
        .in         (fpu_a),
        .mode       (fpu_imm[0]),
        .is_unsigned(fpu_imm[1]),
        .in_valid   (fpu_in_valid && cmd_cvt),
        .flush      (fpu_flush),
        .out_valid  (fpu_cvt_valid),
        .out        (fpu_cvt_data)
    );

    // 倒数
    fp32_recip u_recip (
        .clk       (clk),
        .rst_n     (rst_n),
        .a         (fpu_a),
        .in_valid  (fpu_in_valid && cmd_recip),
        .flush     (fpu_flush),
        .out_valid (fpu_recip_valid),
        .result    (fpu_recip_data)
    );

endmodule
