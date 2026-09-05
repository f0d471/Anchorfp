`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: fp32_cmp
//
// DESCRIPTION: FP32 比较器，返回三态码 -1/0/+1。denormal 按 FTZ 契约当 ±0，输出寄存 1 拍。
//
// NOTE:
//   1. 同号时复用整数比较（IEEE 754 位序 = 数值序），异号直接看符号位
//==============================================================================================//

module fp32_cmp (
    input             clk,
    input             rst_n,
    input      [31:0] a,
    input      [31:0] b,
    input             gt_family,   // 0=lt/le/eq/ne 家族，1=gt/ge 家族
    input             in_valid,
    input             flush,       // 作废在飞运算，清 valid 链
    output reg        out_valid,
    output reg [31:0] result       // -1 / 0 / +1（有符号 32 位）
);

    // FTZ 规整
    wire [31:0] a_ftz = (a[30:23] == 8'd0) ? {a[31], 31'd0} : a;
    wire [31:0] b_ftz = (b[30:23] == 8'd0) ? {b[31], 31'd0} : b;

    wire a_sgn = a_ftz[31];   // a 符号位
    wire b_sgn = b_ftz[31];   // b 符号位

    // NaN 检测
    wire a_nan = (a_ftz[30:23] == 8'hFF) && (a_ftz[22:0] != 0);
    wire b_nan = (b_ftz[30:23] == 8'hFF) && (b_ftz[22:0] != 0);
    wire unordered = a_nan | b_nan;   // NaN 无序标志

    // 比较
    wire a_lt_b_abs = a_ftz[30:0] < b_ftz[30:0];     // 按绝对值比
    wire a_eq_b_abs = a_ftz[30:0] == b_ftz[30:0]; // 按绝对值相等
    wire same_sign  = (a_sgn == b_sgn);
    wire a_zero = (a_ftz[30:0] == 31'd0);
    wire b_zero = (b_ftz[30:0] == 31'd0);

    wire a_lt_b = (a_zero & b_zero) ? 1'b0               // ±0 == ±0
                : same_sign ? (a_sgn ? ~a_lt_b_abs & ~a_eq_b_abs : a_lt_b_abs)
                : a_sgn;

    wire a_eq_b = (a_zero & b_zero) ? 1'b1               // ±0 == ±0
                : (same_sign & a_eq_b_abs);

    // 三态编码
    wire [31:0] cmp_raw;   // 三态编码结果

    assign cmp_raw = unordered ? (gt_family ? 32'hFFFFFFFF : 32'd1)  // NaN → ±1
                   : a_lt_b    ? 32'hFFFFFFFF                        // -1
                   : a_eq_b    ? 32'd0                               //  0
                   :             32'd1;                              // +1

    // 输出寄存
    always @(posedge clk) begin
        if (!rst_n || flush) begin
            out_valid <= 1'b0;
            result    <= 32'd0;
        end else begin
            out_valid <= in_valid;
            result    <= cmp_raw;
        end
    end

endmodule
