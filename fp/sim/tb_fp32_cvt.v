`timescale 1ns/1ps
//==============================================================================================//
// TB: tb_fp32_cvt
//
// DESCRIPTION: fp32_cvt 双向转换的定向用例，覆盖舍入、饱和与特殊值。
//
// NOTE:
//   1. i2f 走 RNE，f2i 向零截断，两个方向的判据不同
//   2. 越界饱和到 INT32_MIN / INT32_MAX / UINT32_MAX
//==============================================================================================//
module tb_fp32_cvt;
    reg clk=0, rst_n=0; always #5 clk=~clk;

    reg [31:0] in; reg mode, unsg, in_v;
    wire out_v; wire [31:0] out;

    fp32_cvt dut (.clk(clk),.rst_n(rst_n),.in(in),.mode(mode),.is_unsigned(unsg),
                  .in_valid(in_v), .flush(1'b0),.out_valid(out_v),.out(out));

    integer n_pass=0, n_fail=0;

    task check;
        input [31:0] exp;
        input [255*8:0] name;
        begin
            if (out === exp) begin n_pass=n_pass+1; $display("  PASS: %s", name); end
            else begin n_fail=n_fail+1; $display("  FAIL: %s got=%08h exp=%08h", name, out, exp); end
        end
    endtask

    task do_cvt;
        input [31:0] vin; input md, ug;
        begin
            @(negedge clk);
            in=vin; mode=md; unsg=ug; in_v=1;
            while(!out_v) @(negedge clk);
            @(negedge clk);
            in_v=0;
        end
    endtask

    initial begin
        $dumpfile("/tmp/tb_fp32_cvt.vcd");
        $dumpvars(0, tb_fp32_cvt);

        rst_n=0; in_v=0; repeat(4)@(posedge clk); rst_n=1; @(posedge clk);

        // ===== i2f 常规值 =====
        $display("-- i2f normal --");
        do_cvt(32'd0,    0,0); check(32'h00000000, "0 → +0");
        do_cvt(32'd1,    0,0); check(32'h3F800000, "1 → 1.0");
        do_cvt(32'd2,    0,0); check(32'h40000000, "2 → 2.0");
        do_cvt(32'd3,    0,0); check(32'h40400000, "3 → 3.0");
        do_cvt(32'd127,  0,0); check(32'h42FE0000, "127 → 127.0");
        do_cvt(32'd255,  0,0); check(32'h437F0000, "255 → 255.0");

        // ===== i2f 大整数 =====
        $display("-- i2f large --");
        do_cvt(32'h40000000, 0,0); check(32'h4E800000, "2^30 = 1073741824.0");
        do_cvt(32'h7FFFFFFF, 0,0); check(32'h4F000000, "INT32_MAX → 2^31 (RNE up)");

        // ===== i2f 负数 =====
        $display("-- i2f negative --");
        do_cvt(32'hFFFFFFFF, 0,0); check(32'hBF800000, "-1 → -1.0");
        do_cvt(32'h80000000, 0,0); check(32'hCF000000, "INT32_MIN → -2^31");

        // ===== i2f unsigned =====
        $display("-- i2f unsigned --");
        do_cvt(32'h80000000, 0,1); check(32'h4F000000, "0x80000000→2^31");
        do_cvt(32'hFFFFFFFF, 0,1); check(32'h4F800000, "UINT32_MAX→2^32(RNE)");

        // ===== f2i 常规值 =====
        $display("-- f2i normal --");
        do_cvt(32'h00000000, 1,0); check(32'd0,      "+0 → 0");
        do_cvt(32'h80000000, 1,0); check(32'd0,      "-0 → 0");
        do_cvt(32'h3F800000, 1,0); check(32'd1,      "1.0 → 1");
        do_cvt(32'hBF800000, 1,0); check(32'hFFFFFFFF,"-1.0 → -1");
        do_cvt(32'h40000000, 1,0); check(32'd2,      "2.0 → 2");
        do_cvt(32'hC0000000, 1,0); check(32'hFFFFFFFE,"-2.0 → -2");

        // ===== f2i 向零截断 =====
        $display("-- f2i trunc --");
        do_cvt(32'h3FC00000, 1,0); check(32'd1,      "1.5 → 1 (trunc)");
        do_cvt(32'hBFC00000, 1,0); check(32'hFFFFFFFF,"-1.5 → -1 (trunc)");
        do_cvt(32'h3F000000, 1,0); check(32'd0,      "0.5 → 0 (trunc)");
        do_cvt(32'hBF000000, 1,0); check(32'd0,      "-0.5 → 0 (trunc)");

        // ===== f2i 边界 =====
        $display("-- f2i bounds --");
		do_cvt(32'h4F000000, 1,0); check(32'h7FFFFFFF,"2^31 → INT32_MAX(saturate)");
        do_cvt(32'h7F7FFFFF, 1,0); check(32'h7FFFFFFF,"max finite → INT32_MAX");
        do_cvt(32'h7F800000, 1,0); check(32'h7FFFFFFF,"+Inf → INT32_MAX");
        do_cvt(32'hFF800000, 1,0); check(32'h80000000,"-Inf → INT32_MIN");

        // ===== f2i NaN =====
        $display("-- f2i NaN --");
        do_cvt(32'h7FC00000, 1,0); check(32'd0,      "qNaN → 0");
        do_cvt(32'h7F800001, 1,0); check(32'd0,      "sNaN → 0");

        // ===== f2i unsigned =====
        $display("-- f2i unsigned --");
        do_cvt(32'h3F800000, 1,1); check(32'd1,      "1.0→1u");
        do_cvt(32'h4F000000, 1,1); check(32'h80000000,"2^31→2^31");
        do_cvt(32'h4F800000, 1,1); check(32'hFFFFFFFF,"2^32→UINT32_MAX");
        do_cvt(32'hBF800000, 1,1); check(32'd0,      "-1.0→0u (clamp)");

        // ===== FTZ denormal → 0 =====
        $display("-- f2i FTZ --");
        do_cvt(32'h00000001, 1,0); check(32'd0,      "dmin→0 (FTZ)");
        do_cvt(32'h007FFFFF, 1,0); check(32'd0,      "dmax→0 (FTZ)");
        do_cvt(32'h80000001, 1,0); check(32'd0,      "-dmin→0 (FTZ)");

        // ===== 随机金标准对拍 =====
        run_random("vectors_cvt.txt");

        $display("==========================================");
        $display("tb_fp32_cvt: %0d PASS, %0d FAIL", n_pass, n_fail);
        if (n_fail==0) $display("ALL PASS");
        else $display("HAS FAILURES");
        $finish;
    end

    localparam MAXN = 300000;
    integer fd, code, i, count, total, bad, rdp;
    reg [31:0] ta, tb_, tm, tu, te;
    reg [31:0] va_q [0:MAXN-1];
    reg        md_q  [0:MAXN-1];
    reg        ug_q  [0:MAXN-1];
    reg [31:0] expq  [0:MAXN-1];

    task run_random;
        input [255*8:0] fname;
        begin
            fd = $fopen(fname, "r");
            if (fd == 0) begin
                $display("  SKIP: %0s 不存在（先跑 gen_cvt_vectors）", fname);
                n_fail = n_fail + 1;
            end else begin
                count = 0;
                while (!$feof(fd) && count < MAXN) begin
                    code = $fscanf(fd, "%h %h %h %h\n", ta, tm, tu, te);
                    if (code == 4) begin
                        va_q[count] = ta; md_q[count] = tm[0]; ug_q[count] = tu[0]; expq[count] = te;
                        count = count + 1;
                    end
                end
                $fclose(fd);
                $display("  loaded %0d vectors from %0s", count, fname);

                total=0; bad=0; rdp=0;
                in_v = 0;
                rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; @(posedge clk);
                for (i = 0; i < count + 4; i = i + 1) begin
                    @(negedge clk);
                    if (i < count) begin
                        in = va_q[i]; mode = md_q[i]; unsg = ug_q[i]; in_v = 1;
                    end else in_v = 0;
                    @(posedge clk);
                    if (out_v) begin
                        total = total + 1;
                        if (out !== expq[rdp]) begin
                            bad = bad + 1;
                            if (bad <= 5)
                                $display("  BAD[%0d]: in=%08h mode=%0d u=%0d got=%08h exp=%08h",
                                         rdp, va_q[rdp], md_q[rdp], ug_q[rdp], out, expq[rdp]);
                        end
                        rdp = rdp + 1;
                    end
                end
                $display("  random golden: loaded=%0d compared=%0d bad=%0d", count, total, bad);
                if (bad == 0 && total > 0) begin
                    n_pass = n_pass + 1;
                    $display("  PASS: fp32_cvt vs IEEE golden %0d vectors", total);
                end else begin
                    n_fail = n_fail + 1;
                end
            end
        end
    endtask
endmodule
