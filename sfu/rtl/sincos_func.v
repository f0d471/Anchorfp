`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: sincos_func
//
// DESCRIPTION: FP32 正弦与余弦共用的两拍流水。is_cos 逐拍选择相位偏移，操作标签随 valid
//   传到出口，SIN 与 COS 交错发射仍可每拍发起一条。延迟见 sfu_lat.vh 的 `SIN_FUNC_LAT。
//
// NOTE:
//   1. 四分之一周期正弦表在模块外，由调用方例化并连接 bram_addr / bram_dout
//   2. 零点出口只对 sin 生效，用于保住 -0 的符号；cos 的正常通路在零点读表末项，即精确 1.0
//   3. valid 链是 flush 的唯一落点，数据级无条件推进，出口寄存器由末级 valid 门控
//==============================================================================================//

module sincos_func (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        flush,       // 作废在飞运算，清 valid 链
    input  wire        is_cos,      // 0 为正弦，1 为余弦，随 in_valid 同拍给出
    input  wire [31:0] in_data,
    output reg         out_valid,
    output reg         out_is_cos,  // 与 out_data 同拍的操作标签
    output reg  [31:0] out_data,
    output wire [9:0]  bram_addr,   // 组合直连表的地址口
    input  wire [31:0] bram_dout
);

    wire c_nan, c_inf, c_zero, c_domain, c_sign, c_res_sign;
    trig_phase_reduce u_reduce (
        .in_data  (in_data),
        .is_cos   (is_cos),
        .f_nan    (c_nan),
        .f_inf    (c_inf),
        .f_zero   (c_zero),
        .f_domain (c_domain),
        .sign     (c_sign),
        .idx      (bram_addr),
        .res_sign (c_res_sign)
    );

    reg s0_valid;
    always @(posedge clk) begin
        if (!rst_n || flush) {s0_valid, out_valid} <= 2'b0;
        else                 {s0_valid, out_valid} <= {in_valid, s0_valid};
    end

    reg s0_is_cos, s0_nan, s0_inf, s0_zero, s0_domain, s0_sign, s0_res_sign;
    always @(posedge clk) begin
        s0_is_cos  <= is_cos;
        s0_nan      <= c_nan;
        s0_inf      <= c_inf;
        s0_zero     <= c_zero;
        s0_domain   <= c_domain;
        s0_sign     <= c_sign;
        s0_res_sign <= c_res_sign;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            out_is_cos <= 1'b0;
            out_data   <= 32'b0;
        end else if (s0_valid) begin
            out_is_cos <= s0_is_cos;
            if (s0_nan | s0_inf | s0_domain)
                out_data <= 32'h7FC0_0000;
            else if (!s0_is_cos && s0_zero)
                out_data <= {s0_sign, 31'b0};
            else
                out_data <= {s0_res_sign, bram_dout[30:0]};
        end
    end

endmodule
