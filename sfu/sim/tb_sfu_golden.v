`timescale 1ns / 1ps
//==============================================================================================//
// TESTBENCH: tb_sfu_golden
//
// DESCRIPTION: 逐位对拍的取样台。9500 条固定激励流过四个函数，每条输入与输出写成一行十六进制。
//
// NOTE:
//   1. 本台不做判定，输出 golden.txt 由回归脚本与冻结参考比较，并交独立数学参考复核
//==============================================================================================//

module tb_sfu_golden;

    localparam integer N = 9500;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [31:0] vec [0:N-1];
    integer i;
    integer p;
    real    r;

    initial $readmemh("vec.hex", vec);

    reg         in_valid = 1'b0;
    reg  [31:0] in_data  = 32'b0;

    wire        exp_v,  sin_v,  cos_v,  rsq_v;
    wire [31:0] exp_d,  sin_d,  cos_d,  rsq_d;
    wire [9:0]  sin_a,  cos_a;
    wire [31:0] trig_dout;

    // sin/cos 共享一份 LUT，地址按当前被测对象选（对拍时两者不同时发射）
    reg sel_cos = 1'b0;
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_sin_lut (
        .clk(clk), .addr(sel_cos ? cos_a : sin_a), .dout(trig_dout)
    );

    exp_func   u_exp  (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .flush(1'b0),
                       .in_data(in_data), .out_valid(exp_v), .out_data(exp_d));
    sin_func   u_sin  (.clk(clk), .rst_n(rst_n), .in_valid(in_valid & ~sel_cos), .flush(1'b0),
                       .in_data(in_data), .out_valid(sin_v), .out_data(sin_d),
                       .bram_addr(sin_a), .bram_dout(trig_dout));
    cos_func   u_cos  (.clk(clk), .rst_n(rst_n), .in_valid(in_valid & sel_cos), .flush(1'b0),
                       .in_data(in_data), .out_valid(cos_v), .out_data(cos_d),
                       .bram_addr(cos_a), .bram_dout(trig_dout));
    rsqrt_func u_rsq  (.clk(clk), .rst_n(rst_n), .in_valid(in_valid), .flush(1'b0),
                       .in_data(in_data), .out_valid(rsq_v), .out_data(rsq_d));

    integer f;
    integer k;

    task run_one(input [31:0] x);
        begin
            @(negedge clk); in_data = x; in_valid = 1'b1;
            @(negedge clk); in_valid = 1'b0;
            repeat (10) @(negedge clk);
        end
    endtask

    reg [31:0] got_exp, got_sin, got_cos, got_rsq;
    always @(posedge clk) begin
        if (exp_v) got_exp <= exp_d;
        if (sin_v) got_sin <= sin_d;
        if (cos_v) got_cos <= cos_d;
        if (rsq_v) got_rsq <= rsq_d;
    end

    initial begin
        f = $fopen("golden.txt", "w");
        got_exp = 32'hDEAD_BEEF; got_sin = 32'hDEAD_BEEF;
        got_cos = 32'hDEAD_BEEF; got_rsq = 32'hDEAD_BEEF;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        for (k = 0; k < N; k = k + 1) begin
            sel_cos = 1'b0;
            run_one(vec[k]);
            $fwrite(f, "%04d in=%08x exp=%08x sin=%08x rsqrt=%08x",
                    k, vec[k], got_exp, got_sin, got_rsq);
            sel_cos = 1'b1;                  // cos 单独走一遍，独占共享 LUT
            run_one(vec[k]);
            $fwrite(f, " cos=%08x\n", got_cos);
        end

        $fclose(f);
        $display("tb_sfu_golden: %0d 条激励已写入 golden.txt", N);
        $finish;
    end

endmodule
