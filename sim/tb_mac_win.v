`timescale 1ns/1ps
`include "fp32_lat.vh"

//==============================================================================================//
// TB: tb_mac_win
//
// DESCRIPTION: fp32_mac_unit 的定点窗口累加与逐位金标准（mac_win_model 第一层）对拍。
//
// NOTE:
//   1. 每拍喂一个积，acc_load 与首项同拍载入 psum，last 标末项
//   2. 一行 SUMMARY 合四条判定：结果逐位相同、末项到 out_valid 拍数恒定、
//      抬基准标志与金标准一致、模块内五条契约断言全程零计数
//   3. -DVECF 选向量文件，-DKLEN 选点积长度，-DKDEP 选一块的累加深度
//      （KDEP < KLEN 时按块喂，块间经 FP32 回灌串 psum）
//==============================================================================================//
`ifndef VECF
  `define VECF "vectors_dot.txt"
`endif
`ifndef KLEN
  `define KLEN 64
`endif
`ifndef TAGNAME
  `define TAGNAME "tb_mac_win"
`endif

// CSA = 1 已不在支持集合内，传 1 会在例化期就报错，见 fp32_mac_unit 的 NOTE 8
`ifndef CSA
  `define CSA 0
`endif
`ifndef FUSE
  `define FUSE 1
`endif
`ifndef KDEP
  `define KDEP `KLEN
`endif

module tb_mac_win;
    localparam K = `KLEN, KDEP = `KDEP, NTMAX = 20000;
    localparam ExpLat = `FP32_MAC_OUT_LAT_F(`FUSE);

    reg clk = 0, rst_n = 0;
    reg prod_valid, acc_load, last;
    reg [31:0] a, b, psum_in;
    wire [31:0] mac_out;
    wire out_valid, win_rescale;

    fp32_mac_unit #(.FuseMul(`FUSE), .UseCarrySave(`CSA)) dut (
        .clk(clk), .rst_n(rst_n), .prod_valid(prod_valid), .acc_load(acc_load),
        .last(last), .a(a), .b(b), .psum_in(psum_in),
        .mac_out(mac_out), .out_valid(out_valid), .win_rescale(win_rescale));

    always #5 clk = ~clk;

    reg [31:0] PS, AW[0:K-1], BW[0:K-1], EXP;
    integer SAT;
    integer fd, code, t, k, blk, total, bad, maxulp, d;
    integer bad_lat, bad_sat, res_seen, blk_res;
    reg [31:0] got, chain; reg got_sat;

    function integer ud(input [31:0] x, input [31:0] y);
        ud = (x >= y) ? (x - y) : (y - x);
    endfunction

    // 末项到出结果的拍数。用同一个 always 里的非阻塞赋值取时刻，
    // 避免两个 always 在同一时间步互相抢
    integer cyc, t_last, t_ov;
    initial begin cyc = 0; t_last = 0; t_ov = 0; end
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (prod_valid && last) t_last <= cyc;
        if (out_valid) begin t_ov <= cyc; got <= mac_out; got_sat <= win_rescale; end
    end

    task wait_capture;
        integer w;
        begin
            w = 0;
            while (!out_valid && w < 400) begin @(posedge clk); w = w + 1; end
        end
    endtask

    initial begin
        fd = $fopen(`VECF, "r");
        if (fd == 0) begin $display("ERR open %0s", `VECF); $finish; end
        total = 0; bad = 0; maxulp = 0; bad_lat = 0; bad_sat = 0; res_seen = 0;
        prod_valid = 0; acc_load = 0; last = 0; a = 0; b = 0; psum_in = 0;
        rst_n = 0; repeat (4) @(posedge clk); rst_n = 1; @(posedge clk);

        for (t = 0; t < NTMAX; t = t + 1) begin
            code = $fscanf(fd, "%h", PS);
            if (code != 1) t = NTMAX;   // EOF
            else begin
                for (k = 0; k < K; k = k + 1) code = $fscanf(fd, " %h %h", AW[k], BW[k]);
                code = $fscanf(fd, " %h %d", EXP, SAT);

                // 每拍喂一个积；acc_load 与首项同拍，与 gemm_pe_array 的产线时序一致。
                // K > KDEP 时按块喂，块间把上一块的结果当下一块的 psum ——
                // 跨 tile 的部分和在硬件里就是这么经 FP32 回灌串起来的
                chain = PS; blk_res = 0;
                for (blk = 0; blk < K; blk = blk + KDEP) begin
                    @(negedge clk);
                    psum_in = chain;
                    for (k = 0; k < KDEP; k = k + 1) begin
                        a = AW[blk+k]; b = BW[blk+k];
                        prod_valid = 1;
                        acc_load   = (k == 0);
                        last       = (k == KDEP-1);
                        @(negedge clk);
                    end
                    prod_valid = 0; acc_load = 0; last = 0; a = 0; b = 0;
                    wait_capture;
                    @(negedge clk);   // 让上一拍的非阻塞更新落定再读
                    chain = got;
                    if (got_sat) blk_res = 1;
                end

                total = total + 1;
                d = ud(got, EXP);
                if (got !== EXP) begin
                    bad = bad + 1;
                    if (bad <= 8)
                        $display("MISMATCH dot=%0d: got=%h exp=%h ulp=%0d",
                                 t, got, EXP, d);
                end
                if (d > maxulp) maxulp = d;

                if (blk_res[0] !== SAT[0]) begin
                    bad_sat = bad_sat + 1;
                    if (bad_sat <= 4)
                        $display("RESCALE dot=%0d: win_rescale=%0d 金标准=%0d", t, blk_res, SAT);
                end
                if (SAT != 0) res_seen = res_seen + 1;

                // 末项到出结果的拍数必须恒定。少了这一条，规格化少走一级也能"算对"
                if ((t_ov - t_last) !== ExpLat) begin
                    bad_lat = bad_lat + 1;
                    if (bad_lat <= 4)
                        $display("LATENCY dot=%0d: 末项->out_valid=%0d 拍，期望 %0d",
                                 t, t_ov - t_last, ExpLat);
                end
                @(negedge clk);
            end
        end
        $fclose(fd);

        $display("==== %0s: fp32_mac_unit 定点窗口累加 vs 逐位金标准 ====", `TAGNAME);
        $display("K=%0d  total=%0d  bad=%0d  maxulp=%0d  bad_lat=%0d  bad_res=%0d  抬基准向量=%0d  (期望延迟 %0d 拍)",
                 K, total, bad, maxulp, bad_lat, bad_sat, res_seen, ExpLat);
        // 断言计数一并报出：C1..C5 在合法激励下必须全零
        $display("SUMMARY %0s: total=%0d bad=%0d lat=%0d res=%0d C1..C5=%0d,%0d,%0d,%0d,%0d -> %0s",
                 `TAGNAME, total, bad, bad_lat, bad_sat,
                 dut.mac_c1, dut.mac_c2, dut.mac_c3, dut.mac_c4, dut.mac_c5,
                 ((total > 0) && (bad == 0) && (bad_lat == 0) && (bad_sat == 0)
                  && (dut.mac_c1 == 0) && (dut.mac_c2 == 0) && (dut.mac_c3 == 0)
                  && (dut.mac_c4 == 0) && (dut.mac_c5 == 0)) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
