`timescale 1ns/1ps
`include "fp32_lat.vh"

// 上层按 out_valid 捕获 mac_out 的接口检查。
module tb_mac_cap;
    localparam K = 4;
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

    reg [31:0] captured;
    integer capture_count;
    integer failures;
    integer waited;
    integer k;

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

    // 同步消费者
    always @(posedge clk) begin
        if (!rst_n) begin
            captured <= 32'd0;
            capture_count <= 0;
        end else if (out_valid) begin
            captured <= mac_out;
            capture_count <= capture_count + 1;
        end
    end

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
        psum_in = 32'd0;

        for (k = 0; k < K; k = k + 1)
            send_product(k == 0, k == K-1);

        waited = 0;
        while (capture_count == 0 && waited < 16) begin
            @(negedge clk);
            waited = waited + 1;
        end

        if (capture_count != 1) begin
            failures = failures + 1;
            $display("FAIL: capture_count=%0d exp=1", capture_count);
        end else if (captured !== 32'h40800000) begin
            failures = failures + 1;
            $display("FAIL: captured=%h exp=40800000", captured);
        end

        if (failures == 0) $display("ALL PASS: MAC synchronous capture");
        else               $display("HAS FAILURES: %0d", failures);
        $finish;
    end
endmodule
