`timescale 1ns / 1ps
//==============================================================================================//
// FILE: fp32_mul_pipe.v
//
// DESCRIPTION: FP32 乘法器，2 级流水，round-to-nearest-even + FTZ。
//   本文件装三个模块：fp32_mul_s1 出未舍入的原始积，fp32_mul_s2 做规格化与舍入，
//   fp32_mul_pipe 把两级串起来。拆级是给 fp32_mac_unit 的融合通路用的，那条通路只取级 1。
//
// NOTE:
//   1. denormal 输入 FTZ 为 ±0；结果 denormal→±0、上溢→±Inf（有意偏离 IEEE 754）
//   2. Inf × 0 与 Inf × denormal 输出 qNaN
//   3. 右移规格化时原积 bit0 移出 48 位容器，须并回粘滞位，否则丢半 ULP 以下信息
//   4. 级 1 的输出未经 FTZ 与上溢钳位，是原始积，融合通路的中间积只在末项钳一次
//==============================================================================================//

module fp32_mul_s1 (
    input             clk,
    input             rst_n,
    input      [31:0] a,
    input      [31:0] b,
    input             in_valid,
    input             flush,        // 作废在飞运算，清 valid
    output reg        v_s1,         // 1 拍后有效
    output reg [47:0] product_r,    // 24x24 尾数积，未规格化未舍入
    output reg signed [9:0] exp_r,  // ea + eb - 127。值 = product_r * 2^(exp_r - 173)
    output reg        sign_r,
    output reg        spec_nan_r,   // qNaN：任一输入 NaN，或 Inf x 0
    output reg        spec_inf_r,
    output reg        spec_zero_r,  // 任一输入为零或 denormal
    output reg        spec_sel_r,   // 上面三个之一成立
    output reg        spec_sgn_r
);

    always @(posedge clk) begin
        if (!rst_n || flush) v_s1 <= 1'b0;
        else                 v_s1 <= in_valid;
    end

    wire        a_sign = a[31];      // a 符号位
    wire [7:0]  a_exp  = a[30:23];   // a 阶码
    wire [22:0] a_frac = a[22:0];    // a 小数位
    wire        b_sign = b[31];      // b 符号位
    wire [7:0]  b_exp  = b[30:23];   // b 阶码
    wire [22:0] b_frac = b[22:0];    // b 小数位

    wire [23:0] a_mant = {1'b1, a_frac};   // a 隐藏位尾数
    wire [23:0] b_mant = {1'b1, b_frac};   // b 隐藏位尾数
    wire result_sign = a_sign ^ b_sign;    // 乘积符号

    // 特殊值
    wire a_is_nan  = (a_exp == 8'hFF) && (a_frac != 0);
    wire b_is_nan  = (b_exp == 8'hFF) && (b_frac != 0);
    wire a_is_inf  = (a_exp == 8'hFF) && (a_frac == 0);
    wire b_is_inf  = (b_exp == 8'hFF) && (b_frac == 0);
    wire a_is_zero = (a_exp == 8'd0);   // a 零或 denormal
    wire b_is_zero = (b_exp == 8'd0);   // b 零或 denormal

    wire is_nan = a_is_nan | b_is_nan;
    wire inf_zero_conflict = (a_is_inf | b_is_inf) && (a_is_zero | b_is_zero); // Inf × 0
    wire is_nan_full = is_nan | inf_zero_conflict;                             // qNaN 结果
    wire is_inf      = a_is_inf | b_is_inf;
    wire is_zero     = a_is_zero | b_is_zero;
    wire spec_sel    = is_nan_full | is_inf | is_zero;                         // 特殊值选择

    wire [47:0] product_s0 = a_mant * b_mant;   // 尾数积
    wire signed [9:0] exp_sum_s0 = $signed({2'b0, a_exp})
                                    + $signed({2'b0, b_exp}) - 10'sd127; // 带符号阶码和

    always @(posedge clk) begin
        if (!rst_n) begin
            product_r   <= 48'd0;
            exp_r       <= 10'sd0;
            sign_r      <= 1'b0;
            spec_nan_r  <= 1'b0;
            spec_inf_r  <= 1'b0;
            spec_zero_r <= 1'b0;
            spec_sel_r  <= 1'b0;
            spec_sgn_r  <= 1'b0;
        end else begin
            product_r   <= product_s0;
            exp_r       <= exp_sum_s0;
            sign_r      <= result_sign;
            spec_nan_r  <= is_nan_full;
            spec_inf_r  <= is_inf & ~is_nan_full;
            spec_zero_r <= is_zero & ~is_nan_full & ~is_inf;
            spec_sel_r  <= spec_sel;
            spec_sgn_r  <= result_sign;
        end
    end

endmodule


module fp32_mul_s2 (
    input             clk,
    input             rst_n,
    input             v_s1,
    input             flush,
    input      [47:0] product_r,
    input signed [9:0] exp_r,
    input             sign_r,
    input             spec_nan_r,
    input             spec_inf_r,
    input             spec_zero_r,
    input             spec_sel_r,
    input             spec_sgn_r,
    output reg [31:0] p,
    output reg        out_valid
);

    always @(posedge clk) begin
        if (!rst_n || flush) out_valid <= 1'b0;
        else                 out_valid <= v_s1;
    end

    // 规格化
    reg signed [9:0] exp_n_s;   // 规格化阶码
    reg [47:0] prod_n;          // 规格化尾数积

    always @(*) begin
        if (product_r[47]) begin
            exp_n_s = exp_r + 10'sd1;
            prod_n  = product_r >> 1;
            prod_n[0] = product_r[1] | product_r[0];   // 低位粘着，右移丢掉的 bit0 并回
        end else begin
            exp_n_s = exp_r;
            prod_n  = product_r;
        end
    end

    // RNE 舍入
    wire guard_bit  = prod_n[22];          // 保护位
    wire sticky_bit = |prod_n[21:0];       // 粘滞位
    wire mant_lsb   = prod_n[23];          // 保留尾数最低位
    wire round_up   = guard_bit & (sticky_bit | mant_lsb); // 舍入进位

    wire [24:0] mant_rnd = {1'b0, prod_n[46:23]} + {24'd0, round_up}; // 舍入后尾数
    wire        mant_ovf = mant_rnd[24];                               // 尾数进位
    wire signed [9:0] exp_final_s = exp_n_s
                                      + (mant_ovf ? 10'sd1 : 10'sd0); // 最终阶码
    wire ftz_out  = (exp_final_s <= 10'sd0);                           // 下溢 FTZ
    wire overflow = (exp_final_s >= 10'sd255);                         // 上溢
    wire [22:0] frac_final = mant_ovf ? 23'd0 : mant_rnd[22:0];        // 最终小数位

    wire [31:0] normal_val;   // 常规结果
    wire [31:0] spec_res;     // 特殊值结果

    assign normal_val = ftz_out  ? {sign_r, 31'd0}
                      : overflow ? {sign_r, 8'hFF, 23'd0}
                      :            {sign_r, exp_final_s[7:0], frac_final};

    assign spec_res = spec_nan_r  ? 32'h7FC00000
                    : spec_inf_r  ? {spec_sgn_r, 8'hFF, 23'd0}
                    : spec_zero_r ? {spec_sgn_r, 31'd0}
                    :               32'd0;

    always @(posedge clk) begin
        if (!rst_n) p <= 32'd0;
        else        p <= spec_sel_r ? spec_res : normal_val;
    end

endmodule


module fp32_mul_pipe (
    input             clk,
    input             rst_n,
    input      [31:0] a,
    input      [31:0] b,
    output     [31:0] p,          // 2 拍后有效
    input             in_valid,
    input             flush,      // 作废在飞运算，清 valid 链
    output            out_valid
);

    wire        v_s1, sign_r, spec_nan_r, spec_inf_r, spec_zero_r, spec_sel_r, spec_sgn_r;
    wire [47:0] product_r;
    wire signed [9:0] exp_r;

    fp32_mul_s1 u_s1 (
        .clk(clk), .rst_n(rst_n), .a(a), .b(b), .in_valid(in_valid), .flush(flush),
        .v_s1(v_s1), .product_r(product_r), .exp_r(exp_r), .sign_r(sign_r),
        .spec_nan_r(spec_nan_r), .spec_inf_r(spec_inf_r), .spec_zero_r(spec_zero_r),
        .spec_sel_r(spec_sel_r), .spec_sgn_r(spec_sgn_r)
    );

    fp32_mul_s2 u_s2 (
        .clk(clk), .rst_n(rst_n), .v_s1(v_s1), .flush(flush),
        .product_r(product_r), .exp_r(exp_r), .sign_r(sign_r),
        .spec_nan_r(spec_nan_r), .spec_inf_r(spec_inf_r), .spec_zero_r(spec_zero_r),
        .spec_sel_r(spec_sel_r), .spec_sgn_r(spec_sgn_r),
        .p(p), .out_valid(out_valid)
    );

endmodule
