`timescale 1ns / 1ps
//==============================================================================================//
// TESTBENCH: tb_rsqrt_stream
//
// DESCRIPTION: rsqrt_func 的发起形态、DAZ 语义与误差预算回归。同一组输入按三种驱动各跑一遍，
//   结果须逐位相同。
//
// NOTE:
//   1. hold：in_data 保持到出结果；pulse：in_data 只给一拍；stream：每拍发起一条
//   2. R1/R4 自洽 |y*y*x-1| < 1e-3，R2 pulse 等于 hold，R3 stream 等于 hold，R5 结果不含 X
//   3. R6 实测延迟等于 RSQRT_FUNC_LAT，R7 hold 结果等于冻结参考，R8 flush 作废在飞运算
//   4. R9/R10 denormal 输入出同符号 Inf，R11 扫满两张表 2048 点，最大相对误差 < 5e-4
//==============================================================================================//
`include "sfu_lat.vh"

module tb_rsqrt_stream;

    integer errors = 0, checks = 0;
    task chk(input cond, input [2047:0] name);
        begin
            checks = checks + 1;
            if (cond) $display("  PASS  %0s", name);
            else begin errors = errors + 1; $display("  FAIL  %0s", name); end
        end
    endtask

    reg clk = 1'b0, rst_n = 1'b0;
    always #10 clk = ~clk;

    reg         in_valid = 1'b0, flush = 1'b0;
    reg  [31:0] in_data  = 32'h0;
    wire        out_valid;
    wire [31:0] out_data;

    rsqrt_func dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .flush(flush),
        .in_data(in_data), .out_valid(out_valid), .out_data(out_data)
    );

    // 输入 x[i] = 1.0 + i*0.37，x[0] 取 2.0
    localparam integer N = 8;
    reg [31:0] xv [0:N-1];
    initial begin
        xv[0] = 32'h40000000;   // 2.00，2 的幂
        xv[1] = 32'h3faf5c29;   // 1.37
        xv[2] = 32'h3fdeb852;   // 1.74，尾数索引 757
        xv[3] = 32'h40070a3e;   // 2.11，奇数阶码
        xv[4] = 32'h401eb852;   // 2.48
        xv[5] = 32'h40366666;   // 2.85
        xv[6] = 32'h404e147b;   // 3.22
        xv[7] = 32'h4065c290;   // 3.59
    end

    localparam integer NDEN = 24;
    reg [31:0] den_x [0:NDEN-1];
    integer di;
    initial begin
        for (di = 0; di < 23; di = di + 1)
            den_x[di] = 32'h00000001 << di;
        den_x[23] = 32'h007fffff;
    end

    // 冻结参考输出，行为变化即报错
    reg [31:0] gold [0:N-1];
    initial begin
        gold[0] = 32'h3f3504f3;   // 1/sqrt(2.00)
        gold[1] = 32'h3f5ac8c1;   // 1/sqrt(1.37)
        gold[2] = 32'h3f421d50;   // 1/sqrt(1.74)，偶数表第 757 项原文
        gold[3] = 32'h3f304387;   // 1/sqrt(2.11)
        gold[4] = 32'h3f229bdd;   // 1/sqrt(2.48)
        gold[5] = 32'h3f17a6d6;   // 1/sqrt(2.85)
        gold[6] = 32'h3f0eb0e0;   // 1/sqrt(3.22)
        gold[7] = 32'h3f071d55;   // 1/sqrt(3.59)
    end

    // IEEE-754 位图转 real
    function real f2r(input [31:0] u);
        real m; integer e, i;
        begin
            e = u[30:23];
            m = (e == 0) ? 0.0 : 1.0;
            for (i = 0; i < 23; i = i + 1)
                if (u[i]) m = m + (2.0 ** (i - 23));
            if (e == 0) f2r = m * (2.0 ** -126);
            else        f2r = m * (2.0 ** (e - 127));
            if (u[31]) f2r = -f2r;
        end
    endfunction

    function real fabs(input real a);
        begin fabs = (a < 0.0) ? -a : a; end
    endfunction

    function [31:0] ulp_dist_pos(input [31:0] a, input [31:0] b);
        begin ulp_dist_pos = (a >= b) ? (a - b) : (b - a); end
    endfunction

    // 自洽：|y*y*x - 1| < 1e-3
    function selfok(input [31:0] y, input [31:0] x);
        real ry, rx, t;
        begin
            ry = f2r(y); rx = f2r(x);
            t  = ry * ry * rx - 1.0;
            selfok = (fabs(t) < 0.001);
        end
    endfunction

    reg [31:0] o_hold [0:N-1], o_pulse [0:N-1], o_str [0:N-1];
    reg [31:0] o_den [0:NDEN-1];
    reg [31:0] o_tmp, sc_x, sc_y, worst_x;
    integer    l_tmp, rp;
    real       max_rel, rel_e, ref_y;
    integer    l_hold [0:N-1], l_pulse [0:N-1];
    integer    l_den [0:NDEN-1];

    // 逐条发起：keep=1 保持 in_data，keep=0 立刻换成无关值。
    // in_valid 被采样那一拍记为第 0 拍，k 从其后一个沿数起，故 lat = k + 1
    integer k;
    task drv_one(input [31:0] x, input keep, output [31:0] o, output integer lat);
        begin
            o = 32'hxxxx_xxxx; lat = -1;
            @(negedge clk);
            in_valid = 1'b1; in_data = x;
            @(posedge clk);
            @(negedge clk);
            in_valid = 1'b0;
            if (!keep) in_data = 32'hdead_beef;
            for (k = 1; k <= 12; k = k + 1) begin
                @(posedge clk); #1;
                if (lat < 0 && out_valid) begin o = out_data; lat = k + 1; end
                @(negedge clk);
            end
        end
    endtask

    // 每拍发起一条，in_data 每拍都换
    integer si, wp;
    task drv_stream;
        begin
            wp = 0;
            @(negedge clk);
            for (si = 0; si < N; si = si + 1) begin
                in_valid = 1'b1; in_data = xv[si];
                @(posedge clk); #1;
                if (out_valid && wp < N) begin o_str[wp] = out_data; wp = wp + 1; end
                @(negedge clk);
            end
            in_valid = 1'b0; in_data = 32'hdead_beef;
            for (k = 0; k < 16; k = k + 1) begin
                @(posedge clk); #1;
                if (out_valid && wp < N) begin o_str[wp] = out_data; wp = wp + 1; end
                @(negedge clk);
            end
        end
    endtask

    // 扫满两张表的全部表项，尾数低 13 位取满，落在每个表项区间误差最大的一端
    localparam integer NSC = 2048;
    function [31:0] scan_x(input integer n);
        begin scan_x = {1'b0, (n[10] ? 8'd128 : 8'd127), n[9:0], 13'h1fff}; end
    endfunction

    integer sp;
    task scan_rel;
        begin
            max_rel = 0.0; worst_x = 32'd0; rp = 0;
            @(negedge clk);
            for (sp = 0; sp < NSC + 16; sp = sp + 1) begin
                if (sp < NSC) begin
                    in_valid = 1'b1; in_data = scan_x(sp);
                end else begin
                    in_valid = 1'b0; in_data = 32'hdead_beef;
                end
                @(posedge clk); #1;
                if (out_valid && rp < NSC) begin
                    sc_x  = scan_x(rp);
                    ref_y = 1.0 / $sqrt(f2r(sc_x));
                    rel_e = fabs(f2r(out_data) - ref_y) / ref_y;
                    if (rel_e > max_rel) begin max_rel = rel_e; worst_x = sc_x; end
                    rp = rp + 1;
                end
                @(negedge clk);
            end
            in_valid = 1'b0;
        end
    endtask

    integer i, bad, badlat, xcnt, fl;
    initial begin
        for (i = 0; i < N; i = i + 1) o_str[i] = 32'hxxxx_xxxx;
        $display("");
        $display("tb_rsqrt_stream : rsqrt_func 的发起形态、DAZ 与误差预算");
        $display("  三种驱动跑同一组输入，须逐位相同。RSQRT_FUNC_LAT = %0d", `RSQRT_FUNC_LAT);
        repeat (4) @(negedge clk); rst_n = 1'b1; repeat (2) @(negedge clk);

        $display("");
        $display("[A] hold 驱动");
        for (i = 0; i < N; i = i + 1) drv_one(xv[i], 1'b1, o_hold[i], l_hold[i]);
        bad = 0; xcnt = 0; badlat = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (^o_hold[i] === 1'bx) xcnt = xcnt + 1;
            else if (!selfok(o_hold[i], xv[i])) bad = bad + 1;
            if (l_hold[i] !== `RSQRT_FUNC_LAT) badlat = badlat + 1;
        end
        chk(bad == 0 && xcnt == 0, "R1 hold self-consistent |y*y*x-1| < 1e-3");
        if (bad || xcnt) for (i = 0; i < N; i = i + 1)
            $display("      hold x=%08x y=%08x lat=%0d", xv[i], o_hold[i], l_hold[i]);

        $display("");
        $display("[B] pulse 驱动");
        for (i = 0; i < N; i = i + 1) drv_one(xv[i], 1'b0, o_pulse[i], l_pulse[i]);
        bad = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (o_pulse[i] !== o_hold[i]) begin
                bad = bad + 1;
                $display("      x=%08x  pulse=%08x  hold=%08x", xv[i], o_pulse[i], o_hold[i]);
            end
            if (l_pulse[i] !== `RSQRT_FUNC_LAT) badlat = badlat + 1;
        end
        chk(bad == 0, "R2 pulse === hold (in_data need not be held)");

        $display("");
        $display("[C] stream 驱动");
        drv_stream;
        bad = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (o_str[i] !== o_hold[i]) begin
                bad = bad + 1;
                $display("      x=%08x  stream=%08x  hold=%08x", xv[i], o_str[i], o_hold[i]);
            end
        end
        chk(bad == 0, "R3 stream(II=1) === hold");

        bad = 0; xcnt = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (^o_str[i] === 1'bx) xcnt = xcnt + 1;
            else if (!selfok(o_str[i], xv[i])) bad = bad + 1;
        end
        chk(bad == 0 && xcnt == 0, "R4 stream self-consistent |y*y*x-1| < 1e-3");
        if (bad || xcnt) $display("      bad=%0d  x=%0d  / %0d", bad, xcnt, N);

        // 表未加载时结果全为 X，而 X === X 为真，R2/R3 会误判为通过
        xcnt = 0;
        for (i = 0; i < N; i = i + 1) begin
            if (^o_hold[i] === 1'bx)  xcnt = xcnt + 1;
            if (^o_pulse[i] === 1'bx) xcnt = xcnt + 1;
            if (^o_str[i] === 1'bx)   xcnt = xcnt + 1;
        end
        chk(xcnt == 0, "R5 no X in any driver's results (rsqrt_*_lut.mem really loaded)");

        chk(badlat == 0, "R6 measured latency == RSQRT_FUNC_LAT");
        if (badlat) for (i = 0; i < N; i = i + 1)
            $display("      lat hold=%0d pulse=%0d", l_hold[i], l_pulse[i]);

        bad = 0;
        for (i = 0; i < N; i = i + 1) if (o_hold[i] !== gold[i]) bad = bad + 1;
        chk(bad == 0, "R7 hold === frozen reference");
        if (bad) begin
            $display("      实测值如下，确认是有意的行为变化后再更新参考：");
            for (i = 0; i < N; i = i + 1)
                $display("        gold[%0d] = 32'h%08x;   // 参考为 %08x", i, o_hold[i], gold[i]);
        end

        $display("");
        $display("[D] denormal 输入的 DAZ");
        bad = 0; xcnt = 0; badlat = 0;
        for (i = 0; i < NDEN; i = i + 1) begin
            drv_one(den_x[i], 1'b0, o_den[i], l_den[i]);
            if (^o_den[i] === 1'bx) xcnt = xcnt + 1;
            else if (o_den[i] !== (den_x[i][31] ? 32'hFF800000 : 32'h7F800000))
                bad = bad + 1;
            if (l_den[i] !== `RSQRT_FUNC_LAT) badlat = badlat + 1;
        end
        chk(bad == 0 && xcnt == 0 && badlat == 0,
            "R9 denormal in -> same-sign zero -> same-sign Inf (DAZ)");
        if (bad || xcnt || badlat)
            for (i = 0; i < NDEN; i = i + 1)
                $display("      den x=%08x y=%08x lat=%0d", den_x[i], o_den[i], l_den[i]);
        drv_one(32'h00000001, 1'b0, o_tmp, l_tmp);
        chk(o_tmp === 32'h7F800000, "R10a rsqrt(0x00000001) == +Inf (DAZ)");
        if (o_tmp !== 32'h7F800000) $display("      got %08x", o_tmp);
        drv_one(32'h807FFFFF, 1'b0, o_tmp, l_tmp);
        chk(o_tmp === 32'hFF800000, "R10b rsqrt(negative denormal) == -Inf (DAZ)");
        if (o_tmp !== 32'hFF800000) $display("      got %08x", o_tmp);

        $display("");
        $display("[F] 相对误差预算");
        scan_rel();
        chk(rp == NSC, "R11a scan collected every result (no silent drop)");
        chk(max_rel < 5.0e-4, "R11b max relative error < 5e-4 (the documented budget)");
        $display("      %0d 点实测最大相对误差 %0e，最坏输入 %08x", rp, max_rel, worst_x);

        $display("");
        $display("[E] flush");
        @(negedge clk); in_valid = 1'b1; in_data = xv[1];
        @(posedge clk); @(negedge clk); in_valid = 1'b0;
        @(posedge clk); @(negedge clk); flush = 1'b1;
        @(posedge clk); @(negedge clk); flush = 1'b0;
        fl = 0;
        for (k = 0; k < 12; k = k + 1) begin
            @(posedge clk); #1; if (out_valid) fl = fl + 1;
            @(negedge clk);
        end
        chk(fl == 0, "R8 flush kills in-flight op (no out_valid afterwards)");

        $display("");
        $display("=====================================================");
        if (errors == 0) $display(" SUMMARY ALL PASS   (%0d checks)", checks);
        else             $display(" SUMMARY %0d FAIL / %0d checks", errors, checks);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #200_000;
        $display("  FAIL  [WATCHDOG] tb_rsqrt_stream timeout");
        $display(" SUMMARY WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
