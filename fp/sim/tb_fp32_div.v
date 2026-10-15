`timescale 1ns/1ps
`include "fp32_lat.vh"
//==============================================================================================//
// TB: tb_fp32_div
//
// DESCRIPTION: fp32_div 的三类判据——数值、时序、协议。数值档与特殊值档都是逐位比较，
//   normal 共同域按 0 ULP 契约，signed zero 与 NaN/Inf 只能位级比，没有容差档。
//
// NOTE:
//   1. 向量每行为 a_bits b_bits result_bits，十六进制，由 gen_div_vectors.c 生成；
//      按 II=1 连续喂入，出口逐条对账，依赖固定延迟与顺序返回，错位由出队条数判据兜住
//   2. 判据另有结构项：出队条数须等于喂入条数，否则是 valid 链错位而不是数值问题
//   3. 时序档实测 in_valid 到 out_valid 的拍数与 `FP32_DIV_LAT 对账，并用 flush/reset 各注一次
//   4. 本模块不读 mem，工作目录取 sim/ 即可；name 一律 ASCII，iverilog 的 %0s 会打坏非 ASCII 字节
//==============================================================================================//
module tb_fp32_div;
    localparam MAXN = 1100000;

    reg clk = 0, rst_n = 0, in_valid = 0, flush = 0;
    reg [31:0] a = 0, b = 0;
    wire        out_valid;
    wire [31:0] result;

    fp32_div dut (.clk(clk), .rst_n(rst_n), .a(a), .b(b),
                  .in_valid(in_valid), .flush(flush),
                  .out_valid(out_valid), .result(result));
    always #5 clk = ~clk;

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    integer n_pass = 0, n_fail = 0;

    task check_exact;
        input [31:0] exp;
        input [255:0] name;
        begin
            if (result === exp) begin n_pass = n_pass + 1; $display("  PASS: %0s", name); end
            else begin n_fail = n_fail + 1;
                $display("  FAIL: %0s got=%08h exp=%08h", name, result, exp); end
        end
    endtask

    task check_lat;
        input [255:0] name;
        input integer got;
        input integer want;
        begin
            if (got === want) begin n_pass = n_pass + 1;
                $display("  PASS: %0s 实测 %0d 拍", name, got); end
            else if (got < 0) begin n_fail = n_fail + 1;
                $display("  FAIL: %0s 超时无 out_valid（FP32_DIV_LAT 说 %0d 拍）", name, want); end
            else begin n_fail = n_fail + 1;
                $display("  FAIL: %0s 实测 %0d 拍，FP32_DIV_LAT 说 %0d 拍", name, got, want); end
        end
    endtask

    // 单笔观察：negedge 采样，cyc 与 out_valid 此时都已稳定，避开 posedge 的调度竞态
    integer t0 = 0, lat = -1, seen = 0;
    always @(negedge clk) begin
        if (out_valid && !seen) begin lat = cyc - t0; seen = 1; end
    end

    integer tmo;
    task do_div;
        input [31:0] va;
        input [31:0] vb;
        begin
            lat = -1; seen = 0; tmo = 0; flush = 1'b0;
            @(negedge clk);
            t0 = cyc; a = va; b = vb; in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            while (!seen && tmo < 64) begin @(negedge clk); tmo = tmo + 1; end
            @(negedge clk);
        end
    endtask

    // flush 作废在飞运算：发射后第 at 拍拉 flush，此后 24 拍内不得有 out_valid
    task do_flush_test;
        input [31:0] va;
        input [31:0] vb;
        input integer at;
        integer k, hit;
        begin
            hit = 0;
            @(negedge clk);
            a = va; b = vb; in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            for (k = 1; k < at; k = k + 1) @(negedge clk);
            @(negedge clk); flush = 1'b1;
            @(negedge clk); flush = 1'b0;
            repeat (24) begin @(negedge clk); if (out_valid) hit = hit + 1; end
            if (hit == 0) begin n_pass = n_pass + 1;
                $display("  PASS: flush 于第 %0d 拍作废在飞运算，后续无 out_valid", at); end
            else begin n_fail = n_fail + 1;
                $display("  FAIL: flush 于第 %0d 拍后仍出现 %0d 次 out_valid", at, hit); end
        end
    endtask

    // flush 与 in_valid 同拍：该请求不得被接受
    task do_flush_same;
        input [31:0] va;
        input [31:0] vb;
        integer hit;
        begin
            hit = 0;
            @(negedge clk);
            a = va; b = vb; in_valid = 1'b1; flush = 1'b1;
            @(negedge clk);
            in_valid = 1'b0; flush = 1'b0;
            repeat (24) begin @(negedge clk); if (out_valid) hit = hit + 1; end
            if (hit == 0) begin n_pass = n_pass + 1;
                $display("  PASS: flush 与 in_valid 同拍，请求未被接受"); end
            else begin n_fail = n_fail + 1;
                $display("  FAIL: flush 同拍请求仍被接受（%0d 次 out_valid）", hit); end
        end
    endtask

    // 中途复位：在飞运算全部作废
    task do_reset_test;
        input [31:0] va;
        input [31:0] vb;
        integer hit;
        begin
            hit = 0;
            @(negedge clk);
            a = va; b = vb; in_valid = 1'b1;
            @(negedge clk);
            in_valid = 1'b0;
            repeat (3) @(negedge clk);
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            check_reset_internal;
            rst_n = 1'b1;
            repeat (24) begin @(negedge clk); if (out_valid) hit = hit + 1; end
            if (hit == 0) begin n_pass = n_pass + 1;
                $display("  PASS: 中途 reset 作废在飞运算"); end
            else begin n_fail = n_fail + 1;
                $display("  FAIL: reset 后仍出现 %0d 次 out_valid", hit); end
        end
    endtask

    // 白盒：reset 期间内部流水寄存器必须全为 0
    // 黑盒看不到这一项 —— 数据寄存器被 val 门控，复位优先级写错时黑盒行为与正确写法逐位相同，
    // 只有直接看内部状态才能发现"复位赋值被 en 分支覆盖"这类缺陷
    integer sk, nbad;
    task check_reset_internal;
        begin
            nbad = 0;
            for (sk = 0; sk <= 12; sk = sk + 1) begin
                if (dut.B_s[sk]            !== 0) nbad = nbad + 1;
                if (dut.R_s[sk]            !== 0) nbad = nbad + 1;
                if (dut.Q_s[sk]            !== 0) nbad = nbad + 1;
                if (dut.sign[sk]           !== 0) nbad = nbad + 1;
                if (dut.E_pipe[sk]         !== 0) nbad = nbad + 1;
                if (dut.kind_s[sk]         !== 0) nbad = nbad + 1;
            end
            if (nbad == 0) begin n_pass = n_pass + 1;
                $display("  PASS: [29] reset 后内部流水寄存器全为 0"); end
            else begin n_fail = n_fail + 1;
                $display("  FAIL: [29] reset 后仍有 %0d 个内部流水寄存器非 0", nbad); end
        end
    endtask

    // 流式向量：II=1 连续喂入，出口监视器逐条对账
    reg [31:0] va_q [0:MAXN-1];
    reg [31:0] vb_q [0:MAXN-1];
    reg [31:0] ve_q [0:MAXN-1];
    integer fd, code, i, count, total, bad, rdp;
    reg [31:0] ta, tb_, te;
    reg mon_en = 0;

    always @(posedge clk) begin
        if (mon_en && out_valid) begin
            total = total + 1;
            if (result !== ve_q[rdp]) begin
                bad = bad + 1;
                if (bad <= 5)
                    $display("  BAD[%0d]: a=%08h b=%08h got=%08h exp=%08h",
                             rdp, va_q[rdp], vb_q[rdp], result, ve_q[rdp]);
            end
            rdp = rdp + 1;
        end
    end

    task run_vectors;
        begin
            fd = $fopen("vectors_div.txt", "r");
            if (fd == 0) begin
                $display("  SKIP: vectors_div.txt 不存在（先跑 gen_vectors.sh 或 gen_div_vectors）");
                n_fail = n_fail + 1;
            end else begin
                count = 0;
                while (!$feof(fd) && count < MAXN) begin
                    code = $fscanf(fd, "%h %h %h\n", ta, tb_, te);
                    if (code == 3) begin
                        va_q[count] = ta; vb_q[count] = tb_; ve_q[count] = te;
                        count = count + 1;
                    end
                end
                $fclose(fd);
                $display("  loaded %0d vectors", count);

                total = 0; bad = 0; rdp = 0;
                a = 0; b = 0; in_valid = 0; flush = 0;
                rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; @(posedge clk);

                mon_en = 1;
                for (i = 0; i < count; i = i + 1) begin
                    @(negedge clk); a = va_q[i]; b = vb_q[i]; in_valid = 1'b1;
                end
                @(negedge clk); in_valid = 1'b0;
                repeat (`FP32_DIV_LAT + 4) @(posedge clk);
                mon_en = 0;

                $display("  vectors: loaded=%0d compared=%0d mismatch=%0d", count, total, bad);
                if (total != count) begin
                    n_fail = n_fail + 1;
                    $display("  FAIL: 出队 %0d != 喂入 %0d（valid 链错位）", total, count);
                end else if (bad == 0) begin
                    n_pass = n_pass + 1;
                    $display("  PASS: %0d 条逐位相同", total);
                end else begin
                    n_fail = n_fail + 1;
                    $display("  FAIL: %0d/%0d 不符", bad, total);
                end
            end
        end
    endtask

    initial begin
        rst_n = 0; in_valid = 0; flush = 0; a = 0; b = 0;
        repeat(4) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat(2) @(negedge clk);

        $display("==== tb_fp32_div ====");

        // ===== 时序：固定延迟 =====
        $display("-- latency --");
        do_div(32'h3F800000, 32'h40000000);
        check_lat("[1]  1.0/2.0 lat", lat, `FP32_DIV_LAT);

        // ===== 特殊值：逐位 =====
        $display("-- special (bit-exact) --");
        do_div(32'h7FC00000, 32'h3F800000); check_exact(32'h7FC00000, "[2] qNaN/1 -> qNaN");
        do_div(32'h3F800000, 32'h7F800001); check_exact(32'h7FC00000, "[3] 1/sNaN -> qNaN");
        do_div(32'h00000000, 32'h80000000); check_exact(32'h7FC00000, "[4] +0/-0 -> qNaN");
        do_div(32'h7F800000, 32'h7F800000); check_exact(32'h7FC00000, "[5] +Inf/+Inf -> qNaN");
        do_div(32'h7F800000, 32'hFF800000); check_exact(32'h7FC00000, "[6] +Inf/-Inf -> qNaN");
        do_div(32'h40400000, 32'h00000000); check_exact(32'h7F800000, "[7] 3/+0 -> +Inf");
        do_div(32'h40400000, 32'h80000000); check_exact(32'hFF800000, "[8] 3/-0 -> -Inf");
        do_div(32'hC0400000, 32'h00000000); check_exact(32'hFF800000, "[9] -3/+0 -> -Inf");
        do_div(32'hC0400000, 32'h80000000); check_exact(32'h7F800000, "[10] -3/-0 -> +Inf");
        do_div(32'h7F800000, 32'h40400000); check_exact(32'h7F800000, "[11] +Inf/3 -> +Inf");
        do_div(32'hFF800000, 32'h40400000); check_exact(32'hFF800000, "[12] -Inf/3 -> -Inf");
        do_div(32'h00000000, 32'h40400000); check_exact(32'h00000000, "[13] +0/3 -> +0");
        do_div(32'h80000000, 32'h40400000); check_exact(32'h80000000, "[14] -0/3 -> -0");
        do_div(32'h00000000, 32'hBF800000); check_exact(32'h80000000, "[15] +0/-1 -> -0");
        do_div(32'h40400000, 32'h7F800000); check_exact(32'h00000000, "[16] 3/+Inf -> +0");
        do_div(32'hC0400000, 32'h7F800000); check_exact(32'h80000000, "[17] -3/+Inf -> -0");
        do_div(32'h00000000, 32'h7F800000); check_exact(32'h00000000, "[18] +0/+Inf -> +0");
        do_div(32'h80000000, 32'h7F800000); check_exact(32'h80000000, "[19] -0/+Inf -> -0");

        // ===== DAZ / FTZ =====
        $display("-- DAZ / FTZ (bit-exact) --");
        do_div(32'h00000001, 32'h3F800000); check_exact(32'h00000000, "[20] dmin/1.0 -> +0 (DAZ)");
        do_div(32'h807FFFFF, 32'h3F800000); check_exact(32'h80000000, "[21] -dmax/1.0 -> -0 (DAZ)");
        do_div(32'h00800000, 32'h41800000); check_exact(32'h00000000, "[22] 2^-126/16 -> +0 (FTZ)");

        // ===== 边界：舍入、位宽、上下溢分界 =====
        $display("-- boundary (bit-exact) --");
        do_div(32'h7F7FFFFF, 32'h3F800000); check_exact(32'h7F7FFFFF, "[23] maxFinite/1.0 -> maxFinite");
        do_div(32'h7F7FFFFF, 32'h00800000); check_exact(32'h7F800000, "[24] maxFinite/minNormal -> +Inf");
        do_div(32'h00800000, 32'h40000000); check_exact(32'h00000000, "[25] minNormal/2.0 -> +0");
        do_div(32'h64000000, 32'h647FFFFF); check_exact(32'h3F000001, "[26] 2R needs bit25");
        do_div(32'h3F800000, 32'h40400000); check_exact(32'h3EAAAAAB, "[27] 1/3 exact rem");
        do_div(32'h40490FDB, 32'h40000000); check_exact(32'h3FC90FDB, "[28] pi/2");

        // ===== 时序：flush 与 reset =====
        $display("-- flush / reset --");
        do_flush_test(32'h3F800000, 32'h40000000, 3);
        do_flush_test(32'h3F800000, 32'h40000000, 7);
        do_flush_same(32'h3F800000, 32'h40000000);
        do_reset_test(32'h3F800000, 32'h40000000);

        // ===== 流式向量：数值 + 协议 =====
        $display("-- streaming vectors --");
        run_vectors;

        $display("==========================================");
        $display("tb_fp32_div: %0d PASS, %0d FAIL", n_pass, n_fail);
        if (n_fail == 0) $display("ALL PASS");
        else             $display("HAS FAILURES");
        $finish;
    end

endmodule
