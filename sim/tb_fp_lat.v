`timescale 1ns/1ps
`include "fp32_lat.vh"
//============================================================================
// tb_fp_lat —— fp32_lat.vh 延迟常数的约束 TB
//
// fp32_lat.vh 声明各计算单元的流水延迟，RTL 的 valid 链是其实际取值。
// 例化期断言只能约束常数之间的关系，两者的一致性由本 TB 施加。
//
// 判据 17 条：
//   [1]-[5]   五个计算单元的 in_valid 到 out_valid 实测拍数等于对应宏。
//             五个单元共享同一触发脉冲，一次发射同时测量。
//   [6]       fp32_mac_unit 末项 prod_valid 到 out_valid 等于 FP32_MAC_OUT_LAT。
//   [7]       fp32_mac_unit 首项 prod_valid 到 out_valid 等于
//             (K-1) * FP32_MAC_PACE + FP32_MAC_OUT_LAT，与 [6] 构成交叉约束。
//   [8]       按 FP32_MAC_PACE 喂入时结果精确正确。
//   [9]       非融合那一档（FuseMul=0）的输出延迟等于 FP32_MAC_OUT_LAT_F(0)。
//             两档共用一个公式，任一档写错都会被这一对交叉约束抓住。
//   [10]-[13] 四个精确值逐位比对，排除残留 valid 造成的误判。
//   [14]-[16] fp32_mac_unit 三条调用契约的断言各注错一次见红：C2 单独拉高 last；
//             C3 在末项之后第 1 拍再喂一个积，那一拍模块内部没有忙标志是高的，
//             用来证明区间取的是末项到 out_valid；C3 再在 out_valid 前一拍注一次。
//   [17]      C4 与 C5 在全程合法激励下一次都没报。
//
// 注：FP32_MAC_PACE 现在是 1，已是下界，少一拍喂入那条判据不可达，换成契约注入。
//
// 运行方式（fp32_recip 的 .mem 为裸文件名，工作目录须为 rtl/ip/sfu/）：
//   cd Main/rtl/ip/sfu
//   iverilog -g2012 -I../fp -o /tmp/tb_fp_lat.vvp \
//     ../../../sim/fp_round/tb_fp_lat.v \
//     ../fp/fp32_add.v ../fp/fp32_mul_pipe.v ../fp/fp32_cmp.v \
//     ../fp/fp32_cvt.v ../fp/fp32_recip.v ../fp/fp32_mac_unit.v \
//     bram_lut_1024x32.v
//   vvp /tmp/tb_fp_lat.vvp
//============================================================================

module tb_fp_lat;

    localparam Pace     = `FP32_MAC_PACE;       // 定点窗口累加的环长，1 拍
    localparam K        = 8;                    // C 组的点积项数
    localparam ONE      = 32'h3F800000;         // 1.0
    localparam K_EXACT  = 32'h41000000;         // 8.0 = K 项 1.0*1.0 的精确和

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    integer n_pass = 0, n_fail = 0;

    task check_lat;
        input [255:0] name;
        input integer got;
        input integer want;
        begin
            if (got === want) begin
                n_pass = n_pass + 1;
                $display("  PASS: %0s 实测 %0d 拍", name, got);
            end else if (got < 0) begin
                n_fail = n_fail + 1;
                $display("  FAIL: %0s 超时无 out_valid（fp32_lat.vh 说 %0d 拍）", name, want);
            end else begin
                n_fail = n_fail + 1;
                $display("  FAIL: %0s 实测 %0d 拍，fp32_lat.vh 说 %0d 拍", name, got, want);
            end
        end
    endtask

    task check_val;
        input [255:0] name;
        input [31:0] got;
        input [31:0] want;
        begin
            if (got === want) begin
                n_pass = n_pass + 1;
                $display("  PASS: %0s = %08x", name, got);
            end else begin
                n_fail = n_fail + 1;
                $display("  FAIL: %0s got=%08x exp=%08x", name, got, want);
            end
        end
    endtask

    // A 组：五个计算单元共享一个触发脉冲，同时测量五条延迟
    reg         trig = 0;
    reg  [31:0] opa = 0, opb = 0;
    reg  [6:0]  imm = 0;

    wire        ov_add, ov_mul, ov_cmp, ov_cvt, ov_rcp;
    wire [31:0] d_add,  d_mul,  d_cmp,  d_cvt,  d_rcp;

    fp32_add      u_add (.clk(clk), .rst_n(rst_n), .a(opa), .b(opb),
                         .s(d_add), .in_valid(trig), .flush(1'b0), .out_valid(ov_add));
    fp32_mul_pipe u_mul (.clk(clk), .rst_n(rst_n), .a(opa), .b(opb),
                         .p(d_mul), .in_valid(trig), .flush(1'b0), .out_valid(ov_mul));
    fp32_cmp      u_cmp (.clk(clk), .rst_n(rst_n), .a(opa), .b(opb), .gt_family(imm[0]),
                         .in_valid(trig), .flush(1'b0), .out_valid(ov_cmp), .result(d_cmp));
    fp32_cvt      u_cvt (.clk(clk), .rst_n(rst_n), .in(opa), .mode(imm[0]), .is_unsigned(imm[1]),
                         .in_valid(trig), .flush(1'b0), .out_valid(ov_cvt), .out(d_cvt));
    fp32_recip    u_rcp (.clk(clk), .rst_n(rst_n), .a(opa),
                         .in_valid(trig), .flush(1'b0), .out_valid(ov_rcp), .result(d_rcp));

    integer t0 = 0;
    integer lat_add, lat_mul, lat_cmp, lat_cvt, lat_rcp;
    reg [31:0] val_add, val_mul, val_cvt, val_rcp;

    // negedge 观察：cyc 与各 out_valid 此时均已稳定，避开 posedge 的调度竞态。
    // 只记录第一次，后面的脉冲不覆盖。
    always @(negedge clk) begin
        if (ov_add && lat_add < 0) begin lat_add = cyc - t0; val_add = d_add; end
        if (ov_mul && lat_mul < 0) begin lat_mul = cyc - t0; val_mul = d_mul; end
        if (ov_cmp && lat_cmp < 0) begin lat_cmp = cyc - t0;                   end
        if (ov_cvt && lat_cvt < 0) begin lat_cvt = cyc - t0; val_cvt = d_cvt; end
        if (ov_rcp && lat_rcp < 0) begin lat_rcp = cyc - t0; val_rcp = d_rcp; end
    end

    // 发出单拍触发，随后等待各观察器记录
    task fire;
        input [31:0] a_in;
        input [31:0] b_in;
        input [6:0]  im_in;
        begin
            lat_add = -1; lat_mul = -1; lat_cmp = -1; lat_cvt = -1; lat_rcp = -1;
            @(negedge clk);
            t0  = cyc;
            opa = a_in; opb = b_in; imm = im_in;
            trig = 1;
            @(negedge clk);
            trig = 0;
            repeat (32) @(negedge clk);   // 32 拍足够各单元排空
        end
    endtask

    // B/C 组：mac_unit 单独例化
    reg         m_pv = 0, m_load = 0, m_last = 0;
    reg  [31:0] m_a = 0, m_b = 0, m_psum = 0;
    wire [31:0] m_out;
    wire        m_ov;

    fp32_mac_unit u_mac (.clk(clk), .rst_n(rst_n), .prod_valid(m_pv), .acc_load(m_load),
                         .last(m_last), .a(m_a), .b(m_b), .psum_in(m_psum),
                         .mac_out(m_out), .out_valid(m_ov));

    // 非融合那一档：项源取乘法器舍入后的输出，比融合档晚 FP32_MUL_LAT-1 拍。
    // 两档的延迟共用 FP32_MAC_OUT_LAT_F 一个公式，互为交叉约束
    wire [31:0] m0_out;
    wire        m0_ov;
    fp32_mac_unit #(.FuseMul(0)) u_mac0 (
        .clk(clk), .rst_n(rst_n), .prod_valid(m_pv), .acc_load(m_load),
        .last(m_last), .a(m_a), .b(m_b), .psum_in(m_psum),
        .mac_out(m0_out), .out_valid(m0_ov));

    integer lat_mac0;
    always @(negedge clk) begin
        if (m0_ov && lat_mac0 < 0) lat_mac0 = cyc - m_t0;
    end

    integer m_t0 = 0, m_first = 0, lat_mac, lat_mac_full;
    reg [31:0] m_captured;

    always @(negedge clk) begin
        if (m_ov && lat_mac < 0) begin
            lat_mac      = cyc - m_t0;       // 末项发射 -> out_valid
            lat_mac_full = cyc - m_first;    // 首项发射 -> out_valid
            m_captured   = m_out;
        end
    end

    // 以 gap 拍为间隔喂入 K 项 1.0*1.0，psum 为 0。
    // gap 等于 FP32_MAC_PACE 时满足调用契约，小于该值时累加器尚未更新即被读取。
    task run_dot;
        input integer gap;
        integer k, c;
        begin
            lat_mac = -1; lat_mac_full = -1; lat_mac0 = -1;
            m_captured = 32'hDEADBEEF;
            @(negedge clk);
            m_psum = 32'd0; m_load = 1; m_pv = 0; m_last = 0;
            @(negedge clk);
            m_load = 0;
            for (k = 0; k < K; k = k + 1) begin
                m_a = ONE; m_b = ONE; m_pv = 1; m_last = (k == K-1);
                if (k == 0)     m_first = cyc;   // 首项发射拍
                if (k == K-1)   m_t0    = cyc;   // 末项发射拍 = out_valid 的基准
                @(negedge clk);
                m_pv = 0; m_last = 0; m_a = 0; m_b = 0;
                for (c = 1; c < gap; c = c + 1) @(negedge clk);
            end
            repeat (32) @(negedge clk);
        end
    endtask

    // 契约注错。断言只计数不打印，靠计数器的增量当判据
    task inject;
        input [255:0] name;
        input integer which;        // 2 = C2 单独拉 last；3 = C3 飞行期；4 = C3 出结果前一拍
        input integer want_c2;
        input integer want_c3;
        integer c2_0, c3_0, k;
        begin
            c2_0 = u_mac.mac_c2; c3_0 = u_mac.mac_c3;
            u_mac.mac_assert_quiet = 1'b1;
            u_mac0.mac_assert_quiet = 1'b1;
            @(negedge clk);
            m_psum = 32'd0; m_load = 1; m_pv = 1; m_last = 0; m_a = ONE; m_b = ONE;
            @(negedge clk);
            m_load = 0;
            for (k = 1; k < K; k = k + 1) begin
                m_pv = 1; m_last = (k == K-1);
                @(negedge clk);
            end
            m_pv = 0; m_last = 0;
            if (which == 2) begin              // last 单独拉高一拍
                m_last = 1; @(negedge clk); m_last = 0;
            end else if (which == 3) begin     // 末项之后第 1 拍就喂
                m_pv = 1; @(negedge clk); m_pv = 0;
            end else begin                     // 等到 out_valid 前一拍再喂
                repeat (`FP32_MAC_OUT_LAT - 1) @(negedge clk);
                m_pv = 1; @(negedge clk); m_pv = 0;
            end
            repeat (32) @(negedge clk);
            u_mac.mac_assert_quiet = 1'b0;
            u_mac0.mac_assert_quiet = 1'b0;
            if ((u_mac.mac_c2 - c2_0 >= want_c2) && (u_mac.mac_c3 - c3_0 >= want_c3)) begin
                n_pass = n_pass + 1;
                $display("  PASS: %0s 契约断言如期计数 (C2 +%0d, C3 +%0d)",
                         name, u_mac.mac_c2 - c2_0, u_mac.mac_c3 - c3_0);
            end else begin
                n_fail = n_fail + 1;
                $display("  FAIL: %0s 注入违约但断言没红 (C2 +%0d 期望 >=%0d, C3 +%0d 期望 >=%0d)",
                         name, u_mac.mac_c2 - c2_0, want_c2,
                         u_mac.mac_c3 - c3_0, want_c3);
            end
        end
    endtask

    initial begin
        rst_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        $display("=== fp32_lat.vh 对账（实测 in_valid -> out_valid）===");
        $display("    Pace = FP32_MAC_PACE = %0d", Pace);

        // A 组：一次发射，同时量五条，顺带做 D 组的逐位检查
        fire(32'h3F800000, 32'h40000000, 7'd0);        // 1.0, 2.0
        check_lat("[1]  fp32_add     ", lat_add, `FP32_ADD_LAT);
        check_lat("[3]  fp32_cmp     ", lat_cmp, `FP32_CMP_LAT);
        check_val("[10] 1.0+2.0      ", val_add, 32'h40400000);

        fire(32'h3FC00000, 32'h40000000, 7'd0);        // 1.5, 2.0
        check_lat("[2]  fp32_mul_pipe", lat_mul, `FP32_MUL_LAT);
        check_val("[11] 1.5*2.0      ", val_mul, 32'h40400000);

        fire(32'd5, 32'd0, 7'd0);                      // i2f(5)
        check_lat("[4]  fp32_cvt     ", lat_cvt, `FP32_CVT_LAT);
        check_val("[12] i2f(5)       ", val_cvt, 32'h40A00000);

        fire(32'h40000000, 32'd0, 7'd0);               // 1/2.0，2 的幂走精确路径
        check_lat("[5]  fp32_recip   ", lat_rcp, `FP32_RECIP_LAT);
        check_val("[13] 1/2.0        ", val_rcp, 32'h3F000000);

        // B 组：mac_unit 的两条延迟恒等式
        run_dot(Pace);
        // [6] 末项发射到 out_valid，仅含乘法、加法与输出寄存，与喂入间隔无关
        check_lat("[6]  mac last->ov ", lat_mac, `FP32_MAC_OUT_LAT);
        // [7] 首项发射到 out_valid，含 K-1 个喂入间隔与一次合成延迟。
        //     FP32_MAC_PACE 与 FP32_MAC_OUT_LAT 任一取值错误，本条即报错。
        check_lat("[7]  mac head->ov ", lat_mac_full, (K-1)*Pace + `FP32_MAC_OUT_LAT);

        // [8] 按 FP32_MAC_PACE 喂入结果精确正确
        check_val("[8]  Pace   feed  ", m_captured, K_EXACT);
        // [9] 非融合那一档的延迟。两档共用 FP32_MAC_OUT_LAT_F 一个公式
        check_lat("[9]  mac(FuseMul=0)", lat_mac0, `FP32_MAC_OUT_LAT_F(0));

        // C 组：三条调用契约各注错一次见红
        inject("[14] C2 last alone   ", 2, 1, 0);
        inject("[15] C3 at last+1     ", 3, 0, 1);
        inject("[16] C3 before ovalid ", 4, 0, 1);

        // [17] C4 与 C5 在全程合法激励下一次都没报。前面的注入只碰 C2/C3，
        //      这两条的计数必须仍是 0 —— 它们红了说明延迟宏或项数上限对不上
        if (u_mac.mac_c4 == 0 && u_mac.mac_c5 == 0
            && u_mac0.mac_c4 == 0 && u_mac0.mac_c5 == 0) begin
            n_pass = n_pass + 1;
            $display("  PASS: [17] C4/C5 全程零计数（两档各自的输出延迟与项数上限都对）");
        end else begin
            n_fail = n_fail + 1;
            $display("  FAIL: [17] C4=%0d/%0d C5=%0d/%0d 应全为 0",
                     u_mac.mac_c4, u_mac0.mac_c4, u_mac.mac_c5, u_mac0.mac_c5);
        end

        $display("================================================");
        $display("tb_fp_lat: %0d PASS, %0d FAIL", n_pass, n_fail);
        if (n_fail == 0) $display("ALL PASS");
        else             $display("HAS FAILURES");
        $finish;
    end

endmodule
