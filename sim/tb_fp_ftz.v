`timescale 1ns/1ps
// tb_fp_ftz.v —— fp32_add+fpmul FTZ语义定向TB（[#37] V1-C §7.2/§7.2b）
// 18条定向用例 + add/mul各20万全域随机 FTZ金标准

module tb_fp_ftz;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;

    // ===== add DUT =====
    reg [31:0] add_a, add_b; reg add_in;
    wire [31:0] add_s; wire add_out;
    fp32_add u_add (.clk(clk),.rst_n(rst_n),.a(add_a),.b(add_b),.s(add_s),
                    .in_valid(add_in), .flush(1'b0),.out_valid(add_out));

    // ===== mul DUT =====
    reg [31:0] mul_a, mul_b; reg mul_in;
    wire [31:0] mul_p; wire mul_out;
    fp32_mul_pipe u_mul (.clk(clk),.rst_n(rst_n),.a(mul_a),.b(mul_b),.p(mul_p),
                         .in_valid(mul_in), .flush(1'b0),.out_valid(mul_out));

    integer n_pass=0, n_fail=0;

    function integer ud(input [31:0] x,input [31:0] y);
        ud = (x>=y) ? (x-y) : (y-x);
    endfunction

    function integer is_nan(input [31:0] x);
        is_nan = ((x & 32'h7F800000) == 32'h7F800000) && ((x & 32'h007FFFFF) != 0);
    endfunction

    task check;
        input [31:0] got, exp;
        input [255*8:0] name;
        begin
            if (is_nan(exp)) begin
                if (is_nan(got)) begin n_pass=n_pass+1; $display("  PASS(NaN): %s", name); end
                else begin n_fail=n_fail+1; $display("  FAIL(NaN): %s got=%08x (exp NaN)", name, got); end
            end else begin
                if (got === exp) begin n_pass=n_pass+1; $display("  PASS: %s", name); end
                else begin n_fail=n_fail+1; $display("  FAIL: %s got=%08x exp=%08x", name, got, exp); end
            end
        end
    endtask

    integer cycle;
    always @(posedge clk) cycle <= cycle + 1;

    task send_add;
        input [31:0] a, b;
        output [31:0] rdat;
        begin
            while (add_out) @(negedge clk);       // 排空旧valid尾
            @(negedge clk);
            add_a = a; add_b = b; add_in = 1;
            while (!add_out) @(negedge clk);
            rdat = add_s;
            @(negedge clk);
            add_in = 0;
        end
    endtask

    task send_mul;
        input [31:0] a, b;
        output [31:0] rdat;
        begin
            while (mul_out) @(negedge clk);       // 排空旧valid尾
            @(negedge clk);
            mul_a = a; mul_b = b; mul_in = 1;
            while (!mul_out) @(negedge clk);
            rdat = mul_p;
            @(negedge clk);
            mul_in = 0;
        end
    endtask

    reg [31:0] rd;

    // ===== FTZ 全域随机金标准（FIFO队列比对）=====
    localparam MAXN = 210000;
    reg [31:0] expq[0:MAXN-1];
    integer wr, rdp, total, exact, bad;
    integer count, i, fd, code;
    reg [31:0] ta, tbb, te;

    task run_ftz_random;
        input [255*8:0] fname;
        input [255*8:0] label;
        input is_mul;
        begin
            count=0; fd=$fopen(fname,"r");
            if(fd==0) begin $display("ERR open %s", fname); $finish; end
            while(!$feof(fd) && count<MAXN) begin
                code=$fscanf(fd,"%h %h %h\n",ta,tbb,te);
                if(code==3) begin count=count+1; end
            end
            $fclose(fd); $display("== %s: loaded %0d vectors ==", label, count);

            total=0;exact=0;bad=0;wr=0;rdp=0;
            add_in=0; mul_in=0;
            rst_n=0; repeat(4)@(posedge clk); rst_n=1; @(posedge clk);

            fd=$fopen(fname,"r");
            for(i=0;i<count+10;i=i+1) begin
                @(negedge clk);
                if(i<count) begin
                    code=$fscanf(fd,"%h %h %h\n",ta,tbb,te);
                    if(code==3) begin
                        if(is_mul) begin mul_a=ta; mul_b=tbb; mul_in=1; end
                        else       begin add_a=ta; add_b=tbb; add_in=1; end
                        expq[wr]=te; wr=wr+1;
                    end
                end else begin
                    add_in=0; mul_in=0;
                end
                @(posedge clk);
                if(is_mul ? mul_out : add_out) begin
                    total=total+1;
                    if(is_nan(expq[rdp])) begin
                        if(is_nan(is_mul ? mul_p : add_s)) exact=exact+1;
                        else begin bad=bad+1; if(bad<=5) $display("  BAD: got=%08h exp=%08h (NaN mismatch)", is_mul?mul_p:add_s, expq[rdp]); end
                    end else begin
                        if((is_mul?mul_p:add_s) === expq[rdp]) exact=exact+1;
                        else begin bad=bad+1; if(bad<=5) $display("  BAD: got=%08h exp=%08h", is_mul?mul_p:add_s, expq[rdp]); end
                    end
                    rdp=rdp+1;
                end
            end
            $fclose(fd);
            $display("  %s: total=%0d exact=%0d bad=%0d (%0d%%)", label, total, exact, bad, (exact*100)/total);
            if(bad==0) begin n_pass=n_pass+1; $display("  PASS: %s FTZ random golden", label); end
            else begin n_fail=n_fail+1; $display("  FAIL: %s", label); end
        end
    endtask

    initial begin
        $dumpfile("/tmp/tb_fp_ftz.vcd");
        $dumpvars(0, tb_fp_ftz);

        rst_n=0; add_a=0; add_b=0; add_in=0; mul_a=0; mul_b=0; mul_in=0;
        repeat(8)@(posedge clk);
        @(negedge clk); rst_n=1; @(posedge clk);

        // ==================== 定向用例 §7.2 ====================
        $display("========== Directional FTZ test cases ==========");

        // ① denormal 输入 FTZ
        $display("-- FTZ input --");
        send_add(32'h00000001, 32'h3F800000, rd);  // dmin + 1.0
        check(rd, 32'h3F800000, "case1: dmin+1.0 = 1.0 (FTZ input)");
        send_add(32'h007FFFFF, 32'h00000001, rd);  // dmax - dmin
        check(rd, 32'h00000000, "case2: dmax-dmin = +0 (both FTZ->0)");

        // ③ 相消到 denormal → FTZ +0
        $display("-- underflow → FTZ --");
        send_add(32'h00800001, 32'h80800000, rd);  // normal + normal → subnormal
        check(rd, 32'h00000000, "case3: normal→denorm = +0 (FTZ out)");

        // ④ normal+denormal → normal
        send_add(32'h3F000000, 32'h00000001, rd);  // 0.5 + dmin
        check(rd, 32'h3F000000, "case4: 0.5+dmin = 0.5 (FTZ input, denorm→0)");

        // ⑤ Inf + finite 符号
        $display("-- Inf sign fix --");
        send_add(32'h7F800000, 32'h3F800000, rd);  // +Inf + 1
        check(rd, 32'h7F800000, "case5a: +Inf+1 = +Inf");
        send_add(32'hFF800000, 32'h3F800000, rd);  // -Inf + 1
        check(rd, 32'hFF800000, "case5b: -Inf+1 = -Inf");
        send_add(32'h7F800000, 32'hBF800000, rd);  // +Inf + (-1) → +Inf (Inf方符号)
        check(rd, 32'h7F800000, "case5c: (+Inf)+(-1) = +Inf (NOT -Inf)");
        send_add(32'hFF800000, 32'hBF800000, rd);  // -Inf + (-1) → -Inf
        check(rd, 32'hFF800000, "case5d: (-Inf)+(-1) = -Inf");

        // ⑥ Inf±Inf
        send_add(32'h7F800000, 32'hFF800000, rd);  // +Inf + -Inf
        check(rd, 32'h7FC00000, "case6a: +Inf+(-Inf) = qNaN");
        send_add(32'hFF800000, 32'hFF800000, rd);  // -Inf + -Inf
        check(rd, 32'hFF800000, "case6b: (-Inf)+(-Inf) = -Inf");

        // ⑦ Inf×0 → NaN
        $display("-- Inf*0/Inf*denorm → NaN --");
        send_mul(32'h7F800000, 32'h00000000, rd);
        check(rd, 32'h7FC00000, "case7a: Inf*0 = qNaN");
        send_mul(32'h7F800000, 32'h00000001, rd);  // Inf × dmin (FTZ→0)
        check(rd, 32'h7FC00000, "case7b: Inf*dmin = qNaN (FTZ→Inf*0)");

        // ⑧ Inf×normal
        send_mul(32'h7F800000, 32'h40000000, rd);  // Inf × 2
        check(rd, 32'h7F800000, "case8: Inf*2 = +Inf");

        // ⑨ 上溢 → +Inf
        $display("-- overflow/underflow --");
        send_add(32'h7F7FFFFF, 32'h7F7FFFFF, rd);  // max+max
        check(rd, 32'h7F800000, "case9a: max+max = +Inf (was NaN)");
        // ⑨b exp_n=255 + mant_ovf → 256 回绕支
        send_add(32'h7F7FFFFF, 32'h7F7FFFFE, rd);
        check(rd, 32'h7F800000, "case9b: near-max pair → +Inf");

        // ⑩ mul 上溢
        send_mul(32'h7F7FFFFF, 32'h40000000, rd);  // max × 2
        check(rd, 32'h7F800000, "case10a: max*2 = +Inf (10-bit exp sum)");
        // ⑩b mul 下溢
        send_mul(32'h08000000, 32'h08000000, rd);  // 2^-100 × 2^-100 = 2^-200
        check(rd, 32'h00000000, "case10b: tiny*tiny = +0 (underflow FTZ)");

        // ⑩c/⑩d denormal × normal/denormal (FTZ 输入)
        send_mul(32'h00000001, 32'h40000000, rd);  // dmin × 2 → 0*2 = 0
        check(rd, 32'h00000000, "case10c: dmin*2 = +0 (FTZ input zero)");
        send_mul(32'h00000001, 32'h00000001, rd);  // dmin × dmin → 0*0 = 0
        check(rd, 32'h00000000, "case10d: dmin*dmin = +0");

        // ⑪ 借位扫描 —— 2026-08-04 复核重写（原版对旧 RTL 也 PASS，零鉴别力）
        //
        //   原版用 {0,e,0x000000} 与 {0,e,0x7FFFFF} 相减：两者差近 1 个 binade，
        //   相消后只有 1 个前导零（lz=1）⇒ exp_n = e-1，**永远借不了位**。
        //   实测：把原版扔给改动前的 RTL 跑，giant count = 0（全过）。
        //
        //   要触发 `exp_big - lz` 的 8 位无符号借位，必须**近乎全相消**：
        //   取只差 1 ULP 的一对 ⇒ 差值 = 2^-23 × 2^(e-127) ⇒ lz≈23 ⇒ e<23 时 exp_n 为负。
        //   实测新向量：旧 RTL giant=22（e=1..22 全产出 exp>200 的巨值），新 RTL giant=0。
        //
        //   判据同时修两处：① 去掉原来的 `rd[23] &&` 门控（bit23 是阶码域最低位，
        //   当门控毫无意义且会漏掉一半）；② PASS 改为只在 bad==0 时才计。
        $display("-- borrow scan --");
        begin
            integer e;
            integer n_giant;
            reg [31:0] va, vb;
            n_giant = 0;
            for (e = 1; e <= 30; e = e + 1) begin
                va = {1'b0, e[7:0], 23'h000001};            // 相邻规格数：只差 1 ULP
                vb = {1'b0, e[7:0], 23'h000000};
                send_add(va, {1'b1, vb[30:0]}, rd);         // 异号相加 = 相减
                // 结果应为 ±0 或常规小数，绝不出现 exp>200 的巨值
                if (rd[30:23] > 8'd200) begin
                    n_giant = n_giant + 1;
                    $display("  GIANT: case11 borrow@e=%0d got=%08h (exp=%0d)", e, rd, rd[30:23]);
                end
            end
            if (n_giant == 0) begin
                n_pass = n_pass + 1;
                $display("  PASS: case11 borrow scan e=1..30 (no giant exp)");
            end else begin
                n_fail = n_fail + 1;
                $display("  FAIL: case11 borrow scan —— %0d/30 产出巨值", n_giant);
            end
        end

        // ⑫ 常规值抽查（应与改前逐位相同）
        send_add(32'h3FC00000, 32'h40000000, rd); check(rd, 32'h40600000, "case12a: 1.5+2=3.5");
        send_add(32'h40A00000, 32'h40000000, rd); check(rd, 32'h40E00000, "case12b: 5+2=7");
        send_mul(32'hC2B40000, 32'h3F59999A, rd); check(rd, 32'hC2990000, "case12c: -90*0.85");

        // ==================== FTZ 全域随机金标准 ====================
        $display("========== FTZ full-range random golden ==========");
        run_ftz_random("vectors_add_ftz.txt", "add FTZ 20万", 0);
        run_ftz_random("vectors_mul_ftz.txt", "mul FTZ 20万", 1);

        $display("==================================================");
        $display("tb_fp_ftz: %0d PASS, %0d FAIL", n_pass, n_fail);
        if (n_fail == 0) $display("ALL PASS (FTZ semantics)");
        else $display("HAS FAILURES");
        $finish;
    end

endmodule
