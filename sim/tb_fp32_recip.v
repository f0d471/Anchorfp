`timescale 1ns/1ps
//==============================================================================================//
// TB: tb_fp32_recip
//
// DESCRIPTION: fp32_recip 与 IEEE 参考比对，数值用例按容差判、特殊值逐位判。
//
// NOTE:
//   1. 容差是设计契约不是迁就实现：这是显式近似原语，误差预算 4 ULP
//   2. 特殊值（±0 / ±Inf / NaN / FTZ）走分类逻辑，没有容差，逐位判死
//   3. 需读 recip_lut.mem，$readmemh 用裸文件名，工作目录须为放表的 rtl/
//==============================================================================================//
module tb_fp32_recip;
    localparam integer TOL_ULP = 4;      // FRECIP 最大误差契约

    reg clk=0, rst_n=0; always #5 clk=~clk;

    reg [31:0] a; reg in_v;
    wire out_v; wire [31:0] res;

    fp32_recip dut (.clk(clk),.rst_n(rst_n),.a(a),.in_valid(in_v), .flush(1'b0),.out_valid(out_v),.result(res));

    integer n_pass=0, n_fail=0;

    function [31:0] ud;
        input [31:0] x, y;
        begin ud = (x>y) ? (x-y) : (y-x); end
    endfunction

    // 特殊值：逐位判死
    task check_exact;
        input [31:0] exp;
        input [255*8:0] name;
        begin
            if (res === exp) begin n_pass=n_pass+1; $display("  PASS: %0s", name); end
            else begin n_fail=n_fail+1;
                $display("  FAIL: %0s got=%08h exp=%08h", name, res, exp); end
        end
    endtask

    // 数值：判容差
    task check_tol;
        input [31:0] exp;
        input [255*8:0] name;
        integer d;
        begin
            d = ud(res, exp);
            if (d <= TOL_ULP) begin
                n_pass=n_pass+1;
                $display("  PASS: %0s (ulp=%0d)", name, d);
            end else begin
                n_fail=n_fail+1;
                $display("  FAIL: %0s got=%08h exp=%08h ulp=%0d > %0d",
                         name, res, exp, d, TOL_ULP);
            end
        end
    endtask

    task do_recip;
        input [31:0] va;
        begin
            @(negedge clk);
            a=va; in_v=1;
            @(negedge clk);
            in_v=0;
            while(!out_v) @(negedge clk);
            @(negedge clk);
        end
    endtask

    initial begin
        rst_n=0; in_v=0; repeat(4)@(posedge clk); rst_n=1; @(posedge clk);

        // ===== 特殊值：逐位 =====
        $display("-- special (bit-exact) --");
        do_recip(32'h00000000); check_exact(32'h7F800000, "1/+0 -> +Inf");
        do_recip(32'h80000000); check_exact(32'hFF800000, "1/-0 -> -Inf");
        do_recip(32'h7F800000); check_exact(32'h00000000, "1/+Inf -> +0");
        do_recip(32'hFF800000); check_exact(32'h80000000, "1/-Inf -> -0");
        do_recip(32'h7FC00000); check_exact(32'h7FC00000, "1/qNaN -> qNaN");
        do_recip(32'hFFC00000); check_exact(32'hFFC00000, "1/-qNaN -> -qNaN");

        // ===== FTZ：逐位 =====
        $display("-- FTZ denormal (bit-exact) --");
        do_recip(32'h00000001); check_exact(32'h7F800000, "1/dmin -> +Inf (FTZ->0)");
        do_recip(32'h80000001); check_exact(32'hFF800000, "1/-dmin -> -Inf (FTZ->0)");
        do_recip(32'h007FFFFF); check_exact(32'h7F800000, "1/dmax -> +Inf (FTZ->0)");
        do_recip(32'h7F7FFFFF); check_exact(32'h00000000, "1/max finite -> +0 (FTZ)");

        // ===== 2 的幂：应当**精确**（1/2^k 可表示，牛顿在这些点无误差）=====
        $display("-- powers of two (bit-exact) --");
        do_recip(32'h3F800000); check_exact(32'h3F800000, "1/1.0 = 1.0");
        do_recip(32'h40000000); check_exact(32'h3F000000, "1/2.0 = 0.5");
        do_recip(32'h40800000); check_exact(32'h3E800000, "1/4.0 = 0.25");
        do_recip(32'h3F000000); check_exact(32'h40000000, "1/0.5 = 2.0");
        do_recip(32'hBF800000); check_exact(32'hBF800000, "1/-1.0 = -1.0");
        do_recip(32'hC0000000); check_exact(32'hBF000000, "1/-2.0 = -0.5");
        do_recip(32'h00800000); check_exact(32'h7E800000, "1/min normal");

        // ===== 非 LUT 格点：落在表项之间才有鉴别力 =====
        //   改前那 18 条定向用例全落在 1024 项表的格点上，纯查表也能逐位对、
        //   鉴别力为零。下面三条落在格点之间，是唯一能验出牛顿迭代真的在算的用例。
        $display("-- off-grid (exercises the Newton step) --");
        do_recip(32'h3F333333); check_tol(32'h3FB6DB6E, "1/1.7");
        do_recip(32'h40490FDB); check_tol(32'h3EA2F983, "1/pi");
        do_recip(32'h3FB504F3); check_tol(32'h3F3504F3, "1/sqrt2");

        run_random("vectors_recip.txt");

        $display("==========================================");
        $display("tb_fp32_recip: %0d PASS, %0d FAIL  (TOL=%0d ULP)", n_pass, n_fail, TOL_ULP);
        if (n_fail==0) $display("ALL PASS");
        else $display("HAS FAILURES");
        $finish;
    end

    localparam MAXN = 300000;
    integer fd, code, i, count, total, bad, ulps, rdp;
    integer max_ulp = 0;
    integer worst_a = 0, worst_got = 0, worst_exp = 0;
    reg mon_en = 0;
    reg [31:0] ta, te;
    reg [31:0] va_q [0:MAXN-1];
    reg [31:0] expq  [0:MAXN-1];

    // 出口监视器：不假设流水深度，固定相位采样在级数改变后会全采空
    always @(posedge clk) begin
        if (mon_en && out_v) begin
            total = total + 1;
            ulps = ud(res, expq[rdp]);
            if (ulps > max_ulp) begin
                max_ulp = ulps; worst_a = va_q[rdp]; worst_got = res; worst_exp = expq[rdp];
            end
            if (ulps > TOL_ULP) begin
                bad = bad + 1;
                if (bad <= 5)
                    $display("  BAD[%0d]: a=%08h got=%08h exp=%08h ulp=%0d",
                             rdp, va_q[rdp], res, expq[rdp], ulps);
            end
            rdp = rdp + 1;
        end
    end

    task run_random;
        input [255*8:0] fname;
        begin
            fd = $fopen(fname, "r");
            if (fd == 0) begin
                $display("  SKIP: %0s 不存在（先跑 gen_recip_vectors）", fname);
                n_fail = n_fail + 1;
            end else begin
                count = 0;
                while (!$feof(fd) && count < MAXN) begin
                    code = $fscanf(fd, "%h %h\n", ta, te);
                    if (code == 2) begin
                        va_q[count] = ta; expq[count] = te;
                        count = count + 1;
                    end
                end
                $fclose(fd);
                $display("  loaded %0d vectors from %0s", count, fname);

                total=0; bad=0; rdp=0; in_v=0;
                rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; @(posedge clk);
                mon_en = 1;
                for (i = 0; i < count; i = i + 1) begin
                    @(negedge clk); a = va_q[i]; in_v = 1;
                    @(negedge clk); in_v = 0;
                end
                repeat(12) @(posedge clk);
                mon_en = 0;

                $display("  random golden: loaded=%0d compared=%0d over-tol=%0d max_ulp=%0d",
                         count, total, bad, max_ulp);
                $display("  worst case: a=%08h got=%08h exp=%08h", worst_a, worst_got, worst_exp);
                // 出队条数必须等于喂入条数，否则是 valid 链错位而不是数值问题
                if (total != count) begin
                    n_fail = n_fail + 1;
                    $display("  FAIL: 出队 %0d != 喂入 %0d（valid 链错位）", total, count);
                end else if (bad == 0) begin
                    n_pass = n_pass + 1;
                    $display("  PASS: %0d 条全部在 %0d ULP 容差内", total, TOL_ULP);
                end else begin
                    n_fail = n_fail + 1;
                    $display("  FAIL: %0d/%0d 超容差", bad, total);
                end
            end
        end
    endtask
endmodule
