`timescale 1ns/1ps
//==============================================================================================//
// TB: tb_fp32_add
//
// DESCRIPTION: fp32_add 与 IEEE FP32 金标准（生成器所在机器上 C 语言的 float）逐位对拍，统计 ULP 分布。
//
// NOTE:
//   1. 向量每行为 a_bits b_bits golden_bits，十六进制
//   2. 期望值走入队/出队队列，对任意流水延迟成立，不写死拍数
//   3. 另有结构判据：出队条数须等于喂入条数
//==============================================================================================//
module tb_fp32_add;
    localparam MAXN = 300000;

    reg clk = 0, rst_n = 0;
    reg  [31:0] a, b;
    reg         in_valid;
    wire [31:0] s;
    wire        out_valid;

    fp32_add dut (.clk(clk), .rst_n(rst_n), .a(a), .b(b), .s(s),
                  .in_valid(in_valid), .flush(1'b0), .out_valid(out_valid));
    always #5 clk = ~clk;

    reg [31:0] av [0:MAXN-1];
    reg [31:0] bv [0:MAXN-1];
    reg [31:0] ev [0:MAXN-1];
    integer count;

    // 期望值队列：入队指针 wrp（喂输入时 +1）、出队指针 rdp（out_valid 时 +1）
    integer wrp = 0, rdp = 0;

    integer total, exact, ulp1, ulpgt1, low_cnt, maxulp;
    integer i, fd, code;
    reg [31:0] ta, tb_, te;

    function integer ulp_dist(input [31:0] x, input [31:0] y);
        ulp_dist = (x >= y) ? (x - y) : (y - x);
    endfunction

    // 出口监视器：out_valid 抬起就出队一条比对，不假设流水深度
    integer d_mon;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            d_mon = ulp_dist(s, ev[rdp]);
            total = total + 1;
            if (d_mon == 0)      exact  = exact  + 1;
            else if (d_mon == 1) ulp1   = ulp1   + 1;
            else                 ulpgt1 = ulpgt1 + 1;
            if (s < ev[rdp])     low_cnt = low_cnt + 1;
            if (d_mon > maxulp)  maxulp = d_mon;
            if (d_mon != 0 && ulpgt1 <= 5)
                $display("  BAD[%0d]: a=%08h b=%08h got=%08h exp=%08h ulp=%0d",
                         rdp, av[rdp], bv[rdp], s, ev[rdp], d_mon);
            rdp = rdp + 1;
        end
    end

    initial begin
        count = 0;
        fd = $fopen("vectors_add.txt", "r");
        if (fd == 0) begin $display("ERROR: cannot open vectors_add.txt"); $finish; end
        while (!$feof(fd) && count < MAXN) begin
            code = $fscanf(fd, "%h %h %h\n", ta, tb_, te);
            if (code == 3) begin
                av[count]=ta; bv[count]=tb_; ev[count]=te; count=count+1;
            end
        end
        $fclose(fd);
        $display("loaded %0d vectors", count);

        total=0; exact=0; ulp1=0; ulpgt1=0; low_cnt=0; maxulp=0;
        a=0; b=0; in_valid=0;
        rst_n=0; repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        for (i = 0; i < count; i = i + 1) begin
            @(negedge clk);
            a = av[i]; b = bv[i]; in_valid = 1'b1; wrp = i + 1;
        end
        @(negedge clk); in_valid = 1'b0;
        repeat(8) @(posedge clk);   // 排空流水

        $display("==== fp32_add vs IEEE golden ====");
        $display("loaded/fed = %0d", count);
        $display("total      = %0d", total);
        $display("exact(0ULP)= %0d  (%0d%%)", exact, total ? (exact*100)/total : 0);
        $display("off 1 ULP  = %0d", ulp1);
        $display("off >1 ULP = %0d", ulpgt1);
        $display("DUT<golden = %0d", low_cnt);
        $display("max ULP    = %0d", maxulp);
        // 出队条数必须等于喂入条数，否则是流水/valid 错位而不是数值问题
        if (total != count)
            $display("FAIL: 出队 %0d 条 != 喂入 %0d 条（valid 链错位）", total, count);
        else if (exact == total)
            $display("ALL PASS (%0d/%0d 逐位相同)", exact, total);
        else
            $display("HAS FAILURES (%0d/%0d 不符, max ULP %0d)", total-exact, total, maxulp);
        $finish;
    end
endmodule
