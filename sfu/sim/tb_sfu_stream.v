`timescale 1ns / 1ps
//==============================================================================================//
// TESTBENCH: tb_sfu_stream
//
// DESCRIPTION: exp_func、sin_func、cos_func 的发起形态与延迟回归。同一组输入按四种驱动各跑一遍，
//   结果须逐位相同。
//
// NOTE:
//   1. hold：in_data 保持到出结果；pulse：in_data 只给一拍；stream：每拍发起一条；ii2：隔一拍发起一条
//   2. sin 与 cos 各接一块表，两者同时被喂
//   3. X1 pulse 等于 hold，X2 stream 等于 hold，X8 ii2 等于 hold，X3 结果不含 X（表已加载）
//   4. X4 实测延迟等于 sfu_lat.vh，X5/X6/X7 零点精确值
//   5. X9 表末项为精确 1.0（cos 无零点出口的前提），X10 flush 作废在飞运算，X11 超出支持域返回 qNaN
//==============================================================================================//
`include "sfu_lat.vh"

module tb_sfu_stream;

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

    localparam integer N = 9;
    reg [31:0] xv [0:N-1];
    initial begin
        xv[0] = 32'h00000000;   //  0.0
        xv[1] = 32'h3f000000;   //  0.5
        xv[2] = 32'h3f800000;   //  1.0
        xv[3] = 32'h3faf5c29;   //  1.37
        xv[4] = 32'h40000000;   //  2.0
        xv[5] = 32'hbf000000;   // -0.5
        xv[6] = 32'h40400000;   //  3.0
        xv[7] = 32'hbf800000;   // -1.0
        xv[8] = 32'h48000000;   //  131072.0，超出相位归约支持域
    end

    // 被测单元，sin 与 cos 各带一块表
    reg         iv = 1'b0;
    reg         fl = 1'b0;   // 三个单元共用的 flush
    reg  [31:0] id = 32'h0;

    wire        e_ov, s_ov, c_ov;
    wire [31:0] e_od, s_od, c_od;
    wire [9:0]  s_ba, c_ba;
    wire [31:0] s_bd, c_bd;

    exp_func u_exp (.clk(clk), .rst_n(rst_n), .in_valid(iv), .flush(fl),
                    .in_data(id), .out_valid(e_ov), .out_data(e_od));

    sin_func u_sin (.clk(clk), .rst_n(rst_n), .in_valid(iv), .flush(fl),
                    .in_data(id), .out_valid(s_ov), .out_data(s_od),
                    .bram_addr(s_ba), .bram_dout(s_bd));
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_sin_tab (
        .clk(clk), .addr(s_ba), .dout(s_bd));

    cos_func u_cos (.clk(clk), .rst_n(rst_n), .in_valid(iv), .flush(fl),
                    .in_data(id), .out_valid(c_ov), .out_data(c_od),
                    .bram_addr(c_ba), .bram_dout(c_bd));
    bram_lut_1024x32 #(.Memfile("sin_lut.mem")) u_cos_tab (
        .clk(clk), .addr(c_ba), .dout(c_bd));

    // 采集：三个单元同时被喂，各按自己的 out_valid 收
    reg [31:0] o_hold [0:2][0:N-1], o_pulse [0:2][0:N-1], o_str [0:2][0:N-1];
    reg [31:0] o_ii2  [0:2][0:N-1];
    integer    l_hold [0:2];

    reg        cap;
    integer    wp_e, wp_s, wp_c;
    integer    which;                    // 0=hold 1=pulse 2=stream 3=ii2

    always @(posedge clk) if (cap) begin
        if (e_ov && wp_e < N) begin
            case (which)
                0: o_hold [0][wp_e] <= e_od;
                1: o_pulse[0][wp_e] <= e_od;
                2: o_str  [0][wp_e] <= e_od;
                default: o_ii2[0][wp_e] <= e_od;
            endcase
            wp_e <= wp_e + 1;
        end
        if (s_ov && wp_s < N) begin
            case (which)
                0: o_hold [1][wp_s] <= s_od;
                1: o_pulse[1][wp_s] <= s_od;
                2: o_str  [1][wp_s] <= s_od;
                default: o_ii2[1][wp_s] <= s_od;
            endcase
            wp_s <= wp_s + 1;
        end
        if (c_ov && wp_c < N) begin
            case (which)
                0: o_hold [2][wp_c] <= c_od;
                1: o_pulse[2][wp_c] <= c_od;
                2: o_str  [2][wp_c] <= c_od;
                default: o_ii2[2][wp_c] <= c_od;
            endcase
            wp_c <= wp_c + 1;
        end
    end

    integer k, i, u, bad, xc;

    // 逐条发起：keep=1 保持 in_data 到出结果，keep=0 立刻换成无关值
    task drv_one(input [31:0] x, input keep);
        begin
            @(negedge clk);
            iv = 1'b1; id = x;
            @(posedge clk);
            @(negedge clk);
            iv = 1'b0;
            if (!keep) id = 32'hdead_beef;
            for (k = 0; k < 12; k = k + 1) begin @(posedge clk); @(negedge clk); end
        end
    endtask

    // 按给定发起间隔连续发起，空档也填无关值
    integer gap;
    task drv_ii(input integer ii);
        begin
            @(negedge clk);
            for (i = 0; i < N; i = i + 1) begin
                iv = 1'b1; id = xv[i];
                @(posedge clk); @(negedge clk);
                for (gap = 1; gap < ii; gap = gap + 1) begin
                    iv = 1'b0; id = 32'hdead_beef;
                    @(posedge clk); @(negedge clk);
                end
            end
            iv = 1'b0; id = 32'hdead_beef;
            for (k = 0; k < 20; k = k + 1) begin @(posedge clk); @(negedge clk); end
        end
    endtask

    // 量一次延迟，in_valid 被采样那一拍记为第 0 拍，k 从其后一个沿数起，故 lat = k + 1
    integer lat_e, lat_s, lat_c;
    task meas_lat;
        begin
            lat_e = -1; lat_s = -1; lat_c = -1;
            @(negedge clk);
            iv = 1'b1; id = xv[3];
            @(posedge clk);
            @(negedge clk); iv = 1'b0;
            for (k = 1; k <= 12; k = k + 1) begin
                @(posedge clk); #1;
                if (lat_e < 0 && e_ov) lat_e = k + 1;
                if (lat_s < 0 && s_ov) lat_s = k + 1;
                if (lat_c < 0 && c_ov) lat_c = k + 1;
                @(negedge clk);
            end
        end
    endtask

    // 发起一条，在其第 at_cycle 拍拉 flush，此后（含同拍）不应再有 out_valid
    integer fl_e, fl_s, fl_c;
    task drv_flush(input integer at_cycle);
        begin
            fl_e = 0; fl_s = 0; fl_c = 0;
            @(negedge clk);
            iv = 1'b1; id = xv[3];
            @(posedge clk); @(negedge clk);
            iv = 1'b0; id = 32'hdead_beef;
            for (k = 1; k <= 12; k = k + 1) begin
                fl = (k == at_cycle);
                @(posedge clk); #1;
                if (k >= at_cycle) begin
                    if (e_ov) fl_e = fl_e + 1;
                    if (s_ov) fl_s = fl_s + 1;
                    if (c_ov) fl_c = fl_c + 1;
                end
                @(negedge clk);
            end
            fl = 1'b0;
        end
    endtask

    reg [8*8-1:0] uname [0:2];
    initial begin uname[0] = "exp"; uname[1] = "sin"; uname[2] = "cos"; end

    initial begin
        $display("");
        $display("tb_sfu_stream : exp/sin/cos 的发起形态与延迟");
        $display("  LAT: exp=%0d sin=%0d cos=%0d",
                 `EXP_FUNC_LAT, `SIN_FUNC_LAT, `COS_FUNC_LAT);
        repeat (4) @(negedge clk); rst_n = 1'b1; repeat (2) @(negedge clk);

        // A. hold
        which = 0; wp_e = 0; wp_s = 0; wp_c = 0; cap = 1'b1;
        for (i = 0; i < N; i = i + 1) drv_one(xv[i], 1'b1);
        cap = 1'b0;

        // B. pulse
        which = 1; wp_e = 0; wp_s = 0; wp_c = 0; cap = 1'b1;
        for (i = 0; i < N; i = i + 1) drv_one(xv[i], 1'b0);
        cap = 1'b0;

        // C. stream
        which = 2; wp_e = 0; wp_s = 0; wp_c = 0; cap = 1'b1;
        drv_ii(1);
        cap = 1'b0;

        // D. ii2
        which = 3; wp_e = 0; wp_s = 0; wp_c = 0; cap = 1'b1;
        drv_ii(2);
        cap = 1'b0;

        // 发起形态判据
        for (u = 0; u < 3; u = u + 1) begin
            $display("");
            $display("[%0s]", uname[u]);
            bad = 0;
            for (i = 0; i < N; i = i + 1)
                if (o_pulse[u][i] !== o_hold[u][i]) begin
                    if (bad < 3) $display("      x=%08x pulse=%08x hold=%08x",
                                          xv[i], o_pulse[u][i], o_hold[u][i]);
                    bad = bad + 1;
                end
            chk(bad == 0, {uname[u], " X1 pulse === hold (in_data need not be held)"});

            bad = 0;
            for (i = 0; i < N; i = i + 1)
                if (o_str[u][i] !== o_hold[u][i]) begin
                    if (bad < 3) $display("      x=%08x stream=%08x hold=%08x",
                                          xv[i], o_str[u][i], o_hold[u][i]);
                    bad = bad + 1;
                end
            chk(bad == 0, {uname[u], " X2 stream(II=1) === hold"});

            xc = 0;
            for (i = 0; i < N; i = i + 1) begin
                if (^o_hold[u][i]  === 1'bx) xc = xc + 1;
                if (^o_str[u][i]   === 1'bx) xc = xc + 1;
            end
            chk(xc == 0, {uname[u], " X3 no X in results (.mem really loaded)"});

            bad = 0;
            for (i = 0; i < N; i = i + 1)
                if (o_ii2[u][i] !== o_hold[u][i]) begin
                    if (bad < 3) $display("      x=%08x ii2=%08x hold=%08x",
                                          xv[i], o_ii2[u][i], o_hold[u][i]);
                    bad = bad + 1;
                end
            chk(bad == 0, {uname[u], " X8 II=2 === hold"});
        end

        // 延迟
        meas_lat;
        chk(lat_e == `EXP_FUNC_LAT && lat_s == `SIN_FUNC_LAT && lat_c == `COS_FUNC_LAT,
            "X4 measured latency == sfu_lat.vh for all three");
        $display("      measured: exp=%0d sin=%0d cos=%0d", lat_e, lat_s, lat_c);

        // 零点精确值，xv[0] 为 0.0
        chk(o_str[0][0] === 32'h3f800000, "X5 exp(0.0) == 1.0 exactly");
        chk(o_str[1][0] === 32'h00000000 || o_str[1][0] === 32'h80000000,
            "X6 sin(0.0) == 0");
        chk(o_str[2][0] === 32'h3f800000, "X7 cos(0.0) == 1.0 exactly");
        if (o_str[0][0] !== 32'h3f800000) $display("      exp(0)=%08x", o_str[0][0]);
        if (o_str[2][0] !== 32'h3f800000) $display("      cos(0)=%08x", o_str[2][0]);

        // 超出支持域的有限输入
        chk(o_str[1][8] === 32'h7fc00000,
            "X11 sin(131072.0) returns qNaN outside supported domain");
        chk(o_str[2][8] === 32'h7fc00000,
            "X11 cos(131072.0) returns qNaN outside supported domain");

        // flush
        drv_flush(1);
        chk(fl_e == 0, "X10 exp  flush kills in-flight op (no out_valid after)");
        chk(fl_s == 0, "X10 sin  flush kills in-flight op (no out_valid after)");
        chk(fl_c == 0, "X10 cos  flush kills in-flight op (no out_valid after)");
        if (fl_e | fl_s | fl_c)
            $display("      leaked out_valid: exp=%0d sin=%0d cos=%0d", fl_e, fl_s, fl_c);

        // 表末项，读被例化的那块表而不是另读一次文件
        chk(u_cos_tab.mem[1023] === 32'h3f800000,
            "X9 sin_lut.mem[1023] == 1.0 exactly (cos_func has no zero bypass)");
        $display("      sin_lut.mem[1023]=%08x  (closed-interval sampling)",
                 u_cos_tab.mem[1023]);

        $display("");
        $display("=====================================================");
        if (errors == 0) $display(" SUMMARY ALL PASS   (%0d checks)", checks);
        else             $display(" SUMMARY %0d FAIL / %0d checks", errors, checks);
        $display("=====================================================");
        $finish;
    end

    initial begin
        #500_000;
        $display("  FAIL  [WATCHDOG] tb_sfu_stream timeout");
        $display(" SUMMARY WATCHDOG TIMEOUT");
        $finish;
    end

endmodule
