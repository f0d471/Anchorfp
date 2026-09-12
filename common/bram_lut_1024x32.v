`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: bram_lut_1024x32
//
// DESCRIPTION: 1024 项 32 位只读查找表，同步读。表内容由 Memfile 指定的 .mem 文件初始化，
//   综合时推断为一块 BRAM36K。
//
// NOTE:
//   1. $readmemh 是 ROM 初值的唯一来源，综合与仿真都依赖它，不是仅供仿真
//   2. Memfile 是裸文件名，综合器与仿真器各按自己的规则查找。找不到时综合只给一条
//      CRITICAL WARNING 并产出无初值的 ROM，仿真读出全 X，集成流程须自行检查表已加载
//   3. 无读使能，每拍无条件读出
//==============================================================================================//

module bram_lut_1024x32 #(
    parameter Memfile = "exp_lut.mem"
) (
    input  wire        clk,
    input  wire [9:0]  addr,
    output reg  [31:0] dout
);

    (* ram_style = "block" *) reg [31:0] mem [0:1023];

    initial begin
        $readmemh(Memfile, mem);
    end

    always @(posedge clk) begin
        dout <= mem[addr];
    end

endmodule
