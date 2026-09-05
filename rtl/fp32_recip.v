`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: fp32_recip
//
// DESCRIPTION: FP32 倒数近似单元，查表加一轮牛顿迭代，5 级流水
//
// NOTE:
//   1. 最大误差 4 ULP，不作为 IEEE 754 正确舍入除法使用
//   2. denormal 输入/输出采用 FTZ；NaN 原值透传
//   3. 查表地址由输入组合直连 BRAM，读延迟由 BRAM 自身的一级寄存承担
//==============================================================================================//

module fp32_recip (
    input             clk,
    input             rst_n,
    input      [31:0] a,
    input             in_valid,
    input             flush,      // 作废在飞运算，清 valid 链
    output reg        out_valid,
    output reg [31:0] result
);

    // valid 影子流水
    reg v1, v2, v3, v4;   // 第 1~4 级有效位

    always @(posedge clk) begin
        if (!rst_n || flush) {v1, v2, v3, v4, out_valid} <= 5'b0;
        else                 {v1, v2, v3, v4, out_valid} <= {in_valid, v1, v2, v3, v4};
    end

    // 级1：拆包 + 查表在途
    wire        s0_sign = a[31];      // 输入符号
    wire [7:0]  s0_exp  = a[30:23];   // 输入阶码
    wire [22:0] s0_frac = a[22:0];    // 输入小数位
    wire s0_nan  = (s0_exp == 8'hFF) && (s0_frac != 0);
    wire s0_inf  = (s0_exp == 8'hFF) && (s0_frac == 0);
    wire s0_zero = (s0_exp == 8'd0);           // 零或 denormal
    wire s0_pow2 = (s0_frac == 23'd0);         // 2 的幂精确路径

    // BRAM 同步读，地址组合直连。BRAM 在本拍时钟沿锁存地址，
    // 数据于下一拍到达，与级1寄存器同拍，故不需要额外的对齐级。
    wire [31:0] lut_dout;   // Q0.17 倒数初值

    bram_lut_1024x32 #(
        .Memfile("recip_lut.mem")
    ) recip_lut (
        .clk  (clk),
        .addr (s0_frac[22:13]),
        .dout (lut_dout)
    );

    reg        s1_nan, s1_inf, s1_zero, s1_sign, s1_pow2;   // 特殊值状态
    reg [7:0]  s1_exp;                                      // 输入阶码
    reg [23:0] s1_m;                                        // Q1.23 尾数
    reg [31:0] s1_a;                                        // NaN 原值

    always @(posedge clk) begin
        if (!rst_n) begin
            s1_nan  <= 1'b0;
            s1_inf  <= 1'b0;
            s1_zero <= 1'b0;
            s1_sign <= 1'b0;
            s1_pow2 <= 1'b0;
            s1_exp  <= 8'd0;
            s1_m    <= 24'd0;
            s1_a    <= 32'd0;
        end else begin
            s1_nan  <= s0_nan;
            s1_inf  <= s0_inf;
            s1_zero <= s0_zero;
            s1_sign <= s0_sign;
            s1_pow2 <= s0_pow2;
            s1_exp  <= s0_exp;
            s1_m    <= {1'b1, s0_frac};
            s1_a    <= a;
        end
    end

    // 级2：收表
    reg        s2_nan, s2_inf, s2_zero, s2_sign, s2_pow2;   // 特殊值状态
    reg [7:0]  s2_exp;                                      // 输入阶码
    reg [23:0] s2_m;                                        // Q1.23 尾数
    reg [17:0] s2_r0;                                       // Q0.17 倒数初值
    reg [31:0] s2_a;                                        // NaN 原值

    always @(posedge clk) begin
        if (!rst_n) begin
            s2_nan  <= 1'b0;
            s2_inf  <= 1'b0;
            s2_zero <= 1'b0;
            s2_sign <= 1'b0;
            s2_pow2 <= 1'b0;
            s2_exp  <= 8'd0;
            s2_m    <= 24'd0;
            s2_r0   <= 18'd0;
            s2_a    <= 32'd0;
        end else begin
            s2_nan  <= s1_nan;
            s2_inf  <= s1_inf;
            s2_zero <= s1_zero;
            s2_sign <= s1_sign;
            s2_pow2 <= s1_pow2;
            s2_exp  <= s1_exp;
            s2_m    <= s1_m;
            s2_r0   <= lut_dout[17:0];
            s2_a    <= s1_a;
        end
    end

    // 级3：牛顿乘积
    wire [41:0] t_s3 = s2_m * s2_r0;   // m × r0，Q1.40

    reg        s3_nan, s3_inf, s3_zero, s3_sign, s3_pow2;   // 特殊值状态
    reg [7:0]  s3_exp;                                      // 输入阶码
    reg [17:0] s3_r0;                                       // Q0.17 倒数初值
    reg [41:0] s3_t;                                        // Q1.40 牛顿乘积
    reg [31:0] s3_a;                                        // NaN 原值

    always @(posedge clk) begin
        if (!rst_n) begin
            s3_nan  <= 1'b0;
            s3_inf  <= 1'b0;
            s3_zero <= 1'b0;
            s3_sign <= 1'b0;
            s3_pow2 <= 1'b0;
            s3_exp  <= 8'd0;
            s3_r0   <= 18'd0;
            s3_t    <= 42'd0;
            s3_a    <= 32'd0;
        end else begin
            s3_nan  <= s2_nan;
            s3_inf  <= s2_inf;
            s3_zero <= s2_zero;
            s3_sign <= s2_sign;
            s3_pow2 <= s2_pow2;
            s3_exp  <= s2_exp;
            s3_r0   <= s2_r0;
            s3_t    <= t_s3;
            s3_a    <= s2_a;
        end
    end

    // 级4：牛顿修正
    wire [41:0] d_s4  = 42'h200_0000_0000 - s3_t;   // 2 - m × r0，Q1.40
    wire [59:0] r1_s4 = s3_r0 * d_s4;               // 1/m 估计，Q0.57

    reg        s4_nan, s4_inf, s4_zero, s4_sign, s4_pow2;   // 特殊值状态
    reg [7:0]  s4_exp;                                      // 输入阶码
    reg [59:0] s4_r1;                                       // Q0.57 倒数估计
    reg [31:0] s4_a;                                        // NaN 原值

    always @(posedge clk) begin
        if (!rst_n) begin
            s4_nan  <= 1'b0;
            s4_inf  <= 1'b0;
            s4_zero <= 1'b0;
            s4_sign <= 1'b0;
            s4_pow2 <= 1'b0;
            s4_exp  <= 8'd0;
            s4_r1   <= 60'd0;
            s4_a    <= 32'd0;
        end else begin
            s4_nan  <= s3_nan;
            s4_inf  <= s3_inf;
            s4_zero <= s3_zero;
            s4_sign <= s3_sign;
            s4_pow2 <= s3_pow2;
            s4_exp  <= s3_exp;
            s4_r1   <= r1_s4;
            s4_a    <= s3_a;
        end
    end

    // 级5：规格化 + RNE 舍入 + 结果组装
    wire [24:0] mant25 = s4_r1[57:33];                          // 舍入前尾数
    wire        guard_bit = s4_r1[32];                          // 保护位
    wire        sticky_bit = |s4_r1[31:0];                      // 粘滞位
    wire        round_up = guard_bit & (sticky_bit | mant25[0]); // 舍入进位
    wire [25:0] mant_s = {1'b0, mant25} + {25'd0, round_up};     // 舍入后尾数
    wire        mant_ovf = mant_s[24] | s4_pow2;                 // 尾数进位

    wire signed [9:0] exp_base = 10'sd253 - $signed({2'b00, s4_exp}); // 基础阶码
    wire signed [9:0] exp_fin  = exp_base
                                  + (mant_ovf ? 10'sd1 : 10'sd0);     // 最终阶码
    wire underflow = (exp_fin <= 10'sd0);                             // 下溢 FTZ
    wire overflow  = (exp_fin >= 10'sd255);                           // 上溢
    wire [22:0] frac_fin = mant_ovf ? 23'd0 : mant_s[22:0];           // 最终小数位

    // 输出寄存
    always @(posedge clk) begin
        if (!rst_n) begin
            result <= 32'd0;
        end else if (v4) begin
            if      (s4_nan)  result <= s4_a;
            else if (s4_inf)  result <= {s4_sign, 31'd0};
            else if (s4_zero) result <= {s4_sign, 8'hFF, 23'd0};
            else if (overflow)  result <= {s4_sign, 8'hFF, 23'd0};
            else if (underflow) result <= {s4_sign, 31'd0};
            else                result <= {s4_sign, exp_fin[7:0], frac_fin};
        end
    end

endmodule
