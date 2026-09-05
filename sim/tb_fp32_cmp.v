`timescale 1ns/1ps
// tb_fp32_cmp.v —— fp32_cmp 定向TB（[#37] V1-D §3.1）
module tb_fp32_cmp;
    reg clk=0, rst_n=0; always #5 clk=~clk;

    reg [31:0] a, b; reg gt_fam, in_v;
    wire out_v; wire [31:0] res;

    fp32_cmp dut (.clk(clk),.rst_n(rst_n),.a(a),.b(b),.gt_family(gt_fam),
                  .in_valid(in_v), .flush(1'b0),.out_valid(out_v),.result(res));

    integer n_pass=0, n_fail=0;

    task check;
        input [31:0] exp;
        input [255*8:0] name;
        begin
            if (res === exp) begin n_pass=n_pass+1; $display("  PASS: %s", name); end
            else begin n_fail=n_fail+1; $display("  FAIL: %s got=%0d exp=%0d", name, $signed(res), $signed(exp)); end
        end
    endtask

    task do_cmp;
        input [31:0] va, vb;
        input gf;
        begin
            @(negedge clk);
            a=va; b=vb; gt_fam=gf; in_v=1;
            while(!out_v) @(negedge clk);
            @(negedge clk);
            in_v=0;
        end
    endtask

    initial begin
        $dumpfile("/tmp/tb_fp32_cmp.vcd");
        $dumpvars(0, tb_fp32_cmp);

        rst_n=0; in_v=0; repeat(4)@(posedge clk); rst_n=1; @(posedge clk);

        // ===== 常规值 =====
        $display("-- normal --");
        do_cmp(32'h3F800000, 32'h40000000, 0); check(-1, "1.0<2.0 → -1");
        do_cmp(32'h40000000, 32'h3F800000, 0); check(+1, "2.0>1.0 → +1");
        do_cmp(32'h40000000, 32'h40000000, 0); check( 0, "2.0==2.0 → 0");

        // ===== 负数 =====
        $display("-- negative --");
        do_cmp(32'hC0000000, 32'h3F800000, 0); check(-1, "-2 < 1 → -1");
        do_cmp(32'hC0000000, 32'hC0400000, 0); check(+1, "-2 > -3 → +1");
        do_cmp(32'hC0000000, 32'hC0000000, 0); check( 0, "-2 == -2 → 0");

        // ===== ±0 =====
        $display("-- zero --");
        do_cmp(32'h00000000, 32'h80000000, 0); check(0, "+0==-0 → 0");
        do_cmp(32'h80000000, 32'h3F800000, 0); check(-1, "-0<1 → -1");

        // ===== FTZ: denormal→±0 =====
        $display("-- FTZ denormal --");
        do_cmp(32'h00000001, 32'h00000000, 0); check(0, "dmin==0 (FTZ)");
        do_cmp(32'h007FFFFF, 32'h3F800000, 0); check(-1, "dmax<1.0 (FTZ→0<1)");
        do_cmp(32'h00000001, 32'h00000002, 0); check(0, "dmin==dmin2 (both FTZ→0)");

        // ===== Inf =====
        $display("-- Inf --");
        do_cmp(32'h7F800000, 32'h7F7FFFFF, 0); check(+1, "+Inf > max → +1");
        do_cmp(32'hFF800000, 32'h3F800000, 0); check(-1, "-Inf < 1 → -1");
        do_cmp(32'h7F800000, 32'h7F800000, 0); check( 0, "+Inf==+Inf → 0");

        // ===== NaN (lt family: gt_family=0 → unordered→+1) =====
        $display("-- NaN lt family (unordered→+1) --");
        do_cmp(32'h7FC00000, 32'h3F800000, 0); check(+1, "qNaN<1 → +1 (unordered)");
        do_cmp(32'h3F800000, 32'h7FC00000, 0); check(+1, "1<qNaN → +1 (unordered)");
        do_cmp(32'h7FC00000, 32'h7FC00000, 0); check(+1, "qNaN==qNaN → +1 (ne→true)");

        // ===== NaN (gt family: gt_family=1 → unordered→-1) =====
        $display("-- NaN gt family (unordered→-1) --");
        do_cmp(32'h7FC00000, 32'h3F800000, 1); check(-1, "qNaN>1 → -1 (unordered)");
        do_cmp(32'h3F800000, 32'h7FC00000, 1); check(-1, "1>qNaN → -1 (unordered)");

        // ===== signed NaN =====
        do_cmp(32'hFFC00000, 32'h3F800000, 0); check(+1, "-qNaN<1 → +1 (unordered)");

        // ===== [#37] V1-D review 补的缺口 =====
        // ① 负 denormal 的 FTZ 符号（原 TB 只测了正 denormal）
        $display("-- FTZ negative denormal --");
        do_cmp(32'h80000001, 32'h00000000, 0); check(0, "-dmin == +0 (FTZ, ±0相等)");
        do_cmp(32'h80000001, 32'h80000000, 0); check(0, "-dmin == -0 (FTZ)");
        do_cmp(32'h80000001, 32'h00000001, 0); check(0, "-dmin == +dmin (两侧FTZ→±0)");
        do_cmp(32'h807FFFFF, 32'hBF800000, 0); check(+1, "-dmax > -1.0 (FTZ→-0)");
        do_cmp(32'h80800000, 32'h80000001, 0); check(-1, "-最小规格化 < -dmin(FTZ→-0)");

        // ② sNaN（frac 最高位=0）也必须判 unordered
        $display("-- sNaN --");
        do_cmp(32'h7F800001, 32'h3F800000, 0); check(+1, "sNaN<1 → +1 (unordered)");
        do_cmp(32'h7F800001, 32'h3F800000, 1); check(-1, "sNaN>1 → -1 (unordered)");

        // ③ Inf 在 gt 家族下 + 同号 Inf
        $display("-- Inf gt family / -Inf --");
        do_cmp(32'h7F800000, 32'hFF800000, 1); check(+1, "+Inf > -Inf (gt fam, ordered)");
        do_cmp(32'hFF800000, 32'hFF800000, 1); check( 0, "-Inf == -Inf");
        do_cmp(32'h7F800000, 32'h7FC00000, 1); check(-1, "+Inf vs NaN → -1 (gt fam)");
        do_cmp(32'hFF800000, 32'hFF7FFFFF, 0); check(-1, "-Inf < -max finite");

        // ===== 随机金标准对拍（vectors_cmp.txt，见 gen_cmp_vectors.c）=====
        run_random("vectors_cmp.txt");

        $display("==========================================");
        $display("tb_fp32_cmp: %0d PASS, %0d FAIL", n_pass, n_fail);
        if (n_fail==0) $display("ALL PASS");
        else $display("HAS FAILURES");
        $finish;
    end

    // ---- 随机向量对拍：a b gt_family expected（全 hex）----
    // 流水延迟 1 拍，按 SOP §2.3 用 FIFO 出队比对（对任意延迟 robust）。
    localparam MAXN = 300000;
    integer fd, code, i, count, total, bad, rdp;
    reg [31:0] ta, tb_, tgf, te;
    reg [31:0] va_q [0:MAXN-1];
    reg [31:0] vb_q [0:MAXN-1];
    reg        gf_q [0:MAXN-1];
    reg [31:0] expq [0:MAXN-1];

    task run_random;
        input [255*8:0] fname;
        begin
            fd = $fopen(fname, "r");
            if (fd == 0) begin
                $display("  SKIP: %0s 不存在（先跑 gen_cmp_vectors）", fname);
                n_fail = n_fail + 1;
            end else begin
                // 第一遍：全部载入数组（与 tb_fp_ftz 同范式，避免边读边喂的 EOF 竞态）
                count = 0;
                while (!$feof(fd) && count < MAXN) begin
                    code = $fscanf(fd, "%h %h %h %h\n", ta, tb_, tgf, te);
                    if (code == 4) begin
                        va_q[count] = ta; vb_q[count] = tb_;
                        gf_q[count] = tgf[0]; expq[count] = te;
                        count = count + 1;
                    end
                end
                $fclose(fd);
                $display("  loaded %0d vectors from %0s", count, fname);

                // 第二遍：逐拍喂 + out_valid 出队比对（延迟 1 拍，FIFO 范式）
                total=0; bad=0; rdp=0;
                in_v = 0;
                rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; @(posedge clk);
                for (i = 0; i < count + 4; i = i + 1) begin
                    @(negedge clk);
                    if (i < count) begin
                        a = va_q[i]; b = vb_q[i]; gt_fam = gf_q[i]; in_v = 1;
                    end else in_v = 0;
                    @(posedge clk);
                    if (out_v) begin
                        total = total + 1;
                        if (res !== expq[rdp]) begin
                            bad = bad + 1;
                            if (bad <= 5)
                                $display("  BAD[%0d]: a=%08h b=%08h gf=%0d got=%0d exp=%0d",
                                         rdp, va_q[rdp], vb_q[rdp], gf_q[rdp],
                                         $signed(res), $signed(expq[rdp]));
                        end
                        rdp = rdp + 1;
                    end
                end
                $display("  random golden: loaded=%0d compared=%0d bad=%0d", count, total, bad);
                if (bad == 0 && total > 0) begin
                    n_pass = n_pass + 1;
                    $display("  PASS: fp32_cmp vs IEEE(FTZ) golden %0d vectors", total);
                end else begin
                    n_fail = n_fail + 1;
                    $display("  FAIL: fp32_cmp random golden");
                end
            end
        end
    endtask
endmodule
