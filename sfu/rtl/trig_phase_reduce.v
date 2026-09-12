`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: trig_phase_reduce
//
// DESCRIPTION: sincos_func 的相位归约，纯组合，不含寄存器。
//   把 FP32 输入折成「表地址 + 结果符号 + 分类旗标」，调用方只需再加一级出口组装。
//
//   方法：P = |x| * (1/2pi)，取小数位即 (|x| mod 2pi)/2pi。高 2 位定象限，
//   次 10 位查四分之一周期表。cos(x) = sin(x + pi/2) 只是相位多走四分之一周期，
//   所以两者的差别全部收进 is_cos：sin 加 0，cos 加 1024。
//
// NOTE:
//   1. 负角靠二补数低位回绕，不设置独立符号数据通路
//   2. 相位归约支持 |x| < 2^17；更大有限输入设置 f_domain，由调用方返回 qNaN
//   3. f_zero 含 DAZ 输入和 Q17.23 下量化成零的极小正常数。它对 sin 与 cos 的含义不同，
//      由调用方各自解释：sin 要保住 -0 的符号，cos 的正常通路本身就给出 1.0
//==============================================================================================//

module trig_phase_reduce (
    input  wire [31:0] in_data,
    input  wire        is_cos,
    output wire        f_nan,
    output wire        f_inf,
    output wire        f_zero,
    output wire        f_domain,  // 有限输入超出相位归约支持范围
    output wire        sign,       // 输入的符号位，sin 用它保住 -0
    output wire [9:0]  idx,        // 四分之一周期正弦表的地址
    output wire        res_sign    // 结果符号，取自象限高位
);
    localparam [31:0] Inv2piQ032 = 32'h28BE60DC;   // round((1/2pi) * 2^32)

    wire [7:0]  exp_e  = in_data[30:23];
    wire [22:0] mant_e = in_data[22:0];
    wire signed [8:0] real_exp = $signed({1'b0, exp_e}) - 9'sd127;

    assign sign   = in_data[31];
    assign f_nan  = (exp_e == 8'hFF && mant_e != 0);
    assign f_inf  = (exp_e == 8'hFF && mant_e == 0);
    assign f_domain = (exp_e != 8'hFF) && (real_exp > 9'sd16);

    // |x| 定点化为 Q17.23
    wire [23:0] mant24 = {1'b1, mant_e};
    wire [4:0] shl = (real_exp > 9'sd16) ? 5'd16 : real_exp[4:0];
    wire [5:0] shr = (9'sd0 - real_exp) > 9'sd40 ? 6'd40 : (6'd0 - real_exp[5:0]);
    wire [40:0] x_mag = real_exp[8] ? ({17'd0, mant24} >> shr)
                                    : ({17'd0, mant24} << shl);
    assign f_zero = (x_mag == 41'd0);

    // P = |x|/2pi，只有小数位有用；cos 再推进四分之一周期
    wire [72:0] p_mag    = x_mag * Inv2piQ032;
    wire [54:0] uf_field = sign ? (~p_mag[54:0] + 55'd1) : p_mag[54:0];
    wire [11:0] uf12     = uf_field[54:43] + (is_cos ? 12'd1024 : 12'd0);

    wire [1:0] quadrant = uf12[11:10];
    wire [9:0] qfrac    = uf12[9:0];

    assign idx      = quadrant[0] ? (10'd1023 - qfrac) : qfrac;   // 奇象限表项反向
    assign res_sign = quadrant[1];

endmodule
