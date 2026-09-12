`timescale 1ns / 1ps
//==============================================================================================//
// FILE: ooc_tops.v
//
// DESCRIPTION: 离线综合用的顶层包装，把 sincos_func 在模块外的正弦表连上，仅供 syn/ 使用。
//
// NOTE:
//   1. sincos_lut：sincos_func 加一块正弦表，即正弦与余弦共用一条流水的形态
//   2. trig_split：sin_func 与 cos_func 各带一块表且共用同一路输入，作对照
//   3. trig_split_sep：同上但两路输入相互独立，综合器无法合并两份相位乘法，作对照
//==============================================================================================//

module sincos_lut (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire        flush,
    input  wire        is_cos,
    input  wire [31:0] in_data,
    output wire        out_valid,
    output wire        out_is_cos,
    output wire [31:0] out_data
);
    wire [9:0]  addr;
    wire [31:0] dout;

    sincos_func u_sincos (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .flush(flush),
        .is_cos(is_cos), .in_data(in_data),
        .out_valid(out_valid), .out_is_cos(out_is_cos), .out_data(out_data),
        .bram_addr(addr), .bram_dout(dout)
    );
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_tab (
        .clk(clk), .addr(addr), .dout(dout)
    );
endmodule

module trig_split (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sin_valid,
    input  wire        cos_valid,
    input  wire        flush,
    input  wire [31:0] in_data,
    output wire        sin_out_valid,
    output wire [31:0] sin_out_data,
    output wire        cos_out_valid,
    output wire [31:0] cos_out_data
);
    wire [9:0]  sin_addr, cos_addr;
    wire [31:0] sin_dout, cos_dout;

    sin_func u_sin (
        .clk(clk), .rst_n(rst_n), .in_valid(sin_valid), .flush(flush), .in_data(in_data),
        .out_valid(sin_out_valid), .out_data(sin_out_data),
        .bram_addr(sin_addr), .bram_dout(sin_dout)
    );
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_sin_tab (
        .clk(clk), .addr(sin_addr), .dout(sin_dout)
    );

    cos_func u_cos (
        .clk(clk), .rst_n(rst_n), .in_valid(cos_valid), .flush(flush), .in_data(in_data),
        .out_valid(cos_out_valid), .out_data(cos_out_data),
        .bram_addr(cos_addr), .bram_dout(cos_dout)
    );
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_cos_tab (
        .clk(clk), .addr(cos_addr), .dout(cos_dout)
    );
endmodule

module trig_split_sep (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sin_valid,
    input  wire        cos_valid,
    input  wire        flush,
    input  wire [31:0] sin_data,
    input  wire [31:0] cos_data,
    output wire        sin_out_valid,
    output wire [31:0] sin_out_data,
    output wire        cos_out_valid,
    output wire [31:0] cos_out_data
);
    wire [9:0]  sin_addr, cos_addr;
    wire [31:0] sin_dout, cos_dout;

    sin_func u_sin (
        .clk(clk), .rst_n(rst_n), .in_valid(sin_valid), .flush(flush), .in_data(sin_data),
        .out_valid(sin_out_valid), .out_data(sin_out_data),
        .bram_addr(sin_addr), .bram_dout(sin_dout)
    );
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_sin_tab (
        .clk(clk), .addr(sin_addr), .dout(sin_dout)
    );

    cos_func u_cos (
        .clk(clk), .rst_n(rst_n), .in_valid(cos_valid), .flush(flush), .in_data(cos_data),
        .out_valid(cos_out_valid), .out_data(cos_out_data),
        .bram_addr(cos_addr), .bram_dout(cos_dout)
    );
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_cos_tab (
        .clk(clk), .addr(cos_addr), .dout(cos_dout)
    );
endmodule
