`timescale 1ns/1ps
`include "fp32_lat.vh"

// 当前接口的 psum 加载与连续任务重载检查。
module tb_mac_equiv2;
    localparam Pace = `FP32_MAC_PACE;

    reg clk = 0;
    reg rst_n;
    reg prod_valid;
    reg acc_load;
    reg last;
    reg [31:0] a;
    reg [31:0] b;
    reg [31:0] psum_in;
    wire [31:0] mac_out;
    wire out_valid;

    integer failures;

    fp32_mac_unit dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .prod_valid (prod_valid),
        .acc_load   (acc_load),
        .last       (last),
        .a          (a),
        .b          (b),
        .psum_in    (psum_in),
        .mac_out    (mac_out),
        .out_valid  (out_valid)
    );

    always #5 clk = ~clk;

    task send_product;
        input first_flag;
        input last_flag;
        begin
            prod_valid = 1;
            acc_load = first_flag;
            last = last_flag;
            a = 32'h3F800000;
            b = 32'h3F800000;
            @(negedge clk);
            prod_valid = 0;
            acc_load = 0;
            last = 0;
            repeat (Pace-1) @(negedge clk);
        end
    endtask

    task run_case;
        input [31:0] psum;
        input integer terms;
        input [31:0] expected;
        integer n;
        integer waited;
        begin
            psum_in = psum;
            for (n = 0; n < terms; n = n + 1)
                send_product(n == 0, n == terms-1);

            waited = 0;
            while (!out_valid && waited < 16) begin
                @(negedge clk);
                waited = waited + 1;
            end

            if (!out_valid) begin
                failures = failures + 1;
                $display("FAIL: out_valid timeout");
            end else if (mac_out !== expected) begin
                failures = failures + 1;
                $display("FAIL: psum=%h terms=%0d got=%h exp=%h",
                         psum, terms, mac_out, expected);
            end

            @(negedge clk);
        end
    endtask

    initial begin
        rst_n = 0;
        prod_valid = 0;
        acc_load = 0;
        last = 0;
        a = 0;
        b = 0;
        psum_in = 0;
        failures = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // 2.0 + 3 * (1.0 * 1.0) = 5.0
        run_case(32'h40000000, 3, 32'h40A00000);

        // 8.0 + 2 * (1.0 * 1.0) = 10.0，验证 acc_load 重载
        run_case(32'h41000000, 2, 32'h41200000);

        if (failures == 0) $display("ALL PASS: MAC psum/reload");
        else               $display("HAS FAILURES: %0d", failures);
        $finish;
    end
endmodule
