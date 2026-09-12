`timescale 1ns / 1ps
//==============================================================================================//
// TESTBENCH: tb_sincos_shared
//
// DESCRIPTION: sincos_func 的共享流水回归。SIN 与 COS 每拍交错发起，查顺序、标签、逐位结果与 flush。
//
// NOTE:
//   1. T1 每条都按顺序返回，T2 标签与结果逐位正确，T3 flush 之后不出现有效输出
//==============================================================================================//
`include "sfu_lat.vh"

module tb_sincos_shared;
    reg clk = 1'b0, rst_n = 1'b0, in_valid = 1'b0, flush = 1'b0, is_cos = 1'b0;
    reg [31:0] in_data = 32'b0;
    always #5 clk = ~clk;

    wire out_valid, out_is_cos;
    wire [31:0] out_data;
    wire [9:0] bram_addr;
    wire [31:0] bram_dout;

    sincos_func dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .flush(flush),
        .is_cos(is_cos), .in_data(in_data),
        .out_valid(out_valid), .out_is_cos(out_is_cos), .out_data(out_data),
        .bram_addr(bram_addr), .bram_dout(bram_dout)
    );
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_tab (
        .clk(clk), .addr(bram_addr), .dout(bram_dout)
    );

    localparam integer N = 10;
    reg [31:0] xv [0:N-1];
    reg        cv [0:N-1];
    reg [31:0] ev [0:N-1];
    integer i, rp, errors, checks, leaked;

    task chk(input cond, input [1023:0] name);
        begin
            checks = checks + 1;
            if (cond) $display("  PASS  %0s", name);
            else begin errors = errors + 1; $display("  FAIL  %0s", name); end
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (out_valid && rp < N) begin
            if (out_is_cos !== cv[rp] || out_data !== ev[rp]) begin
                errors = errors + 1;
                $display("  FAIL  item %0d op=%s x=%08x got(tag=%0d,data=%08x) expected=%08x",
                         rp, cv[rp] ? "COS" : "SIN", xv[rp], out_is_cos, out_data, ev[rp]);
            end
            if (^out_data === 1'bx) begin
                errors = errors + 1;
                $display("  FAIL  item %0d contains X", rp);
            end
            rp = rp + 1;
        end else if (out_valid) begin
            leaked = leaked + 1;
        end
    end

    initial begin
        xv[0]=32'h00000000; cv[0]=0; ev[0]=32'h00000000; // sin(+0)
        xv[1]=32'h00000000; cv[1]=1; ev[1]=32'h3f800000; // cos(+0)
        xv[2]=32'h3f800000; cv[2]=0; ev[2]=32'h3f575c64; // sin(+1)
        xv[3]=32'h3f800000; cv[3]=1; ev[3]=32'h3f0a6770; // cos(+1)
        xv[4]=32'hbf800000; cv[4]=0; ev[4]=32'hbf575c64;
        xv[5]=32'hbf800000; cv[5]=1; ev[5]=32'h3f0a6770;
        xv[6]=32'h7f800000; cv[6]=0; ev[6]=32'h7fc00000; // sin(+Inf)
        xv[7]=32'h80800000; cv[7]=0; ev[7]=32'h80000000; // 极小负正常数保留 -0
        xv[8]=32'h7f800001; cv[8]=1; ev[8]=32'h7fc00000; // sNaN quiet/canonical
        xv[9]=32'h48000000; cv[9]=1; ev[9]=32'h7fc00000; // 定义域边界 2^17

        rp = 0; errors = 0; checks = 0; leaked = 0;
        repeat (4) @(negedge clk); rst_n = 1'b1;

        // 连续每拍交错发射；输入和标签都不保持。
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            in_valid = 1'b1; in_data = xv[i]; is_cos = cv[i];
        end
        @(negedge clk); in_valid = 1'b0; in_data = 32'hdeadbeef; is_cos = 1'b0;
        repeat (`SIN_FUNC_LAT + 3) @(negedge clk);
        chk(rp == N, "T1 alternating SIN/COS II=1 returns every item in order");
        chk(errors == 0, "T2 alternating tags and bit-exact results match");

        // 发射后在结果到达前 flush，不能产生幽灵有效。
        @(negedge clk); in_valid = 1'b1; in_data = 32'h3f800000; is_cos = 1'b0;
        @(negedge clk); in_valid = 1'b0; flush = 1'b1;
        @(negedge clk); flush = 1'b0;
        repeat (`SIN_FUNC_LAT + 3) @(negedge clk);
        chk(leaked == 0, "T3 flush kills shared trig in-flight result");

        $display("=====================================================");
        if (errors == 0) $display(" SUMMARY ALL PASS   (%0d checks)", checks);
        else             $display(" SUMMARY %0d FAIL / %0d checks", errors, checks);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #100000;
        $display(" FAIL WATCHDOG tb_sincos_shared timeout");
        $finish;
    end
endmodule
