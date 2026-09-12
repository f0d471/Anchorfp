`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: rsqrt_func
//
// DESCRIPTION: FP32 平方根倒数，1/sqrt(m * 2^e) = (1/sqrt(m)) * 2^(-e/2)。尾数部分查表，
//   阶码部分按奇偶分两张表以避开半整数次幂。延迟见 sfu_lat.vh 的 `RSQRT_FUNC_LAT。
//
// NOTE:
//   1. 奇数阶码走 (e-1)/2 而不是 (e+1)/2，与 rsqrt_odd_lut.mem 的制表口径一一对应
//   2. 出口的偏置阶码取自表项自身的阶码字段，不是常数 127：
//      1/sqrt(m) 对 m 属于 [1,2) 落在 (0.707,1.0]，表项的阶码字段是 126
//   3. 输入 DAZ：exp 为 0 的位图按同符号零解释，正 denormal 出 +Inf、负 denormal 出 -Inf
//   4. valid 链是 flush 的唯一落点，数据级无条件推进，出口寄存器由末级 valid 门控。
//      表地址由组合逻辑直连 BRAM，可每拍发起一条
//==============================================================================================//

module rsqrt_func (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        flush,       // 作废在飞运算，清 valid 链
    input  wire [31:0] in_data,
    output reg         out_valid,
    output reg  [31:0] out_data
);

    reg v1, v2, v3;   // valid 链，与数据逐级同深度
    always @(posedge clk) begin
        if (!rst_n || flush) {v1, v2, v3, out_valid} <= 4'b0;
        else                 {v1, v2, v3, out_valid} <= {in_valid, v1, v2, v3};
    end

    // s0 组合：拆包与分类
    wire        s0_sign   = in_data[31];
    wire [7:0]  s0_exp_e  = in_data[30:23];
    wire [22:0] s0_mant_e = in_data[22:0];

    // p1：分类结果入寄存器。DAZ：exp 为 0 的位图一律按同符号零解释
    reg        p1_nan, p1_inf, p1_neg, p1_nzero, p1_pzero;
    reg [7:0]  p1_exp_e;
    reg [22:0] p1_mant_e;
    always @(posedge clk) begin
        p1_nan       <= (s0_exp_e == 8'd255 && s0_mant_e != 23'd0);
        p1_inf       <= (s0_exp_e == 8'd255 && s0_mant_e == 23'd0 && !s0_sign);
        p1_neg       <= (s0_sign && s0_exp_e != 8'd0);
        p1_nzero     <= (s0_sign  && s0_exp_e == 8'd0);
        p1_pzero     <= (!s0_sign && s0_exp_e == 8'd0);
        p1_exp_e     <= s0_exp_e;
        p1_mant_e    <= s0_mant_e;
    end

    // p1 组合：阶码奇偶拆分与表地址。地址由 p1 寄存位直连 BRAM。
    wire signed [8:0] e_unbiased = $signed({1'b0, p1_exp_e}) - 9'sd127;
    wire        odd = e_unbiased[0];
    wire [9:0]  idx = p1_mant_e[22:13];
    wire signed [8:0] shift_in = odd ? (e_unbiased - 9'sd1) : e_unbiased;
    wire signed [8:0] shifted  = shift_in >>> 1;
    wire signed [8:0] new_exp_unbiased = -shifted;      // k = -(e/2) 或 -((e-1)/2)

    // p2：阶码增量与旗标入寄存器；与 BRAM 地址采样同拍
    reg        p2_nan, p2_inf, p2_neg, p2_nzero, p2_pzero;
    reg        p2_odd;
    reg signed [8:0] p2_new_exp;

    always @(posedge clk) begin
        p2_nan        <= p1_nan;
        p2_inf        <= p1_inf;
        p2_neg        <= p1_neg;
        p2_nzero      <= p1_nzero;
        p2_pzero      <= p1_pzero;
        p2_odd        <= odd;
        p2_new_exp    <= new_exp_unbiased;
    end

    wire [31:0] bram_even_dout, bram_odd_dout;
    bram_lut_1024x32 #(.Memfile("rsqrt_even_lut.mem")) rsqrt_even (
        .clk(clk), .addr(idx), .dout(bram_even_dout)
    );
    bram_lut_1024x32 #(.Memfile("rsqrt_odd_lut.mem")) rsqrt_odd (
        .clk(clk), .addr(idx), .dout(bram_odd_dout)
    );

    wire [31:0] lut_val = p2_odd ? bram_odd_dout : bram_even_dout;

    // p3：收表
    reg        p3_nan, p3_inf, p3_neg, p3_nzero, p3_pzero;
    reg signed [8:0] p3_new_exp;
    reg [31:0] p3_lut;

    always @(posedge clk) begin
        p3_nan        <= p2_nan;
        p3_inf        <= p2_inf;
        p3_neg        <= p2_neg;
        p3_nzero      <= p2_nzero;
        p3_pzero      <= p2_pzero;
        p3_new_exp    <= p2_new_exp;
        p3_lut        <= lut_val;
    end

    // 出口：偏置阶码 = 表项阶码字段 + k
    wire signed [9:0] neb_full =
        $signed({2'b00, p3_lut[30:23]}) + $signed({p3_new_exp[8], p3_new_exp});
    wire neb_underflow = (neb_full <= 10'sd0);
    wire neb_overflow  = (neb_full >= 10'sd255);
    wire [31:0] normal_result = {1'b0, neb_full[7:0], p3_lut[22:0]};

    always @(posedge clk) begin
        if (!rst_n) begin
            out_data <= 32'b0;
        end else if (v3) begin
            if      (p3_nan)        out_data <= 32'h7FC0_0000;       // 统一 quiet/canonical
            else if (p3_inf)        out_data <= 32'h0000_0000;
            else if (p3_neg)        out_data <= 32'h7FC0_0000;       // 负数无定义，canonical qNaN
            else if (p3_nzero)      out_data <= 32'hFF80_0000;
            else if (p3_pzero)      out_data <= 32'h7F80_0000;
            else if (neb_underflow) out_data <= 32'h0000_0000;
            else if (neb_overflow)  out_data <= 32'h7F80_0000;
            else                    out_data <= normal_result;
        end
    end

endmodule
