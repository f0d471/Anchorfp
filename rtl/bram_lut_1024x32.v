`timescale 1ns / 1ps
//==============================================================================================//
// MODULE: bram_lut_1024x32
//
// DESCRIPTION: 1024 项 32 位查找表，同步读，四个超越函数单元共用。表内容由 Memfile 指定的
//   .mem 文件初始化，综合时推断为一块 BRAM36K。
//
// NOTE:
//   1. $readmemh 是 ROM 初值的唯一来源，综合与仿真都依赖它，不是仅供仿真
//   2. Memfile 是裸文件名：综合按本文件所在目录解析，仿真按当前工作目录解析。
//      所有 .mem 必须与本文件同目录，仿真脚本必须先把表拷到工作目录。
//      路径不对时综合只给一条 CRITICAL WARNING，随后产出一块无初值的 ROM
//   3. 无读使能：表是 ROM，每拍无条件读出。曾有过一个 re 端口，仓内每一处例化
//      （RTL 7 处 + TB 5 处）都接常量 1，既没有省电诉求也没有任何一处需要屏蔽读，已删
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
