`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: exp_func
//
// DESCRIPTION: FP32 指数函数，exp(x) = 2^(x*log2(e)) = 2^n * 2^f。整数部分 n 直接加进阶码，
//   小数部分 f 查 1024 项表。延迟见 sfu_lat.vh 的 `EXP_FUNC_LAT。
//
// NOTE:
//   1. 输入 DAZ：denormal 按同符号零解释，exp(±0)=1
//   2. 定点化覆盖 |x| < 128，该范围外 exp 本身已上溢或下溢
//   3. 常数乘法与 n/idx 提取位于同一级。乘法由 DSP 实现，提取逻辑只包含位选、加减和比较
//   4. s1d 与 BRAM 读并行，用于对齐表数据与控制字段；移除后会把相邻输入的数据与控制字段配错
//   5. valid 链是 flush 的唯一落点，数据级无条件推进，出口寄存器由末级 valid 门控
//==============================================================================================//

module exp_func (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        flush,       // 作废在飞运算，清 valid 链
    input  wire [31:0] in_data,
    output reg         out_valid,
    output reg  [31:0] out_data
);

    // p0 组合：拆包 + Q8.20 定点化
    wire        c_sign     = in_data[31];
    wire [7:0]  c_exp_e    = in_data[30:23];
    wire [22:0] c_mant_e   = in_data[22:0];

    wire c_flag_nan     = (c_exp_e == 8'd255 && c_mant_e != 23'd0);
    wire c_flag_pos_inf = (c_exp_e == 8'd255 && c_mant_e == 23'd0 && !c_sign);
    wire c_flag_neg_inf = (c_exp_e == 8'd255 && c_mant_e == 23'd0 && c_sign);
    wire c_flag_zero    = (c_exp_e == 8'd0);                                   // 含 denormal，输入 DAZ

    wire [23:0] mant24    = {1'b1, c_mant_e};
    wire [27:0] mant24_28 = {4'd0, mant24};
    wire signed [8:0] real_exp = $signed({1'b0, c_exp_e}) - 9'sd127;

    wire real_exp_ge_7 = (real_exp >= 9'sd7);            // |x| >= 128，走上溢/下溢分支
    wire [3:0] lsh = real_exp[3:0] - 4'd3;               // real_exp 在 3..6 时为 0..3
    wire signed [8:0] rsh = 9'sd3 - real_exp;            // real_exp < 3 时为正

    // x_fix = |x| * 2^20，左移右移两个方向都要支持
    wire [27:0] c_x_fix_u = real_exp_ge_7        ? 28'h7FF_FFFF :
                            (real_exp >= 9'sd3)  ? (mant24_28 << lsh) :
                            (rsh > 9'sd27)       ? 28'd0 :
                                                   (mant24_28 >> rsh[5:0]);

    reg v0, v1, v2, v3;   // valid 链，与数据逐级同深度

    reg        p0_sign, p0_flag_nan, p0_flag_pos_inf, p0_flag_neg_inf, p0_flag_zero;
    reg [27:0] p0_x_fix_u;
    reg [31:0] p0_in_data;

    always @(posedge clk) begin
        if (!rst_n || flush) begin
            v0 <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
            out_valid <= 1'b0;
        end else begin
            v0 <= in_valid;
            v1 <= v0;
            v2 <= v1;
            v3 <= v2;
            out_valid <= v3;
        end
    end

    always @(posedge clk) begin
        p0_sign         <= c_sign;
        p0_flag_nan     <= c_flag_nan;
        p0_flag_pos_inf <= c_flag_pos_inf;
        p0_flag_neg_inf <= c_flag_neg_inf;
        p0_flag_zero    <= c_flag_zero;
        p0_x_fix_u      <= c_x_fix_u;
        p0_in_data      <= in_data;
    end

    // s1 组合：常数乘法后直接提取 n / idx，并完成符号修正与边界判定
    localparam [20:0] Log2eQ120 = 21'h17_1547;    // round(log2(e) * 2^20)，Q1.20

    wire [48:0] product = p0_x_fix_u * Log2eQ120;
    wire [28:0] y_raw = product[48:20];    // 低 20 位是被丢弃的小数尾
    wire [7:0] n_unsigned = y_raw[27:20];
    wire [9:0] frac_idx   = y_raw[19:10];

    // exp_lut 按区间中点取样。负数镜像：(n, idx) = (-n-1, 1023-idx)。
    // 1023 而非 1024 是中点表的互补关系，取样口径以表生成器为准
    wire [7:0] neg_nm1 = ~(n_unsigned + 8'd1) + 8'd1;

    wire signed [7:0] c_n_signed = p0_sign
        ? neg_nm1
        : n_unsigned;
    wire [9:0] c_idx = p0_sign
        ? (10'd1023 - frac_idx)
        : frac_idx;

    wire c_flag_underflow = p0_sign && (n_unsigned >= 8'd126);
    wire c_flag_overflow  = !p0_sign && (n_unsigned >= 8'd128);

    reg        s1_flag_nan, s1_flag_pos_inf, s1_flag_neg_inf, s1_flag_zero;
    reg        s1_flag_underflow, s1_flag_overflow;
    reg signed [7:0] s1_n_signed;
    reg [9:0]  s1_idx;
    reg [31:0] s1_in_data;

    always @(posedge clk) begin
        s1_flag_nan       <= p0_flag_nan;
        s1_flag_pos_inf   <= p0_flag_pos_inf;
        s1_flag_neg_inf   <= p0_flag_neg_inf;
        s1_flag_zero      <= p0_flag_zero;
        s1_flag_underflow <= c_flag_underflow;
        s1_flag_overflow  <= c_flag_overflow;
        s1_n_signed       <= c_n_signed;
        s1_idx            <= c_idx;
        s1_in_data        <= p0_in_data;
    end

    // 查表：2^f
    wire [31:0] bram_dout;
    bram_lut_1024x32 #(.Memfile("exp_lut.mem")) exp_lut (
        .clk(clk), .addr(s1_idx), .dout(bram_dout)
    );

    // s1d：与 BRAM 读并行的一级，把旗标推到与表数据同拍
    reg        s1d_flag_nan, s1d_flag_pos_inf, s1d_flag_neg_inf, s1d_flag_zero;
    reg        s1d_flag_underflow, s1d_flag_overflow;
    reg signed [7:0] s1d_n_signed;
    reg [31:0] s1d_in_data;

    always @(posedge clk) begin
        s1d_flag_nan       <= s1_flag_nan;
        s1d_flag_pos_inf   <= s1_flag_pos_inf;
        s1d_flag_neg_inf   <= s1_flag_neg_inf;
        s1d_flag_zero      <= s1_flag_zero;
        s1d_flag_underflow <= s1_flag_underflow;
        s1d_flag_overflow  <= s1_flag_overflow;
        s1d_n_signed       <= s1_n_signed;
        s1d_in_data        <= s1_in_data;
    end

    // s2：收表
    reg        s2_flag_nan, s2_flag_pos_inf, s2_flag_neg_inf, s2_flag_zero;
    reg        s2_flag_underflow, s2_flag_overflow;
    reg signed [7:0] s2_n_signed;
    reg [31:0] s2_lut_val, s2_in_data;

    always @(posedge clk) begin
        s2_flag_nan       <= s1d_flag_nan;
        s2_flag_pos_inf   <= s1d_flag_pos_inf;
        s2_flag_neg_inf   <= s1d_flag_neg_inf;
        s2_flag_zero      <= s1d_flag_zero;
        s2_flag_underflow <= s1d_flag_underflow;
        s2_flag_overflow  <= s1d_flag_overflow;
        s2_n_signed       <= s1d_n_signed;
        s2_lut_val        <= bram_dout;
        s2_in_data        <= s1d_in_data;
    end

    // 出口：把 n 加进表项的阶码
    wire [7:0]  lut_exp  = s2_lut_val[30:23];
    wire [22:0] lut_mant = s2_lut_val[22:0];
    wire [7:0]  abs_n    = ~s2_n_signed + 8'd1;
    wire [7:0]  exp_sub  = (lut_exp < abs_n) ? 8'd0 : (lut_exp - abs_n);
    wire [8:0]  exp_add  = {1'b0, lut_exp} + {1'b0, s2_n_signed[7:0]};
    wire [7:0]  new_exp  = s2_n_signed[7]
        ? exp_sub
        : ((exp_add > 9'd254) ? 8'd255 : exp_add[7:0]);
    wire [31:0] normal_result = {1'b0, new_exp, lut_mant};

    always @(posedge clk) begin
        if (!rst_n) begin
            out_data <= 32'b0;
        end else if (v3) begin
            if      (s2_flag_nan)       out_data <= 32'h7FC0_0000;  // NaN 统一 quiet/canonical
            else if (s2_flag_pos_inf)   out_data <= 32'h7F80_0000;
            else if (s2_flag_zero)      out_data <= 32'h3F80_0000;  // exp(0) = 1
            else if (s2_flag_neg_inf)   out_data <= 32'h0000_0000;
            else if (s2_flag_underflow) out_data <= 32'h0000_0000;
            else if (s2_flag_overflow)  out_data <= 32'h7F80_0000;
            else                        out_data <= normal_result;
        end
    end

endmodule
