`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: fp32_cvt
//
// DESCRIPTION: FP32 与 int32 的有符号/无符号转换单元，输出寄存 1 拍。
//
// NOTE:
//   1. I2F 采用 RNE 舍入；F2I 向零截断，denormal/NaN→0，越界时饱和
//==============================================================================================//

module fp32_cvt (
    input             clk,
    input             rst_n,
    input      [31:0] in,           // int32 或 fp32
    input             mode,         // 0=i2f, 1=f2i
    input             is_unsigned,  // 0=signed, 1=unsigned
    input             in_valid,
    input             flush,        // 作废在飞运算，清 valid 链
    output reg        out_valid,
    output reg [31:0] out
);

    // I2F 符号处理
    wire [31:0] i2f_in = in;
    wire        i2f_sgn = !is_unsigned && i2f_in[31];
    wire [31:0] i2f_abs = i2f_sgn ? (~i2f_in + 32'd1) : i2f_in;
    wire        i2f_zero = (i2f_abs == 32'd0);

    // I2F 规格化
    wire [4:0]  i2f_clz;   // 前导零计数

    assign i2f_clz = i2f_abs[31] ? 5'd0  :
                     i2f_abs[30] ? 5'd1  :
                     i2f_abs[29] ? 5'd2  :
                     i2f_abs[28] ? 5'd3  :
                     i2f_abs[27] ? 5'd4  :
                     i2f_abs[26] ? 5'd5  :
                     i2f_abs[25] ? 5'd6  :
                     i2f_abs[24] ? 5'd7  :
                     i2f_abs[23] ? 5'd8  :
                     i2f_abs[22] ? 5'd9  :
                     i2f_abs[21] ? 5'd10 :
                     i2f_abs[20] ? 5'd11 :
                     i2f_abs[19] ? 5'd12 :
                     i2f_abs[18] ? 5'd13 :
                     i2f_abs[17] ? 5'd14 :
                     i2f_abs[16] ? 5'd15 :
                     i2f_abs[15] ? 5'd16 :
                     i2f_abs[14] ? 5'd17 :
                     i2f_abs[13] ? 5'd18 :
                     i2f_abs[12] ? 5'd19 :
                     i2f_abs[11] ? 5'd20 :
                     i2f_abs[10] ? 5'd21 :
                     i2f_abs[9]  ? 5'd22 :
                     i2f_abs[8]  ? 5'd23 :
                     i2f_abs[7]  ? 5'd24 :
                     i2f_abs[6]  ? 5'd25 :
                     i2f_abs[5]  ? 5'd26 :
                     i2f_abs[4]  ? 5'd27 :
                     i2f_abs[3]  ? 5'd28 :
                     i2f_abs[2]  ? 5'd29 :
                     i2f_abs[1]  ? 5'd30 :
                                    5'd31;

    // 阶码与尾数对齐
    wire [7:0]  i2f_exp   = 8'd158 - {3'd0, i2f_clz};
    wire [55:0] i2f_shift = {24'd0, i2f_abs} << ({1'b0, i2f_clz} + 6'd16);

    // RNE 舍入
    wire        i2f_g     = i2f_shift[23];                                      // 舍入保护位
    wire        i2f_s     = |i2f_shift[22:0];                                   // 舍入粘滞位
    wire        i2f_rnd   = i2f_g & (i2f_s | i2f_shift[24]);                    // RNE 舍入进位
    wire [24:0] i2f_mant  = {1'b0, i2f_shift[47:24]} + {24'd0, i2f_rnd};        // 舍入后尾数
    wire        i2f_mant_ovf = i2f_mant[24];                                    // 尾数进位
    wire [7:0]  i2f_exp_f = i2f_exp + {7'd0, i2f_mant_ovf};
    wire [22:0] i2f_frac  = i2f_mant_ovf ? 23'd0 : i2f_mant[22:0];

    // F2I 拆包与特殊值
    wire [31:0] f2i_in = in;
    wire        f2i_sgn = f2i_in[31];
    wire [7:0]  f2i_exp = f2i_in[30:23];
    wire [22:0] f2i_frac = f2i_in[22:0];
    wire        f2i_ftz = (f2i_exp == 8'd0);
    wire        f2i_nan = (f2i_exp == 8'hFF) && (f2i_frac != 0);
    wire [23:0] f2i_mant24 = f2i_ftz ? 24'd0 : {1'b1, f2i_frac};

    // F2I 尾数对齐
    wire signed [8:0] f2i_sh = $signed({1'b0, f2i_exp}) - 9'sd150;   // 尾数移位量
    wire f2i_sh_left = (f2i_sh > 9'sd0);
    wire [8:0] f2i_sh_neg = -f2i_sh;
    wire [5:0] f2i_sh_abs = f2i_sh_left ? f2i_sh[5:0] : f2i_sh_neg[5:0];
    wire [55:0] f2i_pre = {32'd0, f2i_mant24};
    wire [55:0] f2i_shifted = f2i_sh_left ? (f2i_pre << f2i_sh_abs) : (f2i_pre >> f2i_sh_abs);

    // F2I 截断与饱和
    wire        f2i_under  = (f2i_exp < 8'd127);                                // 小于 1
    wire        f2i_over   = (!is_unsigned && (f2i_exp >= 8'd158))
                           || (is_unsigned && (f2i_sgn || (f2i_exp >= 8'd159))); // 饱和条件
    wire [31:0] f2i_mag   = f2i_under ? 32'd0 : f2i_shifted[31:0];
    wire [31:0] f2i_sat_hi = is_unsigned ? 32'hFFFFFFFF : 32'h7FFFFFFF;
    wire [31:0] f2i_sat_lo = is_unsigned ? 32'd0        : 32'h80000000;
    wire [31:0] f2i_pos    = f2i_sgn ? (~f2i_mag + 32'd1) : f2i_mag;             // 符号恢复结果
    wire [31:0] f2i_val;

    assign f2i_val = f2i_nan ? 32'd0
                   : f2i_over ? (f2i_sgn ? f2i_sat_lo : f2i_sat_hi)
                   : f2i_pos;

    // 结果选择
    wire [31:0] i2f_result = i2f_zero ? 32'd0 : {i2f_sgn, i2f_exp_f, i2f_frac};
    wire [31:0] cvt_raw = mode ? f2i_val : i2f_result;

    // 输出寄存
    always @(posedge clk) begin
        if (!rst_n || flush) begin
            out_valid <= 1'b0;
            out       <= 32'd0;
        end else begin
            out_valid <= in_valid;
            out       <= cvt_raw;
        end
    end

endmodule
