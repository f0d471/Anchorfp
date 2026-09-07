//==============================================================================================//
// FILE: fp32_mac_assert.vh
//
// DESCRIPTION: fp32_mac_unit 的调用契约断言，仅仿真。由主文件在 `ifndef SYNTHESIS 内 include。
//
// NOTE:
//   1. 五条契约 C1 到 C5 的正文见 rtl/datapath-manual.md 第 5.1 节，改契约要同时改那一份
//   2. 每条各有独立计数器供 TB 层次引用，mac_assert_quiet 置 1 则只计数不打印
//   3. 网表里不检查这五条：它们是调用方的义务，硬件按契约成立来设计
//   4. 整份内容裹在 FP32_MAC_ASSERT_INLINE 里，宏没定义时是空的。本仓的 lint 把 .vh
//      单独喂给 verilator，而这里全是模块内的语句，不裹起来单独解析必然是语法错。
//      忘了定义宏不会静默失效：tb_mac_win 层次引用 dut.mac_c1 到 mac_c5，会编译失败
//==============================================================================================//

`ifdef FP32_MAC_ASSERT_INLINE

    localparam PaceMin = `FP32_MAC_PACE;
    localparam MaxTerm = 1 << GrowW;   // 求和增长位撑得住的项数，2^GrowW

    integer mac_c1, mac_c2, mac_c3, mac_c4, mac_c5;
    integer mac_gap;      // 距上一次 prod_valid 的拍数
    integer mac_t_last;   // 末项发射的拍号
    integer mac_cyc;
    integer mac_nterm;    // 本 tile 已进窗口的项数
    reg     mac_drain;    // 末项已发、结果未出
    reg     mac_assert_quiet;

    // 本 tile 的当前计数。acc_load 那一拍 mac_nterm 还是上个 tile 的值
    wire [31:0] mac_nterm_cur = acc_load ? 32'd0 : mac_nterm[31:0];

    initial begin
        mac_c1 = 0; mac_c2 = 0; mac_c3 = 0; mac_c4 = 0; mac_c5 = 0;
        mac_gap = 1000; mac_t_last = 0; mac_cyc = 0; mac_nterm = 0;
        mac_drain = 1'b0; mac_assert_quiet = 1'b0;
    end

    always @(posedge clk) begin
        mac_cyc <= mac_cyc + 1;
        if (!rst_n) begin
            mac_gap   <= 1000;
            mac_drain <= 1'b0;
            mac_nterm <= 0;
        end else begin
            // C1 相邻 prod_valid 的间隔不小于 FP32_MAC_PACE
            if (prod_valid) begin
                if (mac_gap < PaceMin) begin
                    mac_c1 <= mac_c1 + 1;
                    if (!mac_assert_quiet)
                        $display("[fp32_mac_unit] **ASSERT FAIL** C1 喂积间隔 %0d 拍，契约要求 >= %0d (t=%0t)",
                                 mac_gap, PaceMin, $time);
                end
                mac_gap <= 1;
            end else if (mac_gap < 1000) begin
                mac_gap <= mac_gap + 1;
            end

            // C2 last 与末项 prod_valid 同拍
            if (last && !prod_valid) begin
                mac_c2 <= mac_c2 + 1;
                if (!mac_assert_quiet)
                    $display("[fp32_mac_unit] **ASSERT FAIL** C2 last 与 prod_valid 不同拍 (t=%0t)",
                             $time);
            end

            // C3 末项之后到 out_valid 之前不许再喂积，区间从末项算起
            if (mac_drain && prod_valid) begin
                mac_c3 <= mac_c3 + 1;
                if (!mac_assert_quiet)
                    $display("[fp32_mac_unit] **ASSERT FAIL** C3 末项之后 out_valid 之前又喂积 (t=%0t)",
                             $time);
            end
            if (prod_valid && last) begin
                mac_drain  <= 1'b1;
                mac_t_last <= mac_cyc;
            end else if (out_valid) begin
                mac_drain <= 1'b0;
            end

            // C4 末项到 out_valid 的拍数等于 FP32_MAC_OUT_LAT_F
            if (out_valid && mac_drain
                && ((mac_cyc - mac_t_last) != `FP32_MAC_OUT_LAT_F(FuseMul))) begin
                mac_c4 <= mac_c4 + 1;
                if (!mac_assert_quiet)
                    $display("[fp32_mac_unit] **ASSERT FAIL** C4 末项到 out_valid 实测 %0d 拍，FP32_MAC_OUT_LAT_F(%0d) 说 %0d (t=%0t)",
                             mac_cyc - mac_t_last, FuseMul,
                             `FP32_MAC_OUT_LAT_F(FuseMul), $time);
            end

            // C5 一个 tile 内进窗口的项数不超过已认证的上限
            if (acc_load)      mac_nterm <= ps_norm ? 1 : 0;
            else if (fire_in)  mac_nterm <= mac_nterm + 1;
            if (fire_in && (mac_nterm_cur >= MaxTerm)) begin
                mac_c5 <= mac_c5 + 1;
                if (!mac_assert_quiet)
                    $display("[fp32_mac_unit] **ASSERT FAIL** C5 本 tile 项数超过已认证的 %0d (t=%0t)",
                             MaxTerm, $time);
            end
        end
    end

`endif
