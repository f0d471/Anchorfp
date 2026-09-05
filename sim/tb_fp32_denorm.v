`timescale 1ns / 1ps
// tb_fp32_denorm —— fpmul/fpadd 的 denormal 域**契约门禁**
//
// 2026-08-04 [#37] V1-C 改判：本 TB 从"bug 复现器"升级为"契约门禁"。
//
//   旧身份：金标准是完整 IEEE，用来复现两个已知 bug（fp32_mul_norm 只检测 5 位
//   前导零、fp32_add 的 denormal 近似）。那批 `MUL 161/161` + `ADD 80/100` 全错
//   在 [#15] 被归档成"**基线不是 bug，不要修**"——当时 denormal 没有消费者，
//   改它只会给 GEMM 的零余量时序找 churn（改过多次，每次上板乱码）。
//
//   新身份：V1-C 之后硬件真身承诺 FTZ 全语义（[#37] V1-C §3），
//   `gen_denorm_vectors.c` 的期望值已整体反转成 FTZ 契约
//   （denormal 输入/输出 → ±0 保符号；Inf×denormal → qNaN）。
//   ⇒ **判据从"记录错了多少"变成 bad==0 才 PASS**，见文件末尾的 verdict。
//   ⇒ 跑之前必须重新生成向量：
//        gcc -O2 -ffp-contract=off -o gen_denorm gen_denorm_vectors.c && ./gen_denorm > vectors_denorm.txt
//      **旧的 vectors_denorm.txt 不作数**（它是完整 IEEE 期望）。

module tb_fp32_denorm;
    reg clk = 0; always #5 clk = ~clk;
    reg rst_n, in_valid, in_valid_a;
    reg [31:0] mul_a, mul_b, add_a, add_b;
    wire [31:0] p, s;
    wire out_valid, out_valid_a;

    fp32_mul_pipe u_mul (.clk(clk),.rst_n(rst_n),.a(mul_a),.b(mul_b),.p(p),.in_valid(in_valid), .flush(1'b0),.out_valid(out_valid));
    fp32_add      u_add (.clk(clk),.rst_n(rst_n),.a(add_a),.b(add_b),.s(s),.in_valid(in_valid_a), .flush(1'b0),.out_valid(out_valid_a));

    integer fd, code;
    integer total, bad, off1, offgt1;
    integer mul_bad, mul_total;       // [#37] V1-C: 供末尾 verdict 用
    integer maxulp;
    reg [31:0] g_a, g_b, g_exp, got;
    reg [7:0] tag;  // 'M' or 'A'
    integer d;

    // NaN 只判分类（期望里 Inf×denormal 钉的是 0x7FC00000，硬件也可能给别的 payload）
    function integer is_nan(input [31:0] x);
        is_nan = ((x & 32'h7F800000) == 32'h7F800000) && ((x & 32'h007FFFFF) != 0);
    endfunction

    function integer ulp_diff(input [31:0] x, input [31:0] y);
    begin
        if (is_nan(y))                         ulp_diff = is_nan(x) ? 0 : 32'h40000000;
        else if (is_nan(x))                    ulp_diff = 32'h40000000;
        else if (x == y)                       ulp_diff = 0;
        else if (x[31] != y[31])               ulp_diff = 32'h40000000;  // sign mismatch(含 ±0)
        else if (x >= y)                       ulp_diff = x - y;
        else                                   ulp_diff = y - x;
    end
    endfunction

    task test_mul(input [31:0] ga, gb, gexp);
        integer dd;
    begin
        mul_a = ga; mul_b = gb; in_valid = 1;
        @(posedge clk); in_valid = 0;
        repeat(4) @(posedge clk);
        got = p;
        total = total + 1;
        dd = ulp_diff(got, gexp);
        if (dd != 0) begin
            bad = bad + 1;
            if (dd == 1) off1 = off1 + 1;
            else begin offgt1 = offgt1 + 1; if (dd > maxulp) maxulp = dd; end
            if (bad <= 12) $display("MUL MISMATCH #%0d: a=%h b=%h | got=%h exp=%h ulp=%0d", bad, ga, gb, got, gexp, dd);
        end
    end
    endtask

    task test_add(input [31:0] ga, gb, gexp);
        integer dd;
    begin
        add_a = ga; add_b = gb; in_valid_a = 1;
        @(posedge clk); in_valid_a = 0;
        repeat(3) @(posedge clk);
        got = s;
        total = total + 1;
        dd = ulp_diff(got, gexp);
        if (dd != 0) begin
            bad = bad + 1;
            if (dd == 1) off1 = off1 + 1;
            else begin offgt1 = offgt1 + 1; if (dd > maxulp) maxulp = dd; end
            if (bad <= 12) $display("ADD MISMATCH #%0d: a=%h b=%h | got=%h exp=%h ulp=%0d", bad, ga, gb, got, gexp, dd);
        end
    end
    endtask

    initial begin
        fd = $fopen("vectors_denorm.txt", "r");
        if (fd == 0) begin $display("ERR: cannot open vectors_denorm.txt"); $finish; end
        rst_n = 0; in_valid = 0; in_valid_a = 0;
        repeat(4) @(posedge clk); rst_n = 1; @(posedge clk);

        // ===== MUL test =====
        total = 0; bad = 0; off1 = 0; offgt1 = 0; maxulp = 0;
        $display("===== fp32_mul_pipe DENORM test =====");
        code = $fscanf(fd, "%c %h %h %h\n", tag, g_a, g_b, g_exp);
        while (code == 4) begin
            if (tag == "M") test_mul(g_a, g_b, g_exp);
            code = $fscanf(fd, "%c %h %h %h\n", tag, g_a, g_b, g_exp);
        end
        $display("MUL: total=%0d bad=%0d off1=%0d off>1=%0d maxulp=%0d", total, bad, off1, offgt1, maxulp);
        mul_bad = bad; mul_total = total;
        $fclose(fd);

        // ===== ADD test (re-read file) =====
        fd = $fopen("vectors_denorm.txt", "r");
        total = 0; bad = 0; off1 = 0; offgt1 = 0; maxulp = 0;
        $display("===== fp32_add DENORM test =====");
        code = $fscanf(fd, "%c %h %h %h\n", tag, g_a, g_b, g_exp);
        while (code == 4) begin
            if (tag == "A") test_add(g_a, g_b, g_exp);
            code = $fscanf(fd, "%c %h %h %h\n", tag, g_a, g_b, g_exp);
        end
        $display("ADD: total=%0d bad=%0d off1=%0d off>1=%0d maxulp=%0d", total, bad, off1, offgt1, maxulp);
        $fclose(fd);

        // [#37] V1-C：判据从"记录错了多少"改成硬门禁。
        $display("==================================================");
        if ((mul_bad == 0) && (bad == 0))
            $display("tb_fp32_denorm: ALL PASS (FTZ contract) —— MUL %0d/%0d, ADD %0d/%0d",
                     mul_total, mul_total, total, total);
        else
            $display("tb_fp32_denorm: FAIL —— MUL bad=%0d/%0d, ADD bad=%0d/%0d",
                     mul_bad, mul_total, bad, total);

        $finish;
    end
endmodule
