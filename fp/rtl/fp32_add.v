`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: fp32_add
//
// DESCRIPTION: FP32 加法器，3 级流水（对阶 / 加减+规格化 / 舍入），round-to-nearest-even + FTZ。
//
// NOTE:
//   1. denormal 输入 FTZ 为 ±0；结果 denormal→±0、上溢→±Inf（有意偏离 IEEE 754）
//==============================================================================================//

module fp32_add (
    input             clk,
    input             rst_n,
    input      [31:0] a,
    input      [31:0] b,
    output reg [31:0] s,          // 3 拍后有效
    input             in_valid,
    input             flush,      // 作废在飞运算，清 valid 链
    output reg        out_valid
);

    // valid 影子流水
    reg v1, v2;   // 第 1/2 级有效位
    
    always @(posedge clk) begin
        if (!rst_n || flush) {v1, v2, out_valid} <= 3'b0;
        else                 {v1, v2, out_valid} <= {in_valid, v1, v2};
    end

    // 级1：拆包 + 对阶
    wire        sa = a[31], sb = b[31];                              // a/b 符号位
    wire [7:0]  ea = a[30:23];                                       // a 阶码
    wire [7:0]  eb = b[30:23];                                       // b 阶码
    wire [23:0] ma = (a[30:23] == 8'd0) ? 24'd0 : {1'b1, a[22:0]};   // a 尾数，FTZ + 隐藏位
    wire [23:0] mb = (b[30:23] == 8'd0) ? 24'd0 : {1'b1, b[22:0]};   // b 尾数，FTZ + 隐藏位

    // 特殊值
    wire a_is_nan  = (a[30:23] == 8'd255) && (a[22:0] != 0);
    wire b_is_nan  = (b[30:23] == 8'd255) && (b[22:0] != 0);
    wire a_inf     = (a[30:23] == 8'hFF) && (a[22:0] == 0);
    wire b_inf     = (b[30:23] == 8'hFF) && (b[22:0] == 0);
    wire inf_conflict = a_inf && b_inf && (sa != sb);   // Inf + (-Inf) → qNaN

    // 选大小 + 对齐
    wire        a_ge     = (ea > eb) || ((ea == eb) && (ma >= mb));
    wire        sign_big = a_ge ? sa : sb;
    wire        sign_sml = a_ge ? sb : sa;
    wire [7:0]  exp_big  = a_ge ? ea : eb;
    wire [23:0] mant_big = a_ge ? ma : mb;
    wire [23:0] mant_sml = a_ge ? mb : ma;
    wire [7:0]  diff     = exp_big - (a_ge ? eb : ea);   // 阶码差

    // 小尾数右移对齐 + sticky
    wire [26:0] sml_pre = {mant_sml, 3'b000};                          // 小尾数 GRS 扩展
    wire        d_huge  = (diff >= 8'd27);                             // 超范围移位
    wire [4:0]  shamt   = d_huge ? 5'd27 : diff[4:0];                  // 对阶移位量
    wire [26:0] sml_sh  = sml_pre >> shamt;                            // 移位后小尾数
    wire [26:0] lost_m  = (27'd1 << shamt) - 27'd1;                    // 移出位掩码
    wire        stky_sh = d_huge ? (|sml_pre) : (|(sml_pre & lost_m)); // 对阶粘滞位
    wire [26:0] sml_aln = {sml_sh[26:1], sml_sh[0] | stky_sh};         // 对齐后小尾数
    wire        same_sign = (sign_big == sign_sml);
    wire        sxor = sa ^ sb;                                       // 输入符号异或

    // 级1 寄存器
    reg        s1_a_nan, s1_b_nan, s1_a_inf, s1_b_inf, s1_inf_conflict; // 特殊值状态
    reg        s1_a_ge, s1_sign_big, s1_sign_sml, s1_sxor;              // 大小与符号状态
    reg        s1_same_sign;
    reg [7:0]  s1_exp_big;
    reg [23:0] s1_mant_big;
    reg [26:0] s1_sml_aln;

    always @(posedge clk) begin
        if (!rst_n) begin
            s1_a_nan        <= 1'b0;
            s1_b_nan        <= 1'b0;
            s1_a_inf        <= 1'b0;
            s1_b_inf        <= 1'b0;
            s1_inf_conflict <= 1'b0;
            s1_a_ge         <= 1'b0;
            s1_sign_big     <= 1'b0;
            s1_sign_sml     <= 1'b0;
            s1_sxor         <= 1'b0;
            s1_same_sign    <= 1'b0;
            s1_exp_big      <= 8'd0;
            s1_mant_big     <= 24'd0;
            s1_sml_aln      <= 27'd0;
        end else begin
            s1_a_nan        <= a_is_nan;
            s1_b_nan        <= b_is_nan;
            s1_a_inf        <= a_inf;
            s1_b_inf        <= b_inf;
            s1_inf_conflict <= inf_conflict;
            s1_a_ge         <= a_ge;
            s1_sign_big     <= sign_big;
            s1_sign_sml     <= sign_sml;
            s1_sxor         <= sxor;
            s1_same_sign    <= same_sign;
            s1_exp_big      <= exp_big;
            s1_mant_big     <= mant_big;
            s1_sml_aln      <= sml_aln;
        end
    end

    // 级2：加减 + 规格化
    wire [27:0] big28 = {1'b0, s1_mant_big, 3'b000};                    // 大尾数扩展
    wire [27:0] sml28 = {1'b0, s1_sml_aln};                            // 小尾数扩展
    wire [27:0] raw   = s1_same_sign ? (big28 + sml28) : (big28 - sml28); // 尾数加减结果

    reg  [27:0] norm;                      // 规格化尾数
    reg signed [9:0] exp_n_s;          // 10 位带符号，装下溢/上溢
    reg  [4:0]  lz;                        // 前导零计数
    integer     k;                         // 规格化扫描索引

    always @(*) begin
        lz = 5'd0;
        if (raw[27]) begin
            norm    = {1'b0, raw[27:1]};
            norm[0] = raw[1] | raw[0];   // 低位粘着
            exp_n_s = $signed({2'b0, s1_exp_big}) + 10'sd1;
        end else if (raw[26]) begin
            norm    = raw;
            exp_n_s = $signed({2'b0, s1_exp_big});
        end else begin
            lz = 5'd26;
            for (k = 1; k <= 26; k = k + 1)
                if (raw[k]) lz = 5'd26 - k[4:0];
            norm    = raw << lz;
            exp_n_s = $signed({2'b0, s1_exp_big}) - $signed({5'b0, lz});
        end
    end
    wire raw_zero = (raw == 28'd0);

    // 级2 寄存器
    reg        s2_sign_big, s2_spec_sel, s2_raw_zero, s2_spec_nan, s2_spec_sgn; // 符号与特殊值状态
    reg        s2_same_sign;          // 零结果定符号
    reg signed [9:0] s2_exp_n_s;
    reg [27:0] s2_norm;

    always @(posedge clk) begin
        if (!rst_n) begin
            s2_sign_big  <= 1'b0;
            s2_spec_sel  <= 1'b0;
            s2_raw_zero  <= 1'b0;
            s2_spec_nan  <= 1'b0;
            s2_spec_sgn  <= 1'b0;
            s2_same_sign <= 1'b0;
            s2_exp_n_s   <= 10'sd0;
            s2_norm      <= 28'd0;
        end else begin
            s2_sign_big  <= s1_sign_sml ^ s1_sxor;   // XNOR 重建（勿改 ~s1_sxor）
            s2_same_sign <= ~(s1_sign_big ^ s1_sign_sml);
            s2_spec_sel  <= s1_a_nan | s1_b_nan | s1_a_inf | s1_b_inf;
            s2_spec_nan  <= s1_a_nan | s1_b_nan | s1_inf_conflict;
            s2_spec_sgn  <= (s1_a_inf ^ s1_a_ge) ? s1_sign_sml : s1_sign_big;
            s2_raw_zero  <= raw_zero;
            s2_exp_n_s   <= exp_n_s;
            s2_norm      <= norm;
        end
    end

    // 级3：舍入 + 组装
    wire        round_up = s2_norm[2] & (s2_norm[1] | s2_norm[0] | s2_norm[3]);
    wire [24:0] mant_rnd = {1'b0, s2_norm[26:3]} + {24'd0, round_up}; // 舍入后尾数
    wire        mant_ovf = mant_rnd[24];                              // 尾数进位
    wire [22:0] frac_f   = mant_ovf ? 23'd0 : mant_rnd[22:0];         // 最终小数位
    wire signed [9:0] exp_f_s = s2_exp_n_s + (mant_ovf ? 10'sd1 : 10'sd0); // 最终阶码
    wire ftz_out  = (exp_f_s <= 10'sd0);        // 结果 denormal → ±0
    wire overflow = (exp_f_s >= 10'sd255);      // 上溢 → ±Inf
    wire zero_sgn = s2_sign_big & s2_same_sign; // 异号精确得零 → +0
    wire ftz_sign = s2_raw_zero ? zero_sgn : s2_sign_big;
    wire [31:0] core_res;   // 常规结果
    wire [31:0] spec_res;   // 特殊值结果

    assign core_res = (s2_raw_zero | ftz_out) ? {ftz_sign, 31'd0}
                    : overflow                ? {s2_sign_big, 8'hFF, 23'd0}
                    :                           {s2_sign_big, exp_f_s[7:0], frac_f};
    assign spec_res = s2_spec_nan ? 32'h7FC00000 : {s2_spec_sgn, 8'hFF, 23'd0};

    always @(posedge clk) begin
        if (!rst_n) s <= 32'd0;
        else        s <= s2_spec_sel ? spec_res : core_res;
    end

endmodule
