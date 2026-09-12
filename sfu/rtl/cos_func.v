`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: cos_func
//
// DESCRIPTION: FP32 余弦的固定包装，只需要余弦时使用。算法与流水在 sincos_func，
//   本模块把 is_cos 固定为 1。延迟见 sfu_lat.vh 的 `COS_FUNC_LAT。
//
// NOTE:
//   1. 四分之一周期正弦表在模块外，由调用方例化，与正弦共用同一张表
//   2. 没有零点出口：x=0 时相位加 1024 后索引落在 1023，sin_lut.mem 末项为精确 1.0。
//      denormal 右移饱和归零，走同一个索引。该性质依赖表按闭区间取样
//==============================================================================================//

module cos_func (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        flush,       // 作废在飞运算，清 valid 链
    input  wire [31:0] in_data,
    output wire        out_valid,
    output wire [31:0] out_data,
    output wire [9:0]  bram_addr,   // 组合直连表的地址口
    input  wire [31:0] bram_dout
);

    wire unused_is_cos;
    sincos_func u_sincos (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .flush(flush),
        .is_cos(1'b1), .in_data(in_data),
        .out_valid(out_valid), .out_is_cos(unused_is_cos), .out_data(out_data),
        .bram_addr(bram_addr), .bram_dout(bram_dout)
    );

endmodule
