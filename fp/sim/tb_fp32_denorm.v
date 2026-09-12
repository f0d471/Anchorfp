`timescale 1ns/1ps
//==============================================================================================//
// TB: tb_fp32_denorm
//
// DESCRIPTION: fp32_mul_pipe 与 fp32_add 在 denormal 域的 FTZ 契约门禁。
//
// NOTE:
//   1. 金标准是 FTZ 契约而非完整 IEEE：denormal 输入与输出一律 ±0 保符号，Inf x denormal 出 qNaN
//   2. 判据是 bad == 0，任何不符即缺陷
//   3. 向量由 gen_denorm_vectors.c 生成，与本 TB 同一套契约
//==============================================================================================//
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
    integer mul_bad, mul_total;       // 供末尾 verdict 用
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

        // 判据是硬门禁：bad 不为零即 FAIL。
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
