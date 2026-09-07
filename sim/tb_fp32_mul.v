`timescale 1ns/1ps
//============================================================================
// tb_fp32_mul —— 比对 fp32_mul_pipe 与 IEEE FP32 金标准（C float）的 ULP 误差
//   向量文件每行: a_bits b_bits golden_prod_bits（十六进制）
//   DUT 延迟 2 拍；用同步期望流水对齐。
//   统计: 总数 / 精确匹配 / 偏 1ULP / 偏 >1ULP / 最大 ULP / 偏低计数（截断特征）
//============================================================================
module tb_fp32_mul;
    localparam MAXN = 300000;

    reg clk = 0, rst_n = 0;
    reg  [31:0] a, b;
    wire [31:0] p;

    fp32_mul_pipe dut (.clk(clk), .rst_n(rst_n), .a(a), .b(b), .p(p), .flush(1'b0));
    always #5 clk = ~clk;

    reg [31:0] av [0:MAXN-1];
    reg [31:0] bv [0:MAXN-1];
    reg [31:0] ev [0:MAXN-1];
    integer count;

    // 期望值同步流水（与 DUT 2 拍延迟对齐）
    reg [31:0] exp_d1, exp_d2;
    reg        vld_d1, vld_d2;
    reg [31:0] cur_exp;
    reg        cur_vld;
    always @(posedge clk) begin
        exp_d1 <= cur_exp; vld_d1 <= cur_vld;
        exp_d2 <= exp_d1;  vld_d2 <= vld_d1;
    end

    integer total, exact, ulp1, ulpgt1, low_cnt, maxulp;
    integer i, fd, code;
    reg [31:0] ta, tb_, te;

    // ULP 距离（同号规格化数，位模式单调）
    function integer ulp_dist(input [31:0] x, input [31:0] y);
        ulp_dist = (x >= y) ? (x - y) : (y - x);
    endfunction

    task check;
        integer d;
        begin
            if (vld_d2) begin
                d = ulp_dist(p, exp_d2);
                total = total + 1;
                if (d == 0)      exact  = exact  + 1;
                else if (d == 1) ulp1   = ulp1   + 1;
                else             ulpgt1 = ulpgt1 + 1;
                if (p < exp_d2)  low_cnt = low_cnt + 1;   // DUT 偏低（截断特征）
                if (d > maxulp)  maxulp = d;
            end
        end
    endtask

    initial begin
        // 读向量
        count = 0;
        fd = $fopen("vectors_mul.txt", "r");
        if (fd == 0) begin $display("ERROR: cannot open vectors_mul.txt"); $finish; end
        while (!$feof(fd) && count < MAXN) begin
            code = $fscanf(fd, "%h %h %h\n", ta, tb_, te);
            if (code == 3) begin
                av[count] = ta; bv[count] = tb_; ev[count] = te;
                count = count + 1;
            end
        end
        $fclose(fd);
        $display("loaded %0d vectors", count);

        total=0; exact=0; ulp1=0; ulpgt1=0; low_cnt=0; maxulp=0;
        a=0; b=0; cur_exp=0; cur_vld=0;
        rst_n=0; repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        // 逐拍喂入，同步比对
        for (i = 0; i < count; i = i + 1) begin
            a <= av[i]; b <= bv[i]; cur_exp <= ev[i]; cur_vld <= 1'b1;
            @(posedge clk);
            check;
        end
        // 排空流水
        cur_vld <= 1'b0;
        @(posedge clk); check;
        @(posedge clk); check;

        $display("==== fp32_mul vs IEEE golden ====");
        $display("total      = %0d", total);
        $display("exact(0ULP)= %0d  (%0d%%)", exact, (exact*100)/total);
        $display("off 1 ULP  = %0d", ulp1);
        $display("off >1 ULP = %0d", ulpgt1);
        $display("DUT<golden = %0d  (偏低占比 %0d%%)", low_cnt, (low_cnt*100)/total);
        $display("max ULP    = %0d", maxulp);
        if (total != count)
            $display("HAS FAILURES: 出队 %0d 条 != 喂入 %0d 条（valid 链错位）", total, count);
        else if (exact == total)
            $display("ALL PASS (%0d/%0d 逐位相同)", exact, total);
        else
            $display("HAS FAILURES (%0d/%0d 不符, max ULP %0d)", total-exact, total, maxulp);
        $finish;
    end
endmodule
