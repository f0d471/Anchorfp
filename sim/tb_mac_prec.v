`timescale 1ns/1ps
//============================================================================
// tb_mac_prec —— fp32_mac_unit 的 mac_prec 报的是基准重锚，不是基准移动
//
// 两个事件的区别：win_rescale 报 raise_any（基准动过，多数情况无损），
// mac_prec 报 raise_clr（need > ShMax，旧的累加和被整个丢弃）。
// P2 是本 TB 的核心：没有它，mac_prec 退化成第二个 win_rescale。
//
// 判据：
//   P1 首项极小、次项极大，need > ShMax     mac_prec 与 win_rescale 都置位
//   P2 普通抬基准，need 落在 1..ShMax       win_rescale 置位而 mac_prec 不置位
//   P3 全程不抬基准                         两者都不置位，且证明 sticky 被 acc_load 清掉
//
// 跑法：由 run_all.sh 调用
//============================================================================
module tb_mac_prec;

    reg clk = 0, rst_n = 0;
    reg prod_valid, acc_load, last;
    reg [31:0] a, b, psum_in;
    wire [31:0] mac_out;
    wire out_valid, win_rescale, mac_prec;

    fp32_mac_unit dut (
        .clk(clk), .rst_n(rst_n),
        .prod_valid(prod_valid), .acc_load(acc_load), .last(last),
        .a(a), .b(b), .psum_in(psum_in),
        .mac_out(mac_out), .out_valid(out_valid),
        .win_rescale(win_rescale), .mac_prec(mac_prec)
    );

    always #5 clk = ~clk;

    integer errors = 0, checks = 0;
    task chk(input cond, input [1023:0] name);
        begin
            checks = checks + 1;
            if (cond) $display("  PASS  %0s", name);
            else begin errors = errors + 1; $display("  FAIL  %0s", name); end
        end
    endtask

    reg got_res, got_prec, got_ov;
    always @(posedge clk) begin
        if (!rst_n) got_ov <= 1'b0;
        else if (out_valid) begin
            got_res  <= win_rescale;
            got_prec <= mac_prec;
            got_ov   <= 1'b1;
        end
    end

    // 两项一个 tile，b 恒为 1.0，所以项的阶码就是 a 的阶码
    task two_term(input [31:0] x0, input [31:0] x1);
        begin
            got_ov = 1'b0; got_res = 1'bx; got_prec = 1'bx;
            @(negedge clk);
            prod_valid = 1'b1; acc_load = 1'b1; last = 1'b0;
            a = x0; b = 32'h3F800000; psum_in = 32'd0;
            @(negedge clk);
            prod_valid = 1'b1; acc_load = 1'b0; last = 1'b1; a = x1;
            @(negedge clk);
            prod_valid = 1'b0; acc_load = 1'b0; last = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    initial begin
        prod_valid = 0; acc_load = 0; last = 0;
        a = 0; b = 0; psum_in = 0;
        repeat (4) @(negedge clk); rst_n = 1'b1; repeat (2) @(negedge clk);

        $display("");
        $display("tb_mac_prec : mac_prec 只报基准重锚");

        // 2^-60 之后来 2^60，阶码差 120 > ShMax = 87
        two_term(32'h21800000, 32'h5D800000);
        chk(got_ov === 1'b1, "P0 tile produced a result (later checks are not vacuous)");
        chk(got_prec === 1'b1, "P1 mac_prec set when need > ShMax");
        chk(got_res  === 1'b1, "P1b win_rescale also set on the same tile");

        // 2^0 之后来 2^20，阶码差 20，抬基准但不清空
        two_term(32'h3F800000, 32'h49800000);
        chk(got_res  === 1'b1, "P2a win_rescale set on an ordinary base raise");
        chk(got_prec === 1'b0, "P2b mac_prec NOT set on an ordinary base raise");

        // 同阶码，基准一动不动
        two_term(32'h3F800000, 32'h3F800000);
        chk(got_res  === 1'b0, "P3a win_rescale clear when the base never moves");
        chk(got_prec === 1'b0, "P3b sticky cleared by acc_load");

        $display("");
        if (errors == 0) $display("SUMMARY tb_mac_prec: %0d checks -> ALL PASS", checks);
        else             $display("SUMMARY tb_mac_prec: %0d FAIL / %0d checks -> FAIL", errors, checks);
        $finish;
    end

    initial begin
        #100_000;
        $display("SUMMARY tb_mac_prec: WATCHDOG TIMEOUT -> FAIL");
        $finish;
    end

endmodule
